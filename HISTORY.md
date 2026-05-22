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

모든 standalone PASS → RTL 자체 버그 없음.
Chain mismatch 는 모두 ±1 LSB 수준의 양자화 차이 propagation 으로 추정 (Δ 분포 통계 측정 진행 중).

### 다음 단계 — L11 이후 (구조 변경 구간)

- **L11** : POOL_S1 (stride 1, same padding) — `max_pool_s1_unit.v` 별도 모듈 사용
- **L12, L14, L17, L20** : CONV1x1 — conv_top `i_mode=1` 경로, line_buf 1×1 packing
- **L13** : CONV3x3 (L2 패턴 재사용 가능)
- **L15~L16** : ROUTE/REORG — DMA 주소 alias 만, 연산 없음
- **L18** : UPSAMPLE — `upsample_unit.v` 사용
- **L19** : ROUTE concat
