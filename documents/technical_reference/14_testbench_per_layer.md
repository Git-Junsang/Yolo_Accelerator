# 14장. Layer별 / 블록 Testbench

> [← 13장 검증 전략과 인프라](13_testbench_strategy.md) · [목차](README.md) · [15장 Vivado 프로젝트 →](15_vivado_project.md)

---

[13장](13_testbench_strategy.md)에서 본 검증 인프라를 바탕으로, 이 장은 **실제로 존재하는 각 TB가 무엇을 검증하고 어떤 결과를 냈는지**를 정리합니다. 검증 현황의 1차 출처는 [HISTORY.md](../../HISTORY.md)입니다.

---

## 14.1 Layer verify TB 매핑

[yolohw/testbench/](../../yolohw/testbench/)의 verify TB와 각자의 검증 대상입니다.

| TB | 레이어 | 연산 | 검증 포인트 | Phase A 입력 |
|----|--------|------|-------------|--------------|
| [l0_verify_tb](../../yolohw/testbench/l0_verify_tb.v) | L0 | CONV3×3 (3→16) | streaming weight DMA, 첫 레이어 | (chain만) |
| [l1_verify_tb](../../yolohw/testbench/l1_verify_tb.v) | L1 | POOL_S2 (16ch) | max_pool_unit, L0→L1 | L0 OFM golden |
| [l2_verify_tb](../../yolohw/testbench/l2_verify_tb.v) | L2 | CONV3×3 (16→32) | REPACK(pool→conv), NHWC | L1 OFM golden |
| [l5_verify_tb](../../yolohw/testbench/l5_verify_tb.v) | L5 | POOL_S2 (64ch) | L0~L5 chain | L4 OFM golden |
| [l10_verify_tb](../../yolohw/testbench/l10_verify_tb.v) | L10 | CONV3×3 (256→512) | REPACK, Ci=256 | L10 IFM golden |
| [l11_verify_tb](../../yolohw/testbench/l11_verify_tb.v) | L11 | **POOL_S1** | max_pool_s1_unit, same-padding | L10 OFM golden |
| [l12_verify_tb](../../yolohw/testbench/l12_verify_tb.v) | L12 | CONV1×1 (512→256) | 1×1 mode, L11→L12 REPACK | L12 IFM golden |
| [l13_verify_tb](../../yolohw/testbench/l13_verify_tb.v) ★ | L13 | CONV3×3 (256→512) | **canonical**, L12→L13 REPACK | L13 IFM golden |
| [l14_verify_tb](../../yolohw/testbench/l14_verify_tb.v) | L14 | CONV1×1 (512→195) | **검출 헤드** (linear, INT8 raw) | L13 OFM golden |
| [l17_verify_tb](../../yolohw/testbench/l17_verify_tb.v) | L17 | CONV1×1 (256→128) | L15/L16 skip, L12→L17 REPACK | L17 IFM golden |
| [l18_verify_tb](../../yolohw/testbench/l18_verify_tb.v) | L18 | **UPSAMPLE 2×** | upsample_unit, 8×8→16×16 | L17 OFM golden |
| [l20_verify_tb](../../yolohw/testbench/l20_verify_tb.v) | L20 | ROUTE + CONV1×1 | L19 concat, 검출 헤드2 (진행 중) | L18‖L8 |

> verify TB가 L0,1,2,5,10,11~14,17,18만 있는 이유: 같은 구조의 레이어(예: L4·L6·L8은 L2와 동일한 3×3+REPACK 패턴)는 대표 TB로 검증하고, 새 패턴이 등장하는 레이어마다 TB를 추가했기 때문입니다(HISTORY의 점진적 개발).

---

## 14.2 검증 결과 종합 (Vivado 2025 기준)

[HISTORY.md](../../HISTORY.md)의 layer-by-layer 결과입니다. **모든 standalone(Phase A)이 0 mismatch → RTL 자체 버그 없음.**

| TB | Phase A | Phase B (chain) | 해석 |
|----|---------|-----------------|------|
| l0 | (해당없음) | 22 | skeleton 산술 정의 차이 |
| l1 | 0 | 8 | L0 propagation (pool reduce) |
| l2 | 0 | 52 | conv 3×3 spread |
| l5 | 0 | 22 | L2 OFM 일부 |
| l10 | 0 | 660 | 10 layer 누적 (≈2%) |
| **l11** | **0** | **0** | maxpool이 propagation 흡수 ✅ |
| **l12** | **0** | **0** | CONV1×1 + REPACK ✅ |
| **l13** | **0** | **0** | CONV3×3 + REPACK ✅ |
| **l14** | **0** | **0** | 검출 헤드 (linear) ✅ |
| **l17** | **0** | **0** | L15/L16 skip + CONV1×1 ✅ |
| **l18** | **0** | **0** | UPSAMPLE 2× ✅ |

핵심 관찰:
- **L0~L10 chain의 mismatch는 모두 ±1 LSB 양자화 noise**(skeleton float 산술 vs RTL 정수)의 누적 전파입니다. tol-exceed(|d|>1)는 0이므로 PASS입니다.
- **L11(maxpool)을 지나면 chain mismatch가 0으로 흡수**됩니다. maxpool이 인접 픽셀 중 최댓값만 취하므로, ±1 차이가 있던 픽셀이 더 큰 이웃에 가려지기 때문입니다. 이 효과가 L11 이후(L12~L18) 내내 지속되어 chain도 exact 0이 됩니다.

---

## 14.3 주요 verify TB 상세

[13장](13_testbench_strategy.md)의 l13(canonical) 외에, 특징적인 TB들을 짚습니다.

### l0_verify_tb — 첫 레이어, chain만

L0는 네트워크 첫 레이어라 "이전 레이어 출력"이 없습니다. 따라서 Phase A(standalone)가 없고, 입력 이미지에서 시작하는 단일 검증입니다. streaming weight DMA(필터별 가중치 적재)의 정확성을 봅니다. 22 mismatch는 skeleton C의 첫 양자화 단계 정의 차이로, 이후 모든 chain mismatch의 근원이 됩니다.

### l11_verify_tb — stride-1 pool 검증

`max_pool_s1_unit`([10장 10.3](10_rtl_special_units.md))의 same-padding 동작을 검증합니다. 가짜 PASS 가능성까지 확인한 유일한 TB로, golden/DRAM의 non-zero 비율(golden_l11=75%, DRAM L11 OFM=88%)과 packed↔NCHW 수동 디코딩까지 대조했습니다([HISTORY 5차](../../HISTORY.md)). chain이 L10의 660 mismatch를 0으로 흡수하는 지점입니다.

### l14_verify_tb — 검출 헤드 (디버깅 사례)

L14는 `activation=linear`라 ReLU·재양자화가 없고 INT8 raw로 출력합니다([4장 4.5](04_network_architecture.md)). 이 TB는 **디버깅 과정 자체가 교훈적**입니다([HISTORY 9차](../../HISTORY.md)):
1. 1차(수정 전): 11955/12480 mismatch, `got=00 exp=ff` → ReLU가 음수를 0으로 만든 버그.
2. 2차(i_relu_en 추가): 11966 중 98%가 `|d|=1` → toward-zero rounding 차이.
3. 3차(round-bias 추가): **0/12480 PASS**.

이 사례는 delta 분포([13장 13.7](13_testbench_strategy.md))가 어떻게 버그 종류를 가리키는지 보여줍니다.

### l17_verify_tb — 레이어 skip 검증

L15([yolo])·L16([route -4])는 RTL 연산이 없으므로, FSM이 `cp==14 done → cp=17 직점프`로 건너뜁니다([7장 7.11](07_rtl_yolo_engine_top.md)). 이 TB의 Phase B 로그에 `layer_idx 14 → 17`(L15/L16 skip)이 찍히는 것으로 skip 정확성을 확인합니다.

### l18_verify_tb — upsample, golden 출처

L18 golden은 별도 파일이 없어, `CONV20_input.hex`의 채널 0~127(= L19 concat의 첫 128ch = L18 OFM)을 golden으로 씁니다([HISTORY 11차](../../HISTORY.md)). `upsample_unit`의 2× 복제를 32768 byte 단위로 검증합니다.

---

## 14.4 블록 TB

단일 모듈을 격리 검증하는 블록 TB([yolohw/testbench/](../../yolohw/testbench/)):

| TB | 검증 모듈 | 핵심 |
|----|-----------|------|
| [mul_tb](../../yolohw/testbench/mul_tb.v) | `mul` | INT8×INT8 → INT16, 부호 처리 |
| [conv_top_tb](../../yolohw/testbench/conv_top_tb.v) | `conv_top` (+mac_kern+line_buf+gbuff) | conv 산술 엔진 통합 — Phase 2에서 mismatch 31→0 확인 |
| [pool_tb](../../yolohw/testbench/pool_tb.v) | `max_pool_unit` | stride-2 max-of-4 |
| [pool_s1_tb](../../yolohw/testbench/pool_s1_tb.v) | `max_pool_s1_unit` | stride-1 same-padding |
| [upsample_tb](../../yolohw/testbench/upsample_tb.v) | `upsample_unit` | 2× nearest-neighbor |
| [ifm_line_buf_tb](../../yolohw/testbench/ifm_line_buf_tb.v) | `ifm_line_buf` | 윈도우 패킹, cyclic row |
| [dpram_tb](../../yolohw/testbench/dpram_tb.v) | `dpram_wrapper` | dual-port read/write |
| [spram_tb](../../yolohw/testbench/spram_tb.v) | `spram_wrapper` | single-port read/write |
| [axi_dma_rd_tb](../../yolohw/testbench/axi_dma_rd_tb.v) | `axi_dma_rd` | burst read |
| [axi_dma_wr_tb](../../yolohw/testbench/axi_dma_wr_tb.v) | `axi_dma_wr` | burst write |
| [conv1x1_micro_tb](../../yolohw/testbench/conv1x1_micro_tb.v) | 1×1 path | Ci=4, Co=1, 4×4 micro 회귀 테스트 |

### conv1x1_micro_tb — 1×1 회귀 테스트

[6장 6.3](06_data_representation_memory_map.md)의 1×1 채널 패킹 버그를 수정한 뒤, 향후 회귀를 막기 위해 보존된 소규모 TB입니다(Ci=4, Co=1, H=W=4). 1×1 mode의 offset/col_inblk 매핑과 채널 정렬을 최소 데이터로 검증합니다([HISTORY 6차](../../HISTORY.md)).

---

## 14.5 nonstreaming 변종과 전체 통합 TB

### nonstreaming 변종

[l0_nonstreaming_verify_tb](../../yolohw/testbench/l0_nonstreaming_verify_tb.v), `l1_nonstreaming`, `l2_nonstreaming`은 **구 RTL(weight 일괄 적재 방식) 전용**입니다. 현재 RTL은 streaming weight DMA로 통일되었으므로([HISTORY 2차](../../HISTORY.md)), 이 변종들은 현재 `src/`로는 컴파일되지 않으며 로그 포맷 통일만 적용된 보존 파일입니다.

### yolo_engine_tb / yolo_engine_golden_tb

[yolo_engine_tb](../../yolohw/testbench/yolo_engine_tb.v)는 22-layer end-to-end 통합 TB로, `ap_start` → `network_done` 완주와 일부 OFM을 검증합니다(Phase 2에서 22-layer 완주 + non-zero OFM 확인). [yolo_engine_golden_tb](../../yolohw/testbench/yolo_engine_golden_tb.v)는 golden 대조 버전입니다. 이들은 `sim_dram_model`([13장 13.5](13_testbench_strategy.md))과 함께 보드에 가까운 환경을 모델링합니다.

---

## 14.6 iverilog 컴파일 검증

verify TB는 Vivado 외에 Linux iverilog로도 빠르게 문법/elaboration 확인할 수 있습니다(FPGA 매크로 off 상태):

```bash
# yolohw 디렉토리에서
iverilog -g2012 -I src -s <module> -o /tmp/<m>.vvp src/*.v testbench/<tb>.v
```

단, 정밀 chain 검증(0 mismatch 판정)은 [Vivado 2025](15_vivado_project.md)에서 수행합니다(시뮬레이터 X 처리 차이 때문).

---

## 14.7 이 장의 요약

- verify TB는 새 패턴이 등장하는 레이어마다 추가되었고(L0,1,2,5,10,11~14,17,18), 같은 패턴 레이어는 대표 TB로 검증.
- 모든 Phase A(standalone)가 0 mismatch → **RTL 자체 버그 없음**. L0~L10 chain의 ±1 LSB는 양자화 noise이며 tol-exceed 0.
- **L11 maxpool이 chain mismatch를 0으로 흡수**, 그 효과가 L12~L18까지 지속되어 chain도 exact 0.
- l14(검출 헤드) 디버깅은 delta 분포가 버그 종류를 가리킨 모범 사례(ReLU clip → toward-zero → 0 mismatch).
- 블록 TB(mul/conv_top/pool/upsample/line_buf/dpram/dma)와 conv1x1_micro(회귀)로 모듈 단위 검증, yolo_engine_tb로 22-layer 완주 확인.

다음 장에서는 이 RTL을 합성·시뮬레이션하는 **Vivado 프로젝트 구성**을 다룹니다.

---

> [← 13장 검증 전략과 인프라](13_testbench_strategy.md) · [목차](README.md) · [15장 Vivado 프로젝트 →](15_vivado_project.md)
