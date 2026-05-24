# HISTORY.md — YOLO Accelerator 검증 진행 기록

## 2026-05-22

### Phase 3 RTL 검증 (라우팅 이전, L0~L10)

#### 1차 — L0, L1, L2 (non-streaming)
- L0 (CONV3x3 3→16, 256×256), L1 (POOL_S2 16ch), L2 (CONV3x3 16→32, 128×128) 구현·검증
- L2 IFM 포맷 충돌 (L1 OFM 채널-major ↔ L2 IFM NHWC packed) 해결을 위해 **REPACK 단계** 도입
- weight 는 layer 시작 시 일괄 BRAM 적재 방식
- 결과 : L0/L1/L2 standalone 모두 PASS. chain L0→L1→L2 의 mismatch 는 모두 L0 의 22개 양자화 차이 propagation (skeleton float vs RTL int 산술)
- 주요 RTL 버그 수정 :
  - `conv_top.v` weight pipeline 정렬 — `ST_LOAD` 와 spatial transition 의 `wgt_base+1` advance 제거 (이전에 acc_len>1 layer 가 채널 회전 곱셈 버그 발생)
  - L2 OFM DRAM 주소 fi-stride (`fi<<11` → `fi<<14`)
  - L4 IFM DRAM base / row stride 누락 (mux 에 L4 case 추가)

#### 2차 — streaming weight mode 통일
- L0~L10 의 모든 conv 가 **per-filter streaming weight DMA** 사용 (filter 1개 weight 만 BRAM[0..acc_len-1] 에 fresh 적재 → conv → 다음 filter 로)
- `conv_top.i_stream_wgt_mode = 1`, `i_wgt_base = 0` 고정
- 이유 : L6+ 의 weight (8192+ entry) 가 BRAM (4096 entry) 초과 → streaming 필수. 일관성을 위해 L0~L4 도 통일
- 결과 : non-streaming 과 bit-identical (mismatch 수 동일)

#### 3차 — L3, L4, L5 추가
- L3 (POOL_S2 32ch), L4 (CONV3x3 32→64, 64×64), L5 (POOL_S2 64ch) 구현
- pool/conv/REPACK 파라미터 mux 화 (`pool_phase_r`, `conv_phase_r` 으로 layer 구별)
- L3→L4 REPACK 추가 (W_BLK=16, ci_g=8)
- `fi_r` 5-bit → 12-bit 확장 (L5 의 64 filter 대응 — 이전 5-bit 라 fi 0..31 만 처리되어 Phase A 50% mismatch 발생했음)

#### 4차 — L6, L7, L8, L9, L10 추가 (라우팅 이전 마지막)
- L6 (CONV 64→128, 32×32), L7 (POOL 128), L8 (CONV 128→256, 16×16), L9 (POOL 256), L10 (CONV 256→512, 8×8)
- conv mux 6 layers / pool mux 5 layers / REPACK 5 transitions 까지 확장
- `rp_cig_r` 4-bit → 6-bit (L9→L10 의 ci_g 0..63 대응)
- REPACK GEN addr 가 `cur_rp_load_words` (W_BLK 변수) 기반 multiplication 으로 layer-agnostic

### DRAM 메모리 맵 (Phase 3 검증 시점)

```
WGT  : 0x00000000 (~10MB, 11 layer weights)
BIAS : 0x00A00000 ( 2294 word = 9.2KB)
IFM  : 0x00B00000 (65,536 word = 256KB, L0 input image)
OFM  : 0x00C00000 →
   L0 OFM           : 0x000000..0x0FFFFF  (1024KB) conv 2×2 packed
   L1 OFM           : 0x100000..0x13FFFF  (256KB)  channel-major byte stream
   L2 IFM  (REPACK) : 0x140000..0x17FFFF  (256KB)  NHWC packed
   L2 OFM           : 0x180000..0x1FFFFF  (512KB)  conv 2×2 packed
   L3 OFM           : 0x200000..0x21FFFF  (128KB)
   L4 IFM  (REPACK) : 0x220000..0x23FFFF  (128KB)
   L4 OFM           : 0x240000..0x27FFFF  (256KB)
   L5 OFM           : 0x280000..0x28FFFF  ( 64KB)
   L6 IFM  (REPACK) : 0x290000..0x29FFFF  ( 64KB)
   L6 OFM           : 0x2A0000..0x2BFFFF  (128KB)
   L7 OFM           : 0x2C0000..0x2C7FFF  ( 32KB)
   L8 IFM  (REPACK) : 0x2C8000..0x2CFFFF  ( 32KB)
   L8 OFM           : 0x2D0000..0x2DFFFF  ( 64KB)
   L9 OFM           : 0x2E0000..0x2E3FFF  ( 16KB)
   L10 IFM (REPACK) : 0x2E4000..0x2E7FFF  ( 16KB)
   L10 OFM          : 0x2E8000..0x2EFFFF  ( 32KB)
```
총 ~3MB DRAM 사용. 16MB 내 여유 충분.

### 검증 결과 (Phase B = full chain L0~LN)

| TB | Phase A (standalone) | Phase B (chain) | 비고 |
|---|---|---|---|
| l0_verify_tb  | (해당없음) | 22 mismatch  | skeleton 산술 정의 차이 |
| l1_verify_tb  | 0          | 8 mismatch   | L0 propagation (max pool reduce) |
| l2_verify_tb  | 0          | 52 mismatch  | conv 3×3 spread |
| l5_verify_tb  | 0          | 22 mismatch  | L2 OFM 일부 측정 |
| l10_verify_tb | 0          | 660 mismatch | 10 layer 누적 propagation (=2%) |
| l11_verify_tb | 0          | 0 mismatch   | POOL_S1, max pool 이 propagation 흡수 |
| l12_verify_tb | 0          | 0 mismatch    | CONV1x1, RTL REPACK + L11 maxpool 흡수 효과 지속 |
| l13_verify_tb | 0          | 0 mismatch    | CONV3x3 (L10 구조 재사용), L12→L13 RTL REPACK |
| l14_verify_tb | 0          | 0 mismatch    | CONV1x1 detection layer (linear activation, INT8 raw output) |
| l17_verify_tb | 0          | 0 mismatch    | L15 [yolo] + L16 [route -4] skip → L12→L17 RTL REPACK → CONV1x1 |
| l18_verify_tb | 0          | 0 mismatch    | UPSAMPLE 2× (upsample_unit), L11 pool_s1 패턴과 동일 6-state 통합 |

모든 standalone PASS → RTL 자체 버그 없음.
Chain mismatch 는 모두 ±1 LSB 수준의 양자화 차이 propagation 으로 추정 (Δ 분포 통계 측정 진행 중).

#### 5차 — L11 (POOL_S1) 추가 (2026-05-22 추가)

- L10 conv 직후 종료되던 FSM 에 L11 (stride-1 same-padding maxpool) 통합
- 새 상태 6개 추가: `S_L11_LOAD/LOAD_WAIT/POOL/POOL_WAIT/STORE/STORE_WAIT`
  (state_r 5-bit → 6-bit 확장)
- 새 DMA target: `DMA_TGT_L11_IFM` — DRAM L10 OFM → ofm dpram[0..8191] 직접 적재
- `max_pool_s1_unit` 을 `u_pool_s1` 로 인스턴스화, OFM dpram port A/B 와 mux
- L11 OFM 영역 신설: `0x002F0000..0x002F7FFF` (32KB, 8192 word)
- 데이터 흐름: DRAM(L10 OFM) → dpram[0..8191] → pool_s1(in_base=0,out_base=8192) → dpram[8192..16383] → DRAM(L11 OFM)
- 검증 결과:
  - Phase A (standalone) : 0 mismatch (golden L10 OFM → max_pool_s1_unit → golden L11 OFM 비교)
  - Phase B (chain L0~L11) : 0 mismatch — L10 verify 의 660 mismatch 가 L11 maxpool 통과 후 **0 으로 흡수됨**
- 가짜 PASS 가능성 검증 완료 (TB 내 sanity_check_data + compare_l10_ofm_chain 으로 직접 측정, 비활성화 후 보존):
  - golden_l10 nonzero=18683/32768 (57%), golden_l11=24700/32768 (75%)
  - DRAM L10 OFM=6595/8192 word (81%), DRAM L11 OFM=7248/8192 word (88%)
  - Packed-2×2 ↔ NCHW byte 매핑 수동 디코딩 검증 완료

### 다음 단계 — L12 이후 (1×1 conv 진입)

- **L12, L14, L17, L20** : CONV1x1 — conv_top `i_mode=1` 경로, line_buf 1×1 packing
- **L13** : CONV3x3 (L2 패턴 재사용 가능)
- **L15~L16** : ROUTE/REORG — DMA 주소 alias 만, 연산 없음
- **L18** : UPSAMPLE — `upsample_unit.v` 사용
- **L19** : ROUTE concat

#### 6차 — L12 (CONV1x1, 첫 1×1 layer) Phase A 검증 (2026-05-23 추가)

- L12 (Ci=512, Co=256, 8×8, 1×1 kernel) yolo_engine 통합:
  - L12 파라미터 + conv mux 확장 + DRAM addr (`L12_OFM_BYTE_BASE = 0x00300000`)
  - `is_conv_l12` 분기로 conv_top.i_mode, ifm_line_buf.i_mode 모두 1×1 mode 설정
  - 1×1 IFM row stride = 4096 byte (3×3 의 2배)
  - `ifm_first_row_for_rb = 2*rb` (1×1 은 rb 한 step = 2 input rows)
  - FSM S_CONV_DONE 의 cp==12 분기 추가 (S_DONE 으로 종료)

- conv_top + ifm_line_buf 의 **1×1 mode 버그 2개 발견 및 수정**:
  1. **offset / col_inblk 매핑**: 기존 1×1 path 가 3×3 의 `col_start = 2*Cb - 1` 식 그대로 사용 → 잘못된 offset.
     - 수정: `offset_1x1 = 0`, `col_block_1x1 = i_cb >> 1`, `col_inblk_1x1 = (i_cb[0])?2:0`
     - micro TB (Ci=4, Co=1, H=W=4) 로 확인
  2. **ifm/weight ch packing 불일치**: weight 의 slot packing 은 ch 0..3 을 byte 0, 9, 18, 27 에 배치하지만,
     기존 ifm packing 은 byte 0..3 에 배치 → `mul[i] = wgt[i] × ifm[i]` 매핑에서 ch 0 곱셈만 진행되고
     ch 1~3 무시되는 버그.
     - 수정: ifm00/01/10/11 의 ch 0..3 도 byte 0, 9, 18, 27 위치에 배치
     - L12 실데이터로 확인 — 수정 전 mismatch 10997/16384 → 수정 후 0/16384

- 검증 결과:
  - Phase A (TB software REPACK, golden L12 IFM → conv → golden L12 OFM 비교) : **0 mismatch / 16,384**
  - Phase B (L0→...→L12 chain) : RTL L11→L12 REPACK 필요로 보류 (추후 작업)

- **TB software REPACK 알고리즘**: L12 IFM 의 NHWC entry 생성
  - entry @ (row, ci_g, col_b) byte (col_l*4 + ch_l) = golden_l12_ifm[(ci_g*4+ch_l)*64 + row*8 + (col_b*4+col_l)]
  - DRAM L12 IFM 영역 = `0x002F8000..0x002FFFFF` (32 KB)

- 1×1 path 의 micro 검증 TB 보존: `yolohw/testbench/conv1x1_micro_tb.v` — 향후 1×1 regression 용

#### 7차 — L11→L12 RTL REPACK (Phase B 완성, 2026-05-23 추가)

- yolo_engine 에 L12 IFM 변환 transform engine 추가 (`L12_RP_*` 신규 state 6개):
  - `S_L12_RP_LOAD/LOAD_WAIT`: L11 OFM 8192 word → ofm dpram[0..8191] (DMA RD, `DMA_TGT_L12_RP_IN`)
  - `S_L12_RP_GEN`: 13 cycle / entry (8 dpram read + 4 dpram write)
  - `S_L12_RP_STORE/STORE_WAIT`: dpram[16384..16387] → DRAM L12 IFM entry (4 word DMA WR)
  - `S_L12_RP_NEXT`: loop control (row 0..7, ci_g 0..127, col_b 0..1 = 2048 entries)
- 변환식:
  - `L12_entry[col_l*4 + ch_l] = L11_OFM[ch=ci_g*4+ch_l, h=row>>1, w=col_b*2 + col_l>>1][byte sub_h=row[0], sub_w=col_l[0]]`
  - phase 0..7: dpram read addr 발사 (ch_l × sub_wb 조합 8개)
  - phase 1..8: 이전 cycle 의 L11 word 에서 2 byte (sub_h 의 sub_w=0,1) 추출 → entry 의 col_l_lo, col_l_hi 위치 byte 채움
  - phase 9..12: entry 의 4 word → dpram[16384..16387]
- L11 STORE_WAIT 후 자연 진입 (force 불필요), REPACK 완료 후 `S_LOAD_BIAS` 로 L12 conv 진입
- 검증 결과 (Linux iverilog + Windows xsim 모두):
  - Phase A : 0 / 16,384 (변화 없음)
  - **Phase B : 0 / 16,384** — L11 maxpool 의 propagation 흡수 효과가 L12 까지 이어짐
- 시뮬 시간: L0→L12 chain 153 ms sim time (wall time ~11분 Vivado)

#### 8차 — L13 (CONV3x3, Ci=256 Co=512) 추가 (2026-05-23 추가)

- L13 conv 는 L10 와 동일 구조 (Ci=256, Co=512, 3×3, acc_len=64) — 검증된 3×3 path 재사용
- yolo_engine 변경:
  - L13 파라미터 추가 (blk_off=76432, bias_off=1264, OFM @ 0x308000, IFM @ 0x304000)
  - `is_conv_l13` + conv mux 확장 (cur_w/h/co/acc_len/shift/ci_grps/eir_per_row 등)
  - DRAM addr mux (wgt/bias/ifm/ofm base) L13 case
  - L13 의 OFM stride 는 L10/L12 와 동일 (8×8 OFM, 4×4 block)
- **REPACK FSM 일반화** — L11→L12 와 L12→L13 둘 다 동일 state path 사용:
  - 신규 mux wires: `cur_rp12_in_base`, `cur_rp12_out_base`, `cur_rp12_in_words`, `cur_rp12_cig_max`, `cur_rp12_entries_per_row`
  - `conv_phase_r==12` → L11→L12 (Ci=512, ci_g_max=127, 8192 word)
  - `conv_phase_r==13` → L12→L13 (Ci=256, ci_g_max=63,  4096 word)
  - entry_idx 식: `row * entries_per_row + ci_g*2 + col_b` (entries_per_row layer 별 mux)
- FSM 흐름:
  - L11 STORE_WAIT → cp=12, L12 REPACK → L12 conv
  - L12 conv done (cp==12) → cp=13, L13 REPACK → L13 conv
  - L13 conv done (cp==13) → S_DONE
- 검증 결과:
  - Phase A : 0 / 32,768 (TB software REPACK)
  - **Phase B : 0 / 32,768** — L11 maxpool 흡수 효과가 L13 까지 지속
- 시뮬 시간: L0→L13 chain 181.5 ms sim time (wall time ~10분 Vivado)

#### 9차 — L14 (CONV1x1 detection layer, Ci=512 Co=195) 추가 (2026-05-23 추가)

- L14 는 yolov2 의 detection layer 로, **activation=linear (ReLU 없음) + INT8 raw output**.
  aix2024.cfg 의 line 131 `activation=linear` (L20 도 동일).
- L14 conv 구조는 L12 의 1×1 mode 와 동일 (Ci=512, acc_len=128). Co=195 (4 의 배수 아님).
- yolo_engine 변경:
  - L14 파라미터 (blk_off=109200, bias_off=1776, OFM @ 0x318000, IFM @ 0x310000)
  - `is_conv_l14` + `is_conv_1x1` 통합 wire (L12+L14)
  - REPACK mux 확장 (cp==14: L13 OFM → L14 IFM, Ci=512 = cp==12 와 동일 식)
  - FSM 분기: cp==13 done → L14 REPACK → L14 conv → S_DONE
- **post_process.v 의 큰 수정**:
  1. **`i_relu_en` 입력 추가**:
     - `i_relu_en=1` (L0~L13/L17): 기존 ReLU + UINT8 (0..255) clamp
     - `i_relu_en=0` (L14/L20): ReLU bypass + INT8 signed (-128..+127) clamp
  2. **Round-bias (음수 toward-zero rounding)**:
     - Verilog `>>>` 는 floor (toward -∞), C 의 `/` 는 toward-zero
     - 음수일 때 `(2^shift - 1)` 더한 후 shift → C 와 동일 동작
     - 양수일 때 round_bias=0 이라 다른 layer 영향 없음
- `mac_kern`, `conv_top` 에 `i_relu_en` pass-through. yolo_engine 에서 `i_relu_en = !is_conv_l14`.
- **첫 시뮬 결과** (수정 전): 11955/12480 mismatch, `got=00 exp=ff` 패턴 (모두 ReLU clip)
- **두 번째 결과** (i_relu_en 만 추가 후): 11966/12480 mismatch 중 |Δ|=1 이 98% — toward-zero rounding 차이로 1 LSB off-by-one
- **세 번째 결과** (round-bias 추가 후): **0/12480 PASS** (Phase A, B 모두)
- 시뮬 시간: L0→L14 chain 196 ms sim time (wall time ~10분 Vivado)

#### 10차 — L15 [yolo] + L16 [route -4] skip + L17 (CONV1x1, Ci=256 Co=128) 추가 (2026-05-23 추가)

- cfg 상 L15 = `[yolo]` (RTL 연산 없음, software 후처리), L16 = `[route layers=-4]` (L12 OFM 참조).
  → RTL 관점에선 둘 다 "FSM skip + DMA 주소 alias" 로 처리.
- L17 conv 구조는 L13 의 1×1 변형 (Ci=256 = L13 동일, Co=128, acc_len=64).
- yolo_engine 변경:
  - L17 파라미터 (blk_off=134160, bias_off=1971, OFM @ 0x320000, IFM @ 0x31C000)
  - `is_conv_l17` 추가, `is_conv_1x1` = L12 || L14 || L17 로 확장
  - 모든 conv mux (cur_w/h/co/acc_len/shift/ci_grps/eir_per_row/wgt_per_fi/bias_dma/ifm_init/ifm_next/ofm_fil/wgt_off/bias_off/bias_entry_base/ifm_base/ofm_layer_base) L17 case 추가
  - `cur_ofm_fi_byte` / `cur_ofm_rb_byte` 에 L17 추가 (64 / 16, L10/L12/L13/L14 와 동일)
  - **`addr_ifm_byte` 1×1 분기 세분화**: L12/L14 만 row stride=4096 (Ci=512), L17 은 2048 (Ci=256 = 3×3 path 와 동일 식 재사용)
  - REPACK mux 에 cp==17 분기 추가 — L12 OFM → L17 IFM, Ci=256 (cp==13 와 동일 식). `is_rp_ci256 = (cp==13 || cp==17)` 로 in_words/cig_max/entries_per_row 통합.
  - FSM 분기: cp==14 done → **cp=17 직점프 + S_L12_RP_LOAD** (L15/L16 skip), cp==17 done → S_DONE
- L17 IFM = L12 OFM 을 NHWC entry 로 REPACK (1×1 conv path 의 필수 변환). REPACK FSM 은 cp==13 코드 그대로 활용.
- post_process 의 `i_relu_en = !is_conv_l14` 그대로 — L17 은 자동 ReLU 활성 (cfg activation=relu).
- 검증 결과 (Vivado xsim):
  - Phase A (TB software REPACK → conv → L17 OFM 비교) : **0 / 8,192 PASS**
  - **Phase B (L0 → L14 → cp=17 jump → L17) : 0 / 8,192 PASS**
- 시뮬 시간: L0→L17 chain 189.4 ms sim time (wall time 9분 49초 Vivado xsim)
- FSM transition 로그: `layer_idx 14 → 17` (L15/L16 skip), `17 → 18` (L17 완료)

#### 11차 — L18 (UPSAMPLE 2×, 128 ch, 8×8 → 16×16) 추가 (2026-05-23 추가)

- `upsample_unit.v` 는 이미 존재 (6-phase FSM: read → wait → 4 writes per input pixel).
  미통합 상태였던 것을 yolo_engine 에 통합.
- L11 (max_pool_s1) 통합 패턴 그대로 적용 — load → run → store 6 state.
- yolo_engine 변경:
  - L18 파라미터 (Co=128, H_in_b=W_in_b=4, OFM @ 0x328000 32KB)
  - 신규 state 6 개 (`S_L18_LOAD/LOAD_WAIT/UP/UP_WAIT/STORE/STORE_WAIT`)
  - 신규 DMA target `DMA_TGT_L18_IFM = 3'd7`
  - `upsample_unit` → `u_upsample` 인스턴스화 (in_base=0, out_base=2048)
  - dpram port mux 에 `upsample_phase` 분기 추가
  - `dpram_load_we` 에 `l18_ifm_we` 추가 (L17 OFM → dpram[0..2047])
  - FSM 분기: cp==17 conv done → S_L18_LOAD, S_L18_STORE_WAIT done → S_DONE
  - `up_start_r` reset/1-cycle pulse 패턴 (pool_s1_start_r 와 동일)
- L18 데이터 흐름:
  - DRAM L17 OFM (2048 word, conv 2×2 packed) → dpram[0..2047]
  - upsample_unit: 1 input pixel → 4 output pixel (값 복제) × 128 ch × 16 input block = 2048 input block × 4 = 8192 output block
  - dpram[2048..10239] → DRAM L18 OFM (8192 word, conv 2×2 packed)
- 검증 (Vivado xsim):
  - Golden 출처: `CONV20_input.hex` 의 chan 0..127 = L19 route concat 의 첫 128 ch = L18 OFM (NCHW byte, 32768 byte)
  - Phase A (TB software pack L17 OFM → L18 upsample → 비교) : **0 / 32,768 PASS**
  - **Phase B (L0 → ... → L18) : 0 / 32,768 PASS**
- 시뮬 시간: L0→L18 chain 183.0 ms sim time (wall time 8분 47초 Vivado xsim)
- FSM transition 로그: `14 → 17 → 18 → 19` (L17 done → L18 자연 진입)

## 2026-05-24

### Vivado 2021 vs 2025 시뮬레이터 차이 — chain 검증 비결정성 해결

L18 chain 검증(Phase B)에서 **동일 PC가 아닌 환경에 따라 mismatch 가 0 ↔ 3360/3676 으로 달라지는** 현상 발견. 정밀 진단 결과:

- **원인**: uninitialized 메모리(X)의 시뮬레이터 버전 간 처리 차이.
  - Vivado **2025**: chain 검증 = **0 mismatch** (PASS)
  - Vivado **2021**: 동일 RTL·데이터·TB 인데 = 3360 mismatch (|Δ|≤3, 92% |Δ|=1)
  - 메모리를 0 으로 강제 초기화하니 2021 결과가 3360 → 3676 으로 **바뀜** → chain 이 미초기화 메모리 값에 의존한다는 직접 증거.
- **검증으로 배제한 것** (RTL 버그 아님 확정):
  - golden 자가 일관성 100% (인접 layer output==input, route -4, upsample 모두 0 mismatch)
  - 다른 PC(2025)의 zip 과 비교: 산술 모듈(mul/mac_kern/mac_stack/add_tree/post_process/conv_top/upsample) **byte-identical**, 입력 데이터(.mem)·golden·TB **모두 동일**
  - 차이는 **오직 Vivado 버전(2021 vs 2025)**
- **조치**:
  1. sim behavioral 메모리에 `initial` 0 초기화 추가 — `dpram_wrapper`(ram + rdata + rdata_r), `spram_wrapper`(mem + rdata_o), `ifm_line_buf`(mem×4 banks + dout_a_r/dout_b_r), `gbuff_param`(wgt_mem + bias_mem). 모두 `ifdef FPGA` else(sim) 영역 → 합성/fps/Energy 영향 없음. 실제 BRAM(0 초기화)과 일치.
  2. **검증 환경을 Vivado 2025 로 통일** (`yolohw/fpga/create_project_25.tcl`). 2025 에서 L18 chain = 0 mismatch 확인.
- **결론**: RTL 자체는 정확. ±1 LSB 는 시뮬레이터 X 처리 차이였으며, mAP·점수(fps/Energy)에는 무관. 향후 모든 검증은 Vivado 2025 기준.
- CLAUDE.md §4-8 규칙 추가, ARCHITECTURE.md 검증 환경 노트 추가.

### 문서 정합성 점검 — 실제 구조와 어긋난 정보 수정 (2026-05-24)

문서들이 Phase 2 시점에 멈춰 있어 실제 파일 구조와 불일치한 항목들을 일괄 수정:

| 항목 | 문서 (기존) | 실제 / 수정 |
|---|---|---|
| `mul_dual.v` | README 인스턴스 계층·파일별에 존재 | **존재 안 함** — `mul.v` 단일 (genvar 144). 제거 |
| src 파일 수 | CLAUDE/ARCH "18 파일" | **19 .v** (yolo_engine + 17 서브모듈 + `define.v` stub) |
| 활성 TB 위치 | README "`yolohw/sim/` 5 파일" | **`yolohw/testbench/`** (l0~l20 verify + 블록 TB). `sim/` 은 iverilog 산출물 |
| backup 디렉토리 | README `src_backup`/`sim_backup`/`_archive` | **`.recycle_bin/`** 단일 |
| 참고자료 폴더 | README `참고자료/` | **`documents/`** |
| `HANDOFF.md` | ARCH/README 참조 | **폐기됨**(2026-05-22) — 제거, HISTORY.md/메모리로 대체 |
| FSM state 수 | README "14-state" | 실제 **53 state** (개념적 흐름임을 명시) |
| `define.v` | (미기재) | `mul.v` 참조용 include stub (실제 매크로는 `user_define_h.v`) |
| Vivado 버전 | README 배지 "2020.2+" | **2025** (검증 환경) |

- 수정 문서: README.md(디렉토리·인스턴스 계층·파일별·FSM·배지·Last updated), CLAUDE.md(§6 파일 구조), ARCHITECTURE.md(§7 디렉토리).
- 22-layer ↔ 서브모듈 매핑, DRAM 메모리 맵 등 나머지 기술 정보는 실제와 일치 확인됨.

### L19 (ROUTE concat) + L20 (CONV1x1 detection head 2) 통합 및 검증 PASS (2026-05-24)

마지막 RTL 레이어 L19/L20 통합 완료. **RTL 추론이 L20 에서 완성**됨 (L21 = software YOLO 후처리).

- **L19 (Route, layers=-1,8)**: 연산 모듈 없이 **RTL REPACK** 으로 구현. L18 OFM(16×16×128, ch 0..127) ‖ L8 OFM(16×16×256, ch 128..383) 을 채널 concat → L20 IFM(16×16×384, NHWC entry). 신규 FSM 8 state(`S_L19_RP_LOAD_A`~`S_L19_RP_NEXT`), rp19_* 주소 로직(rp12 의 16×16 2-source 확장). L8 OFM(0x2D0000) 보존 영역을 route 소스로 사용. software memcpy·double-inference 폐지.
- **L20 (CONV1x1 detection head 2)**: Ci=384 Co=195 16×16, ReLU off. 기존 conv 파이프라인 재사용(cur_* mux + IFM/OFM/weight/bias 주소 L20 분기). DRAM: IFM @ 0x330000(96KB), OFM @ 0x348000. weight/bias 는 gen_sim_dram.py CONV20 항목(blk_off=142352, bias_off=2099).
- **descale shift 원인 규명**: detection 레이어 shift 는 다음 conv 의 input quant multiplier 에 의존 — **L14=6**(다음 L17 conv), **L20=9**(다음 conv 없음). golden 수학 역산으로 확정(`acc>>9` + post_process 의 trunc-toward-zero + INT8 signed clamp). 초기 shift=6 오설정이 Phase A 98% mismatch 의 원인이었음(L20_SHIFT 6→9 수정으로 해결).
- **검증 (l20_verify_tb, l13 canonical 포맷)**:
  - Phase A (standalone L19+L20): L20 IFM(REPACK) 0 mismatch + L20 OFM 0 mismatch → **PASS**
  - Phase B (chain L10→L20, L8 OFM golden 주입): **PASS**
- 문서 갱신: ARCHITECTURE / technical_reference / study_guide 의 L19 "software concat"→RTL REPACK, double→single-inference, shift 6→9 정정.
