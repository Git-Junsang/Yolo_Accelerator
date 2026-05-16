/******************************************************************************
 * AIX2026 베타트론 — MicroBlaze Firmware (Phase 3)
 *
 * 수정 이력:
 *   Phase 3: 22-layer 프로토콜, 레지스터 맵 수정, 폴링 완성, YOLO 후처리 추가
 *
 * UART 프로토콜 (Host PC ↔ MicroBlaze):
 *   0x01 MODE_TEST_HELLO   → 16바이트 "Hello, World!" 응답
 *   0x02 MODE_TEST_ECHO    → 16바이트 수신 후 그대로 송신
 *   0x03 MODE_STORE_RAM    → [4B addr][4B word_count] → word_count × 4B DRAM 쓰기
 *   0x04 MODE_LOAD_RAM     → [4B addr][4B word_count] → word_count × 4B DRAM 읽기
 *   0x06 MODE_RUN_ENGINE   → YOLO 추론 실행 (ap_start → network_done 폴링)
 *   0x07 MODE_CONCAT_L19   → L8 OFM을 L19 concat 위치로 DRAM 복사
 *   0x08 MODE_YOLO_POST    → OFM 읽기 → Sigmoid/Softmax/NMS → 결과 송신
 *
 * DRAM 레이아웃:
 *   dram_wgt_base  = MIG_BASE + 0x0000_0000  (weight: 22-layer 전체)
 *                  + 0x0001_0000 offset       (bias)
 *   dram_ifm_base  = MIG_BASE + 0x0100_0000  (입력 이미지 256×256×3)
 *   dram_ofm_base  = MIG_BASE + 0x0200_0000  (OFM, per-layer offset)
 *
 * yolo_engine AXI-Lite 레지스터 맵:
 *   0x00: ctrl_reg0 → [0]=ap_start, [1]=network_done(읽기)
 *   0x04: ctrl_reg1 → dram_wgt_base
 *   0x08: ctrl_reg2 → dram_ifm_base
 *   0x0C: ctrl_reg3 → dram_ofm_base
 ******************************************************************************/
#define AIX2024_FIRMWARE_ENABLE 1

#ifdef AIX2024_FIRMWARE_ENABLE

#include "xparameters.h"
#include "xstatus.h"
#include "xuartlite.h"
#include <stdio.h>
#include <math.h>
#include <string.h>
#include "xil_io.h"

/* ── 모드 코드 ── */
#define MODE_TEST_HELLO   0x01
#define MODE_TEST_ECHO    0x02
#define MODE_STORE_RAM    0x03
#define MODE_LOAD_RAM     0x04
#define MODE_RUN_ENGINE   0x06
#define MODE_CONCAT_L19   0x07
#define MODE_YOLO_POST    0x08

/* ── DRAM 레이아웃 상수 (byte 주소, MIG_BASE 기준 offset) ── */
#define DDR2_BASE             XPAR_MIG_7SERIES_0_BASEADDR
#define WGT_OFFSET_BYTES      0x00000000u  /* weight base */
#define BIAS_OFFSET_BYTES     0x00A00000u  /* bias: wgt_base + 0xA00000 (weight ~10MB 이후) */
#define IFM_OFFSET_BYTES      0x01000000u  /* 입력 이미지 */
#define OFM_OFFSET_BYTES      0x02000000u  /* OFM 영역 시작 */

#define DRAM_WGT_BASE   (DDR2_BASE + WGT_OFFSET_BYTES)
#define DRAM_IFM_BASE   (DDR2_BASE + IFM_OFFSET_BYTES)
#define DRAM_OFM_BASE   (DDR2_BASE + OFM_OFFSET_BYTES)

/* ── Per-layer OFM DRAM word offset (yolo_engine.v 테이블과 동일) ── */
#define L8_OFM_WORD_OFFSET   614400u
#define L18_OFM_WORD_OFFSET  668720u
#define L18_OFM_WORD_SIZE    8192u
#define L14_OFM_WORD_OFFSET  663552u
#define L14_OFM_WORD_SIZE    3120u    /* 8×8×195 / 4 = 3120 words */
#define L20_OFM_WORD_OFFSET  693296u
#define L20_OFM_WORD_SIZE    12480u   /* 16×16×195 / 4 = 12480 words */
#define L8_OFM_WORD_SIZE     16384u   /* 256ch × 8 × 8 / 4 = 4096, wait: 256×8×8=16384 words */

/* ── yolo_engine AXI-Lite 기준 주소 ── */
#define ENGINE_BASE   XPAR_YOLO_ENGINE_IP_0_BASEADDR

/* ── YOLO 모델 파라미터 (aix2024.cfg) ── */
#define N_ANCHORS_PER_HEAD  3
#define N_CLASSES           60
#define YOLO_ENTRY          (4 + 1 + N_CLASSES)   /* 65 */
/* anchors: 전체 6쌍, mask에 따라 head 별로 3쌍 사용 */
/* L14 (8×8 head): mask 3,4,5 → (81,82),(135,169),(344,319) */
/* L20 (16×16 head): mask 0,1,2 → (10,14),(23,27),(37,58) */
static const float g_anchors_l14[N_ANCHORS_PER_HEAD][2] = {{81,82},{135,169},{344,319}};
static const float g_anchors_l20[N_ANCHORS_PER_HEAD][2] = {{10,14},{23,27},{37,58}};
#define INPUT_W  256.0f
#define INPUT_H  256.0f
#define NMS_THRESH    0.45f
#define OBJ_THRESH    0.24f
#define MAX_DETS      200

/* ── UART ── */
#define UARTLITE_DEVICE_ID  XPAR_UARTLITE_0_DEVICE_ID
static XUartLite UartLite;
static uint8_t g_recv_buf[16];

/* ── 응답 문자열 (16바이트 고정) ── */
static const uint8_t cHello[16]      = {' ',' ','H','e','l','l','o',',',' ','W','o','r','l','d','!',' '};
static const uint8_t cWaiting[16]    = {' ',' ','W','a','i','t','i','n','g','_','C','M','D',' ',' ',' '};
static const uint8_t cCmdRecv[16]    = {' ',' ','C','M','D','_','R','e','c','e','i','v','e',' ',' ',' '};
static const uint8_t cComplete[16]   = {' ','S','t','o','r','e',' ','c','o','m','p','l','e','t','e',' '};
static const uint8_t cEngineRun[16]  = {'E','n','g','i','n','e',' ','R','u','n',' ',' ',' ',' ',' ',' '};
static const uint8_t cEngineDone[16] = {'E','n','g','i','n','e',' ','c','o','m','p','l','e','t','e',' '};
static const uint8_t cConcatDone[16] = {'C','o','n','c','a','t',' ','D','o','n','e',' ',' ',' ',' ',' '};
static const uint8_t cPostDone[16]   = {'P','o','s','t',' ','D','o','n','e',' ',' ',' ',' ',' ',' ',' '};
static const uint8_t cError[16]      = {'E','R','R','O','R',' ',' ',' ',' ',' ',' ',' ',' ',' ',' ',' '};

/* ═══════════════════════════════════════════
 * UART 헬퍼
 * ═══════════════════════════════════════════ */
static void uart_recv(uint32_t num_bytes) {
    uint32_t received = 0;
    while (received < num_bytes)
        received += XUartLite_Recv(&UartLite, g_recv_buf + received, num_bytes - received);
}

static void uart_send(const uint8_t *data, uint32_t num_bytes) {
    uint32_t sent = 0;
    while (sent < num_bytes)
        sent += XUartLite_Send(&UartLite, (uint8_t *)data + sent, num_bytes - sent);
}

static int init_uart(uint16_t DeviceID) {
    int status;
    status = XUartLite_Initialize(&UartLite, DeviceID);
    if (status != XST_SUCCESS) return XST_FAILURE;  /* 수정: =! → != */
    status = XUartLite_SelfTest(&UartLite);
    if (status != XST_SUCCESS) return XST_FAILURE;  /* 수정: =! → != */
    XUartLite_ResetFifos(&UartLite);
    return XST_SUCCESS;
}

/* ═══════════════════════════════════════════
 * DRAM 접근 헬퍼
 * ═══════════════════════════════════════════ */
/* byte 단위 쓰기 */
static void write_addr(uint32_t addr, const uint8_t *data, uint32_t num_bytes) {
    for (uint32_t i = 0; i < num_bytes; i++)
        Xil_Out8(addr + i, data[i]);
}

/* 32-bit scalar 직접 쓰기 (수정: u32 scalar → 포인터 UB 방지) */
static void write_addr_u32(uint32_t addr, uint32_t value) {
    Xil_Out32(addr, value);
}

/* 32-bit scalar 읽기 */
static uint32_t read_addr_u32(uint32_t addr) {
    return Xil_In32(addr);
}

static void read_addr(uint32_t addr, uint8_t *buf, uint32_t num_bytes) {
    for (uint32_t i = 0; i < num_bytes; i++)
        buf[i] = Xil_In8(addr + i);
}

/* ═══════════════════════════════════════════
 * MODE_STORE_RAM — Host→DRAM 데이터 적재
 *   프로토콜: [4B addr_offset][4B word_count] → word_count × [4B data]
 *   addr_offset 은 DDR2_BASE 로부터의 byte offset.
 * ═══════════════════════════════════════════ */
static void handle_store_ram(void) {
    uart_send(cWaiting, 16);

    uart_recv(8);
    uint32_t offset    = ((uint32_t)g_recv_buf[3]<<24)|((uint32_t)g_recv_buf[2]<<16)
                        |((uint32_t)g_recv_buf[1]<<8)|g_recv_buf[0];
    uint32_t word_cnt  = ((uint32_t)g_recv_buf[7]<<24)|((uint32_t)g_recv_buf[6]<<16)
                        |((uint32_t)g_recv_buf[5]<<8)|g_recv_buf[4];
    uint32_t base_addr = DDR2_BASE + offset;

    uart_send(cCmdRecv, 16);

    for (uint32_t i = 0; i < word_cnt; i++) {
        uart_recv(4);
        write_addr(base_addr + i * 4, g_recv_buf, 4);
    }
    uart_send(cComplete, 16);
}

/* ═══════════════════════════════════════════
 * MODE_LOAD_RAM — DRAM→Host 데이터 전송
 * ═══════════════════════════════════════════ */
static void handle_load_ram(void) {
    uart_send(cWaiting, 16);

    uart_recv(8);
    uint32_t offset   = ((uint32_t)g_recv_buf[3]<<24)|((uint32_t)g_recv_buf[2]<<16)
                       |((uint32_t)g_recv_buf[1]<<8)|g_recv_buf[0];
    uint32_t word_cnt = ((uint32_t)g_recv_buf[7]<<24)|((uint32_t)g_recv_buf[6]<<16)
                       |((uint32_t)g_recv_buf[5]<<8)|g_recv_buf[4];
    uint32_t base_addr = DDR2_BASE + offset;

    uart_send(cCmdRecv, 16);

    uint8_t tmp[4];
    for (uint32_t i = 0; i < word_cnt; i++) {
        read_addr(base_addr + i * 4, tmp, 4);
        uart_send(tmp, 4);
    }
}

/* ═══════════════════════════════════════════
 * MODE_RUN_ENGINE — 22-layer 추론 실행
 *   1. ctrl_reg1/2/3 에 DRAM 주소 설정
 *   2. ap_start (ctrl_reg0[0] = 1) 트리거
 *   3. network_done (ctrl_reg0[1]) 폴링
 * ═══════════════════════════════════════════ */
static void handle_run_engine(void) {
    uart_send(cEngineRun, 16);

    /* 레지스터 설정 */
    write_addr_u32(ENGINE_BASE + 0x04, DRAM_WGT_BASE);   /* ctrl_reg1: weight base */
    write_addr_u32(ENGINE_BASE + 0x08, DRAM_IFM_BASE);   /* ctrl_reg2: IFM base */
    write_addr_u32(ENGINE_BASE + 0x0C, DRAM_OFM_BASE);   /* ctrl_reg3: OFM base */

    /* ap_start 트리거 (1-cycle pulse: 1→0) */
    write_addr_u32(ENGINE_BASE + 0x00, 0x00000001u);
    write_addr_u32(ENGINE_BASE + 0x00, 0x00000000u);

    /* network_done 폴링 (ctrl_reg0[1]) */
    uint32_t ctrl;
    do {
        ctrl = read_addr_u32(ENGINE_BASE + 0x00);
    } while (!(ctrl & 0x00000002u));

    uart_send(cEngineDone, 16);
}

/* ═══════════════════════════════════════════
 * MODE_CONCAT_L19 — L8 OFM → L19 concat 위치로 DRAM memcpy
 *   L19 IFM = L18 OFM(8192 words) + L8 OFM(16384 words) 연속 배치
 *   복사 전 yolo_engine 이 L18 까지 완료되어 있어야 함.
 *   (double-inference 전략: 1차 run 후 concat, 2차 run 으로 정확한 L20 결과 획득)
 * ═══════════════════════════════════════════ */
static void handle_concat_l19(void) {
    uint32_t src_base = DRAM_OFM_BASE + L8_OFM_WORD_OFFSET * 4u;
    uint32_t dst_base = DRAM_OFM_BASE + (L18_OFM_WORD_OFFSET + L18_OFM_WORD_SIZE) * 4u;

    /* 16,384 word = 65,536 byte 복사 */
    for (uint32_t i = 0; i < L8_OFM_WORD_SIZE; i++) {
        uint32_t val = read_addr_u32(src_base + i * 4u);
        write_addr_u32(dst_base + i * 4u, val);
    }
    uart_send(cConcatDone, 16);
}

/* ═══════════════════════════════════════════
 * YOLO 후처리 헬퍼
 * ═══════════════════════════════════════════ */
static inline float sigmoid_f(float x) { return 1.0f / (1.0f + expf(-x)); }

/* UINT8 출력값을 float logit 으로 역양자화.
 * post_process: output = clip(bias + acc >> shift, 0, 255)
 * 역: logit ≈ (val - 128) 를 근사 사용 (대칭 UINT8 기준).
 * 실제 정확도를 높이려면 per-layer scale 을 host 가 전달해야 함. */
static inline float dequant(uint8_t val) { return (float)(int8_t)(val - 128u); }

typedef struct {
    float x, y, w, h;
    float obj;
    float cls_prob[N_CLASSES];
    int   cls_id;
    float score;
} Detection;

static Detection g_dets[MAX_DETS];
static int g_n_dets;

static float box_iou(const Detection *a, const Detection *b) {
    float ax1 = a->x - a->w * 0.5f, ax2 = a->x + a->w * 0.5f;
    float ay1 = a->y - a->h * 0.5f, ay2 = a->y + a->h * 0.5f;
    float bx1 = b->x - b->w * 0.5f, bx2 = b->x + b->w * 0.5f;
    float by1 = b->y - b->h * 0.5f, by2 = b->y + b->h * 0.5f;
    float ix  = (ax2 < bx2 ? ax2 : bx2) - (ax1 > bx1 ? ax1 : bx1);
    float iy  = (ay2 < by2 ? ay2 : by2) - (ay1 > by1 ? ay1 : by1);
    if (ix <= 0 || iy <= 0) return 0.0f;
    float inter = ix * iy;
    return inter / (a->w * a->h + b->w * b->h - inter);
}

/* 한 YOLO head 의 OFM 을 파싱하여 g_dets 에 추가 */
static void parse_yolo_head(
        const uint8_t *ofm,   /* UINT8 OFM 데이터 (NCHW, 4바이트 packed) */
        int grid_w, int grid_h,
        const float anchors[][2])
{
    /* OFM layout: [channel][row][col], channel = anchor_idx * YOLO_ENTRY + entry_idx
     * conv_top 은 4픽셀(2×2)씩 패킹하므로 word = {ch3,ch2,ch1,ch0} */
    int n_spatial = grid_w * grid_h;

    for (int an = 0; an < N_ANCHORS_PER_HEAD; an++) {
        float aw = anchors[an][0];
        float ah = anchors[an][1];

        for (int row = 0; row < grid_h; row++) {
            for (int col = 0; col < grid_w; col++) {
                int spatial = row * grid_w + col;

                /* NCHW 에서 entry e 의 byte 인덱스
                 * channel = an * YOLO_ENTRY + e
                 * byte offset = channel * n_spatial + spatial */
                #define YOLO_BYTE(e) \
                    ofm[(an * YOLO_ENTRY + (e)) * n_spatial + spatial]

                float tx = dequant(YOLO_BYTE(0));
                float ty = dequant(YOLO_BYTE(1));
                float tw = dequant(YOLO_BYTE(2));
                float th = dequant(YOLO_BYTE(3));
                float to = dequant(YOLO_BYTE(4));

                float obj = sigmoid_f(to);
                if (obj < OBJ_THRESH) continue;

                /* anchor box 디코딩 */
                float bx = (sigmoid_f(tx) + (float)col) / (float)grid_w;
                float by = (sigmoid_f(ty) + (float)row) / (float)grid_h;
                float bw = aw * expf(tw) / INPUT_W;
                float bh = ah * expf(th) / INPUT_H;

                /* 클래스 확률 softmax */
                float cls[N_CLASSES];
                float max_cls = -1e9f, sum_cls = 0.0f;
                for (int c = 0; c < N_CLASSES; c++) {
                    cls[c] = dequant(YOLO_BYTE(5 + c));
                    if (cls[c] > max_cls) max_cls = cls[c];
                }
                for (int c = 0; c < N_CLASSES; c++) {
                    cls[c] = expf(cls[c] - max_cls);
                    sum_cls += cls[c];
                }
                int best_cls = 0;
                float best_p = 0.0f;
                for (int c = 0; c < N_CLASSES; c++) {
                    cls[c] /= sum_cls;
                    if (cls[c] > best_p) { best_p = cls[c]; best_cls = c; }
                }
                #undef YOLO_BYTE

                float score = obj * best_p;
                if (score < OBJ_THRESH) continue;
                if (g_n_dets >= MAX_DETS) continue;

                Detection *d = &g_dets[g_n_dets++];
                d->x = bx; d->y = by; d->w = bw; d->h = bh;
                d->obj = obj; d->score = score; d->cls_id = best_cls;
            }
        }
    }
}

/* ═══════════════════════════════════════════
 * MODE_YOLO_POST — DRAM OFM 읽기 → Sigmoid/Softmax/NMS → UART 송신
 *
 * 송신 형식:
 *   [4B n_dets]
 *   per detection: [4B cls_id][4B score (float)][4B x][4B y][4B w][4B h]
 * ═══════════════════════════════════════════ */
/* OFM 임시 버퍼 (16×16×195 bytes = 49920 bytes 가 최대) */
static uint8_t g_ofm_buf[16 * 16 * N_ANCHORS_PER_HEAD * YOLO_ENTRY];

static void handle_yolo_post(void) {
    g_n_dets = 0;

    /* ── L14 OFM 읽기 (8×8 grid, 3120 words = 12480 bytes) ── */
    uint32_t l14_base = DRAM_OFM_BASE + L14_OFM_WORD_OFFSET * 4u;
    for (uint32_t i = 0; i < L14_OFM_WORD_SIZE; i++) {
        uint32_t w = read_addr_u32(l14_base + i * 4u);
        g_ofm_buf[i * 4 + 0] = (uint8_t)(w       & 0xFF);
        g_ofm_buf[i * 4 + 1] = (uint8_t)((w >> 8) & 0xFF);
        g_ofm_buf[i * 4 + 2] = (uint8_t)((w >>16) & 0xFF);
        g_ofm_buf[i * 4 + 3] = (uint8_t)((w >>24) & 0xFF);
    }
    parse_yolo_head(g_ofm_buf, 8, 8, g_anchors_l14);

    /* ── L20 OFM 읽기 (16×16 grid, 12480 words = 49920 bytes) ── */
    uint32_t l20_base = DRAM_OFM_BASE + L20_OFM_WORD_OFFSET * 4u;
    for (uint32_t i = 0; i < L20_OFM_WORD_SIZE; i++) {
        uint32_t w = read_addr_u32(l20_base + i * 4u);
        g_ofm_buf[i * 4 + 0] = (uint8_t)(w       & 0xFF);
        g_ofm_buf[i * 4 + 1] = (uint8_t)((w >> 8) & 0xFF);
        g_ofm_buf[i * 4 + 2] = (uint8_t)((w >>16) & 0xFF);
        g_ofm_buf[i * 4 + 3] = (uint8_t)((w >>24) & 0xFF);
    }
    parse_yolo_head(g_ofm_buf, 16, 16, g_anchors_l20);

    /* ── 클래스별 NMS ── */
    for (int c = 0; c < N_CLASSES; c++) {
        /* 해당 클래스 score 내림차순 단순 버블 정렬 */
        for (int i = 0; i < g_n_dets - 1; i++) {
            for (int j = i + 1; j < g_n_dets; j++) {
                if (g_dets[i].cls_id == c && g_dets[j].cls_id == c &&
                    g_dets[j].score > g_dets[i].score) {
                    Detection tmp = g_dets[i];
                    g_dets[i] = g_dets[j];
                    g_dets[j] = tmp;
                }
            }
        }
        /* IoU 기반 억제 */
        for (int i = 0; i < g_n_dets; i++) {
            if (g_dets[i].cls_id != c || g_dets[i].score <= 0.0f) continue;
            for (int j = i + 1; j < g_n_dets; j++) {
                if (g_dets[j].cls_id != c || g_dets[j].score <= 0.0f) continue;
                if (box_iou(&g_dets[i], &g_dets[j]) > NMS_THRESH)
                    g_dets[j].score = 0.0f;
            }
        }
    }

    /* ── 결과 집계 (score > 0 인 것만) ── */
    int valid = 0;
    for (int i = 0; i < g_n_dets; i++)
        if (g_dets[i].score > 0.0f) valid++;

    /* ── UART 송신 ── */
    uint8_t hdr[4];
    hdr[0] = (uint8_t)(valid);
    hdr[1] = (uint8_t)(valid >> 8);
    hdr[2] = (uint8_t)(valid >> 16);
    hdr[3] = (uint8_t)(valid >> 24);
    uart_send(hdr, 4);

    for (int i = 0; i < g_n_dets; i++) {
        if (g_dets[i].score <= 0.0f) continue;
        /* cls_id (4B) + score (4B float) + x,y,w,h (4B each) = 24 bytes per det */
        uint8_t det_buf[24];
        int32_t cls  = g_dets[i].cls_id;
        float   scr  = g_dets[i].score;
        float   bx   = g_dets[i].x;
        float   by   = g_dets[i].y;
        float   bw   = g_dets[i].w;
        float   bh   = g_dets[i].h;
        memcpy(det_buf +  0, &cls, 4);
        memcpy(det_buf +  4, &scr, 4);
        memcpy(det_buf +  8, &bx,  4);
        memcpy(det_buf + 12, &by,  4);
        memcpy(det_buf + 16, &bw,  4);
        memcpy(det_buf + 20, &bh,  4);
        uart_send(det_buf, 24);
    }
    uart_send(cPostDone, 16);
}

/* ═══════════════════════════════════════════
 * main
 * ═══════════════════════════════════════════ */
int main(void) {
    if (init_uart(UARTLITE_DEVICE_ID) != XST_SUCCESS) {
        /* UART 초기화 실패 시 무한 루프 (디버그용) */
        while (1);
    }

    while (1) {
        uart_recv(1);
        uint8_t mode = g_recv_buf[0];

        if (mode == MODE_TEST_HELLO) {
            uart_send(cHello, 16);

        } else if (mode == MODE_TEST_ECHO) {
            uart_recv(16);
            uart_send(g_recv_buf, 16);

        } else if (mode == MODE_STORE_RAM) {
            handle_store_ram();

        } else if (mode == MODE_LOAD_RAM) {
            handle_load_ram();

        } else if (mode == MODE_RUN_ENGINE) {
            handle_run_engine();

        } else if (mode == MODE_CONCAT_L19) {
            handle_concat_l19();

        } else if (mode == MODE_YOLO_POST) {
            handle_yolo_post();

        } else {
            uart_send(cError, 16);
        }
    }
    return 0;
}

#else
/* 기존 memory test 코드 (참조용 보존) */
#include <stdio.h>
#include "xparameters.h"
#include "platform.h"
#include "memory_config.h"
#include "xil_printf.h"
void test_memory_range(struct memory_range_s *range);
int main(void) { return 0; }
#endif
