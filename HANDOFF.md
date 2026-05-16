# AIX2026 베타트론 — 세션 핸드오프 문서

## 📍 현재 위치: **Phase 3 코드 완성** (RTL + firmware + host.py 모두 완료)

보드 통합(Vivado IP 재패키징 + XSA + 비트스트림)만 남아 있음.

---

## 🗂️ 프로젝트 4-Phase

| Phase | 내용 | 상태 |
|-------|------|------|
| **Phase 1** | MicroBlaze 제외 RTL 합성 완료 (22-layer 자동 추론) | ✅ 완료 |
| **Phase 2** | TB 검증 + 정확도 튜닝 (shift 실측, mismatch 0) | ✅ 완료 |
| **Phase 3** | MicroBlaze + UART + DDR2 통합 코드 | ✅ **코드 완성** / 보드 통합 대기 |
| Phase 4 | 비트스트림 + 보드 데모 + 측정 | ⏳ 대기 |

---

## ✅ Phase 3 완료 사항 (2026-05-16)

### A. RTL 수정 (Linux에서 완료)

#### A1. `yolohw/src/conv_top.v`
- `output o_fil_done`: ST_DRAIN에서 1-cycle pulse (필터 1개 완료 신호)
- `input i_conv_pause`: HIGH 동안 ST_NEXT에서 대기 (streaming DMA용)

#### A2. `yolohw/src/yolo_engine.v` — 치명적 버그 7개 수정

| Bug | 증상 | 수정 내용 |
|-----|------|----------|
| lyr_wgt_dram_blk 누락 | L2+ layer가 L0 weight로 추론 | reg [17:0] lyr_wgt_dram_blk 추가, case table 전수 정의 |
| Weight BRAM write addr 0 고정 | L2 weight가 L0 BRAM 덮어씀 | `12'd0` → `{lyr_wgt_base, 2'b00}` |
| Bias DRAM per-layer offset 누락 | L2+ 모두 L0 bias 사용 | addr_bias += lyr_bias_base × 4 |
| Bias BRAM write addr 0 고정 | bias_entry_addr L0부터 덮어씀 | `12'd0` → `lyr_bias_base` |
| Weight BRAM overflow (L6+) | L6+ Co×acc_len > 1024 BRAM 한계 | stream_wgt_mode: 필터별 weight 순차 로딩 |
| OFM dpram overflow (L0, L2) | OFM > 65536 word | stream_mode: 필터별 OFM DMA streaming |
| conv_pause_r 1-cycle pulse | DMA 중 conv 재개 | 레벨 신호로 변경, dma_done 시에만 해제 |
| ofm_store_rd_addr_r off-by-one | stream_fil_cnt 이미 k+1일 때 addr 계산 | `- 1` 보정 |

**Layer별 lyr_wgt_dram_blk 값** (64-byte block 단위):
```
L0=0, L2=16, L4=144, L6=656, L8=2704, L10=10896,
L12=43664, L13=76432, L14=109200, L17=134160, L20=142352
```

**Stream mode 기준**:
- `stream_mode` (OFM streaming): L0 (262144 > 65536), L2 (131072 > 65536)
- `stream_wgt_mode` (Weight streaming): L6+ (Co × acc_len > 1024)

### B. Firmware (`yolohw/fpga/vitis/memorytest.c`) — 수정 완료

- `init_uart`: `=!` → `!=` 수정
- `write_addr_u32` 추가 (scalar 직접 쓰기)
- MODE_RUN_ENGINE 레지스터 맵: ctrl_reg1=WGT(0x04), ctrl_reg2=IFM(0x08), ctrl_reg3=OFM(0x0C)
- `network_done` 실제 폴링 (ctrl_reg0[1])
- MODE_CONCAT_L19 (0x07): L8 OFM → L18 뒤로 DRAM memcpy (double-inference 전략)
- MODE_YOLO_POST (0x08): Sigmoid/Softmax/NMS → UART 결과 송신

**UART 프로토콜 요약**:
```
0x01 MODE_TEST_HELLO   → 16B "  Hello, World! "
0x03 MODE_STORE_RAM    → [4B offset][4B word_cnt] → data → 16B ack
0x04 MODE_LOAD_RAM     → [4B offset][4B word_cnt] → 16B ack → data
0x06 MODE_RUN_ENGINE   → 16B "Engine Run      " ... 16B "Engine complete "
0x07 MODE_CONCAT_L19   → 16B "Concat Done     "
0x08 MODE_YOLO_POST    → [4B n_dets] → n_dets×24B → 16B "Post Done       "
```

### C. Host PC 클라이언트 (`yolohw/firmware/host.py`) — 신규 작성

```bash
# 최초 실행 (weight + image 전송 + 추론)
python host.py --port /dev/ttyUSB1 --image test01.jpg --weights skeleton/bin/log_param

# 재추론 (weight 스킵)
python host.py --port /dev/ttyUSB1 --image test02.jpg --skip-weights

# 통신 테스트
python host.py --port /dev/ttyUSB1 --hello
```

**host.py 핵심 데이터 패킹**:
```
Weight DRAM 포맷 (filter-major → group-major → slot-minor):
  byte_off = (blk_off + f×acc_len + g) × 64 + s × 16
  slot = [kernel(9 or 1 bytes)] + [zero pad to 16 bytes]

Bias DRAM 포맷:
  DDR2_BASE + 0x10000 + lyr_bias_base × 4
  각 bias: 16-bit hex → sign-extend → 32-bit LE

IFM DRAM 포맷 (L0: 256×256×3):
  word = R | (G<<8) | (B<<16)  (ch3=0 padding)
  배치: row-major, col_block-major (4 pixels/entry)
```

---

## ⏭️ Phase 3 남은 작업 (Windows Vivado 필요)

### B1. yolo_engine IP 재패키징
- `ip_repo/` 내 IP를 Phase 3 RTL (19 파일)로 업데이트
- Vivado TCL: `update_ip_catalog` → IP 재합성
- 포트: AXI4-Lite slave (S_AXI_*), AXI4 master (M_AXI_RD_*, M_AXI_WR_*)

### B2. Block design 연결 확인
- MicroBlaze MCS → AXI Interconnect → yolo_engine_ip (AXI-Lite)
- yolo_engine_ip AXI master → AXI Interconnect → DDR2 MIG
- UartLite baud: 921600

### B3. 주소 맵 확인
- DDR2 MIG: `0x8000_0000`
- yolo_engine_ip: `0x44A0_0000` (AXI-Lite, 16 bytes)
- UartLite: `0x4060_0000`

### B4. XSA 재생성
- File → Export → Export Hardware (Include Bitstream) → `yolo_design_1_wrapper.xsa`
- Vitis에서 firmware 빌드 + `memorytest.c` 컴파일

---

## ⏭️ Phase 4 — 보드 데모 + 측정

```tcl
launch_runs synth_1 -jobs 4
launch_runs impl_1 -to_step write_bitstream -jobs 4
```
- 합성 후 Vitis에서 firmware 다운로드
- host.py로 Hello 테스트 → weight 전송 → 추론 → 결과 확인
- 100장 테스트셋 mAP + fps + 전력 측정
- **점수 공식**: Score = 10⁴ / Energy × ReLU(mAP − 0.2) × ReLU(fps − 5)

---

## 📋 DRAM 레이아웃 (Phase 3 약속)

```
DDR2_BASE + 0x0000_0000 : Weight 전체 (11 conv layer, ~9.8 MB)
DDR2_BASE + 0x0001_0000 : Bias 전체 (2294 × 4 bytes)
DDR2_BASE + 0x0100_0000 : IFM (256×256×3, packed)
DDR2_BASE + 0x0200_0000 : OFM (per-layer offset, yolo_engine.v 테이블 기준)
```

### Per-layer OFM offset (32-bit word 단위)
| Layer | offset | size |
|-------|--------|------|
| L0  | 0       | 262144 |
| L1  | 262144  | 65536  |
| L2  | 327680  | 131072 |
| L8  | 614400  | 16384  |
| L12 | 651264  | 4096   |
| L14 | 663552  | 3120   |
| L18 | 668720  | 8192   |
| L20 | 693296  | 12480  |

---

## 📁 활성 파일 목록

### yolohw/src/ (RTL, 19 파일)
`mul.v`, `mul_dual.v`, `add_tree_36in.v`, `mac_stack.v`, `mac_kern.v`,
`post_process.v`, `gbuff_param.v`, `spram_wrapper.v`, `dpram_wrapper.v`,
`ifm_line_buf.v`, `conv_top.v`, `max_pool_unit.v`, `max_pool_s1_unit.v`,
`upsample_unit.v`, `yolo_engine.v`, `yolo_engine_axi.v`,
`axi_dma_rd.v`, `axi_dma_wr.v`, `user_define_h.v`

### Phase 3 추가/수정 파일
- `yolohw/fpga/vitis/memorytest.c` — 수정 완료
- `yolohw/firmware/host.py` — 신규 작성 완료

---

## 🚀 다음 세션 시작 시 권장 명령

### Phase 3 보드 통합 (Windows에서 Vivado 실행):
```
@CLAUDE.md @HANDOFF.md @ARCHITECTURE.md 를 읽고
Phase 3 보드 통합 (B단계: IP 재패키징 + XSA 생성)을 시작해 주세요.
```

### Phase 4 측정:
```
@CLAUDE.md @HANDOFF.md 를 읽고
Phase 4 (비트스트림 + 보드 데모 + mAP 측정)을 시작해 주세요.
```
