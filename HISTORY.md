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
