# 20장. Layer별 / 블록 Testbench

> [← 19장 검증 전략](19_testbench_strategy.md) · [목차](README.md) · 다음 장: [21장 Vivado 프로젝트 →](21_vivado_project.md)
> **이 장을 읽기 위한 준비**: [19장 검증 전략](19_testbench_strategy.md).

---

[19장](19_testbench_strategy.md)의 검증 인프라로, 실제 각 TB가 무엇을 검증하고 어떤 결과를 냈는지 봅니다. 결과의 1차 출처는 [HISTORY.md](../../HISTORY.md)입니다.

---

## 20.1 Layer verify TB 목록

[yolohw/testbench/](../../yolohw/testbench/)의 verify TB와 검증 대상입니다.

| TB | 레이어 | 연산 | 검증 포인트 |
|----|--------|------|-------------|
| l0 | L0 | Conv3×3 | 가중치 streaming, 첫 레이어 |
| l1 | L1 | Pool/2 | max_pool_unit |
| l2 | L2 | Conv3×3 | REPACK(풀링→합성곱) |
| l5 | L5 | Pool/2 | L0~L5 chain |
| l10 | L10 | Conv3×3 | REPACK, Ci=256 |
| l11 | L11 | **Pool/1** | max_pool_s1, same-padding |
| l12 | L12 | Conv1×1 | 1×1 모드, REPACK |
| l13 ★ | L13 | Conv3×3 | **canonical** TB |
| l14 | L14 | Conv1×1 | **검출 헤드** (linear) |
| l17 | L17 | Conv1×1 | L15/L16 스킵 |
| l18 | L18 | Upsample | upsample_unit |

> 새 패턴이 등장하는 레이어마다 TB를 추가했습니다. 같은 패턴(L4·L6·L8은 L2와 동일)은 대표 TB로 검증합니다.

---

## 20.2 검증 결과 — L11이 마법을 부린다

[HISTORY.md](../../HISTORY.md)의 결과입니다. **모든 단독(Phase A)이 0 mismatch → RTL 자체 버그 없음.**

| TB | Phase A | Phase B (chain) | 해석 |
|----|---------|-----------------|------|
| l0 | (없음) | 22 | skeleton 산술 차이 |
| l1 | 0 | 8 | L0 오차 전파 |
| l2 | 0 | 52 | 합성곱 확산 |
| l5 | 0 | 22 | L2 일부 |
| l10 | 0 | 660 | 10층 누적 (≈2%) |
| **l11** | **0** | **0** | ★ 풀링이 오차 흡수! |
| **l12~l18** | **0** | **0** | 흡수 효과 지속 ✅ |

### 🔑 왜 L11을 지나면 chain mismatch가 0이 되나

L0~L10 chain에는 ±1 LSB 오차가 쌓입니다(skeleton float 산술 vs RTL 정수, [2장 2.10](02_quantization_basics.md)). 그런데 **L11(max pooling)을 지나면 0이 됩니다.**

```
L10 출력: 어떤 픽셀이 골든보다 1 작음 (예: 골든 200, RTL 199)
   ↓ max pooling (주변 4개 중 최댓값)
   주변에 더 큰 값(예: 205)이 있으면 → 205가 선택됨
   → ±1 오차가 있던 199는 가려져 사라짐 → 결과 동일!
```

[1장 1.7](01_cnn_basics.md)에서 예고한 대로, max는 "주변 최댓값"만 남기므로 작은 오차가 더 큰 이웃에 묻힙니다. 이 흡수 효과가 L11 이후(L12~L18) 내내 지속됩니다.

> 💡 그래서 L0~L10의 chain mismatch(8, 52, 660 등)는 **걱정할 필요 없는 양자화 noise**입니다(모두 tol-exceed=0, 즉 |d|≤1). [19장 19.5](19_testbench_strategy.md)의 delta 분포로 이를 확인합니다.

---

## 20.3 주요 TB 깊이 보기

### l11 — stride-1 풀링과 가짜 PASS 방지

`max_pool_s1_unit`([16장 16.3](16_rtl_special_units.md))의 same-padding을 검증합니다. "혹시 우연히 PASS한 건 아닌가"까지 의심해서, golden/DRAM의 non-zero 비율(golden 75%, DRAM 88%)과 packed↔채널순서 수동 디코딩까지 대조했습니다([HISTORY 5차](../../HISTORY.md)). chain 오차를 0으로 흡수하는 지점이라 특히 꼼꼼히 검증했습니다.

### l14 — 검출 헤드 디버깅 (delta 분포 활용의 모범)

L14·L20은 `activation=linear`(ReLU 없음)라 INT8 raw 출력입니다([6장 6.5](06_yolo_basics.md)). 검출 헤드를 정확히 만들려면 **세 가지**가 모두 맞아야 했고, 디버깅 과정이 교육적입니다([HISTORY 9차](../../HISTORY.md), [메모리](../../HISTORY.md)).

```
① ReLU off (i_relu_en=0):
   수정 전 → got=00 exp=ff (ReLU가 음수를 0으로 만든 버그)
   → post_process에 i_relu_en 추가

② toward-zero rounding:
   ① 후 → |d|=1이 98% (C 나눗셈 vs Verilog 시프트 차이)
   → round_bias 보정 추가 ([2장 2.7])

③ 올바른 descale shift:
   L14=6 (다음 conv L17 존재), L20=9 (다음 conv 없음)
   → L20_SHIFT를 6→9로 정정 ([9장 9.4])

세 가지 모두 적용 → 0 mismatch PASS
```

> 🔑 [19장 19.5](19_testbench_strategy.md)에서 본 **delta 분포가 버그 종류를 정확히 가리킨** 사례입니다: `got=00 exp=ff` → ReLU 문제, `|d|=1 98%` → rounding 문제. 그리고 검출 헤드인데도 L14(shift 6)와 L20(shift 9)이 다른 이유는 다음 합성곱 유무 때문입니다([2장 2.6](02_quantization_basics.md)).

### l17 — 레이어 스킵 검증

L15(yolo)·L16(route)는 RTL 연산이 없어, FSM이 L14 다음에 **L15·L16을 건너뛰고 L17로 직행**합니다([13장 13.10](13_rtl_yolo_engine_top.md)). Phase B 로그에 `layer_idx 14 → 17`이 찍히는 것으로 스킵 정확성을 확인합니다.

---

## 20.4 블록 TB — 모듈 하나씩

단일 모듈을 격리 검증합니다.

| TB | 검증 모듈 | 핵심 |
|----|-----------|------|
| `mul_tb` | `mul` | INT8 곱셈, 부호 처리 |
| `conv_top_tb` | `conv_top` 등 | 합성곱 엔진 통합 — Phase 2에서 mismatch 31→0 |
| `pool_tb` / `pool_s1_tb` | 풀링 | max-of-4 / stride-1 |
| `upsample_tb` | `upsample_unit` | 2× 복제 |
| `ifm_line_buf_tb` | `ifm_line_buf` | 윈도우 패킹 |
| `dpram_tb` / `spram_tb` | 메모리 | read/write |
| `axi_dma_rd/wr_tb` | DMA | burst |
| `conv1x1_micro_tb` | 1×1 경로 | Ci=4 Co=1 회귀 테스트 |

> `conv1x1_micro_tb`는 [15장 15.1.1](15_rtl_memory_buffers.md)의 1×1 채널 패킹 버그를 고친 뒤, 재발 방지를 위해 보존한 소규모 회귀 테스트입니다(Ci=4, Co=1, 4×4).

---

## 20.5 빠른 검증 — iverilog

Vivado 외에 리눅스 iverilog로 문법/elaboration을 빠르게 확인할 수 있습니다(FPGA 매크로 off):

```bash
# yolohw 디렉토리에서
iverilog -g2012 -I src -s <module> -o /tmp/<m>.vvp src/*.v testbench/<tb>.v
```

단, 정밀 chain 검증(0 mismatch 판정)은 [Vivado 2025](21_vivado_project.md)에서 합니다([4장 4.7](04_rtl_timing_basics.md)의 X 처리 차이 때문).

---

## 20.6 이 장의 요약

- verify TB는 새 패턴 레이어마다 추가(L0,1,2,5,10,11~14,17,18). 모든 Phase A가 0 mismatch → **RTL 버그 없음**.
- L0~L10 chain의 ±1 LSB는 양자화 noise(tol-exceed=0). **L11 max pooling이 이를 0으로 흡수**, L12~L18까지 지속.
- l14 검출 헤드는 ① ReLU off ② toward-zero ③ 올바른 shift(L14=6, L20=9) 세 가지가 모두 맞아야 PASS — delta 분포가 버그를 가리킨 모범 사례.
- 블록 TB(mul/conv_top/pool/upsample/line_buf/dpram/dma)와 conv1x1_micro(회귀)로 모듈 단위 검증.

다음 장에서는 이 RTL을 합성·시뮬하는 **Vivado 프로젝트**를 봅니다.

---

> [← 19장 검증 전략](19_testbench_strategy.md) · [목차](README.md) · 다음 장: [21장 Vivado 프로젝트 →](21_vivado_project.md)
