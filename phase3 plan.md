# Phase 3 계획: MicroBlaze + UART + DDR2 통합

## Context

Phase 2에서 RTL 합성 및 TB 검증이 완료되었다 (conv_top_tb mismatch 0, yolo_engine_tb 22-layer 완주). Phase 3의 목표는 기존 Vivado block design (MicroBlaze + DDR2 MIG + yolo_engine_ip)을 Phase 2 RTL에 맞게 업데이트하고, Vitis firmware를 완성하여 Host PC ↔ FPGA UART 통신으로 end-to-end 추론을 구현하는 것이다.

**핵심 발견**: `yolohw/fpga/vitis/memorytest.c`에 이미 Full MicroBlaze 기반 UART 프로토콜이 구현되어 있다. Block design에 `yolo_engine_ip` + DDR2 MIG + UART가 이미 존재한다. Phase 3는 _새 설계_가 아닌 **기존 구조 수정 + 완성**이다.

---

## 기존 구조 현황

| 구성요소 | 상태 | 위치 |
|---------|------|------|
| Full MicroBlaze + UartLite | ✅ 존재 | `vivado_yolohw/` 블록 디자인 |
| DDR2 MIG IP | ✅ 존재 | `design_1_mig_7series_0_0` |
| yolo_engine_ip | ✅ 존재 (구버전) | `ip_repo/` — Phase 1 이전 RTL |
| Vitis firmware | ⚠️ 부분 구현 + 버그 | `vitis/memorytest.c` |
| AXI 레지스터 맵 불일치 | ❌ 버그 | 펌웨어 vs 현재 yolo_engine_axi.v |

**기존 firmware 버그 목록**:
1. `init_uart()`: `=!` (assign-NOT) 대신 `!=` 사용해야 함 (UART 초기화 항상 실패)
2. `write_addr()`: u32 scalar를 `u8*` 포인터로 전달 → UB (MODE_RUN_ENGINE에서)
3. `MODE_RUN_ENGINE` 레지스터 맵: 구버전 순서 (IFM=0x04, OFM=0x08, WGT=0x0C) → 현재 RTL (WGT=0x04, IFM=0x08, OFM=0x0C)로 수정 필요
4. network_done 폴링: `is_dummy=1`로 바이패스 → `ctrl_reg0[1]` 실제 폴링으로 교체
5. `NUM_CONV_LAYER 11` → 22로 수정

---

## Phase 3 작업 목록

### Step A — RTL 수정 (Linux, 선행 필수)

**A1. OFM Streaming DMA** (`yolohw/src/yolo_engine.v`)
- **문제**: L0 OFM = 262,144 word, dpram = 65,536 word (4× 초과)
- **해결**: ST_RUN_CONV 상태에서 conv_top의 `row_done` 신호를 받아 row 단위로 DMA write 수행 (conv와 병렬)
  - conv_top.v에 `o_row_done` 출력 추가 (현재 행 처리 완료 시 1-cycle pulse)
  - yolo_engine.v에 sub-state `ST_STREAM_OFM` 추가: row_done → axi_dma_wr 트리거
  - dpram은 scratch buffer로만 사용, DRAM이 실제 저장소
- **수정 파일**: `yolohw/src/conv_top.v`, `yolohw/src/yolo_engine.v`

**A2. L19 Concat DMA** (`yolohw/src/yolo_engine.v`)
- **문제**: L19 Route(L18‖L8) 처리 시 L8 OFM(16,384 word)을 L18 OFM 직후에 이어붙여야 함
- **해결**: ST_NEXT에서 L19 감지 시 `ST_CONCAT` 상태 추가
  - axi_dma_rd로 L8 OFM 위치(dram_ofm_base + L8_offset)에서 읽기
  - axi_dma_wr로 L18 OFM 이후(dram_ofm_base + L18_offset + L18_size)에 쓰기
  - 16,384 word = 64 burst × 256 word
- **수정 파일**: `yolohw/src/yolo_engine.v`

---

### Step B — Vivado 블록 디자인 업데이트 (Windows Vivado GUI)

**B1. yolo_engine IP 재패키징**
- `ip_repo/`의 IP를 Phase 2 RTL(19 파일)로 갱신
- Vivado TCL: `update_ip_catalog` → IP 재합성
- AXI4-Lite slave 포트: `S_AXI_*` (4 registers)
- AXI4 master 포트: `M_AXI_RD_*`, `M_AXI_WR_*`

**B2. 블록 디자인 연결 확인 / 수정**
- MicroBlaze → AXI Interconnect → yolo_engine_ip (AXI-Lite)
- MicroBlaze → AXI Interconnect → DDR2 MIG
- yolo_engine_ip AXI master → AXI Interconnect → DDR2 MIG
- UART Lite baud rate: 921600 (최대 throughput)

**B3. 주소 맵 확인**
- DDR2 MIG base: `0x8000_0000` (Nexys A7 표준)
- yolo_engine_ip: `0x44A0_0000` (AXI-Lite slave, 16 byte)
- UART Lite: `0x4060_0000`

**DRAM 레이아웃 약속 (Phase 3)**:
```
dram_wgt_base  = DDR2_BASE + 0x0000_0000  (Weight)
               +  0x0001_0000 offset       (Bias)
dram_ifm_base  = DDR2_BASE + 0x0100_0000  (입력 이미지 256×256×3 = 192KB)
dram_ofm_base  = DDR2_BASE + 0x0200_0000  (OFM, ~700KB)
```

**B4. XSA 재생성**
- `File → Export → Export Hardware (Include Bitstream)` → `yolo_design_1_wrapper.xsa`

---

### Step C — Vitis Firmware 완성 (Linux C 코드, `yolohw/fpga/vitis/`)

**파일**: `memorytest.c` (기존 파일 수정)

**C1. 버그 수정**
```c
// init_uart 수정
if(status != XST_SUCCESS){ ... }   // =! → !=

// write_addr 오버로드 추가
void write_addr_u32(u32 addr, u32 value);  // 32-bit scalar 직접 쓰기
```

**C2. MODE_RUN_ENGINE 재구현** (레지스터 맵 수정 + 폴링 완성)
```c
// ctrl_reg1 = WGT base, ctrl_reg2 = IFM base, ctrl_reg3 = OFM base
write_addr_u32(ENGINE_BASE + 0x04, DDR2_BASE + WGT_OFFSET);   // ctrl_reg1
write_addr_u32(ENGINE_BASE + 0x08, DDR2_BASE + IFM_OFFSET);   // ctrl_reg2
write_addr_u32(ENGINE_BASE + 0x0C, DDR2_BASE + OFM_OFFSET);   // ctrl_reg3
write_addr_u32(ENGINE_BASE + 0x00, 0x01);                      // ap_start

// 실제 network_done 폴링
uint8_t temp[4];
do { read_addr(ENGINE_BASE + 0x00, temp, 4); }
while(!(temp[0] & 0x02));  // ctrl_reg0[1] = network_done
```

**C3. MODE_YOLO_POST 추가** (새 모드 0x08)
- DRAM에서 L14 OFM (8×8×195 = 12,480 words) 읽기
- DRAM에서 L20 OFM (16×16×195 = 49,920 words) 읽기
- Sigmoid 활성화 (objectness, 좌표 x,y)
- Anchor box 디코딩 (get_region_box)
- Softmax (클래스 확률)
- NMS (do_nms_sort)
- 결과를 UART로 전송 (detection 배열)

**C4. 고정소수점 후처리 구현**
- MicroBlaze는 소프트웨어 float 지원 (`-mhard-float` 또는 소프트웨어 FPU)
- Sigmoid LUT 또는 실수 연산 (MicroBlaze는 32-bit float 지원)
- skeleton/src의 `logistic_activate()`, `do_nms_sort()` 이식
- Anchor biases: 6 anchor pair (aix2024.cfg에서 추출)

---

### Step D — Host PC 스크립트 (Linux Python)

**파일**: `yolohw/firmware/host.py` (신규)

**프로토콜 시퀀스**:
```
1. [최초 1회] Weight 전송:
   → MODE_STORE_RAM (0x03) × N_layer
   → addr = DDR2_BASE + WGT_OFFSET, data = CONV*_param_weight.hex 내용

2. [매 추론] 이미지 전송:
   → MODE_STORE_RAM (0x03)
   → addr = DDR2_BASE + IFM_OFFSET, data = 256×256×3 uint8

3. 추론 실행:
   → MODE_RUN_ENGINE (0x06)
   → 응답: "Engine complete" (16 bytes)

4. 후처리 요청:
   → MODE_YOLO_POST (0x08)
   → 응답: detection[] 배열

5. 결과 시각화:
   → bounding box 그리기 + 저장
```

---

### Step E — 통합 검증 (Windows Vivado + 보드)

1. Vivado 합성 + 비트스트림: `launch_runs impl_1 -to_step write_bitstream -jobs 4`
2. Vitis에서 firmware 빌드 + 보드 다운로드
3. host.py로 Hello (MODE_TEST_HELLO) 통신 테스트
4. Weight 전송 후 단일 이미지 추론 + 결과 확인
5. 100장 테스트셋 mAP 측정 (Phase 4로 이어짐)

---

## 실행 순서 (의존성 기준)

```
A1 (conv_top row_done 추가)
A2 (L19 concat FSM)
    ↓
B1 (IP 재패키징) → B2 (BD 연결 확인) → B3/B4 (XSA 생성)
    ↓
C1~C4 (firmware 완성)
    ↓
D (host.py)
    ↓
E (보드 통합 테스트)
```

---

## 수정할 파일 목록

| 파일 | 변경 내용 |
|------|----------|
| `yolohw/src/conv_top.v` | `o_row_done` 출력 추가 |
| `yolohw/src/yolo_engine.v` | Streaming DMA (A1) + L19 Concat FSM (A2) |
| `yolohw/fpga/vitis/memorytest.c` | 버그 수정 + 모드 확장 (C1~C4) |
| `yolohw/firmware/host.py` | 신규 작성 (D) |

**Windows에서만 실행 (Claude Code 직접 실행 불가)**:
- Vivado block design IP 갱신 + XSA 재생성 (B1~B4)
- 합성 + 비트스트림 (E)

---

## 검증 방법

1. **RTL 시뮬레이션 (Vivado sim)**: A1 수정 후 `conv_top_tb` 재실행 → row_done 타이밍 확인
2. **펌웨어 통신 테스트**: `host.py --mode hello` → "Hello, World!" 16바이트 수신
3. **DRAM 읽쓰기 테스트**: `host.py --mode store_ram` → weight 전송 → `--mode load_ram` → 동일 데이터 확인
4. **End-to-end 추론**: 단일 이미지로 MODE_RUN_ENGINE + MODE_YOLO_POST → detection 결과 확인
