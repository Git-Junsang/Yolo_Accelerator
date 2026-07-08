# YOLOv2 FPGA Accelerator

[English](README.md) | **한국어**

---

**22-layer YOLOv2 객체 검출기를 단일 Artix-7 FPGA SoC 로 추론**

---

## 1. 배경

실시간 객체 검출은 보통 GPU 에 의존하지만, 에너지 예산 때문에 엣지에서는 비현실적입니다. 본 프로젝트는 22-layer YOLOv2 검출기 전체를 단일 Artix-7 FPGA 에 이식하여, 모든 convolution·pooling·upsample·route 를 온칩에서 처리하고 가벼운 후처리만 소프트웨어에 남깁니다.

- **모델**: 22-layer YOLOv2 (tiny 변형), INT8 양자화, 2 개 검출 헤드 (8×8 / 16×16 격자)
- **엔진**: 144-MAC output-stationary 데이터패스 (`36 mul × 4 spatial`) 하나로 모든 convolution 을 재사용 처리
- **단일 패스 추론**: 하나의 FSM 이 22-layer 전체 (Conv 3×3/1×1, MaxPool s2/s1, Upsample, Route) 를 layer 당 host 왕복 없이 순회
- **점수 공식** — 에너지 우선 대회입니다:

  ```
  Score = 10⁴ / Energy × ReLU(mAP − 0.2) × ReLU(fps − 5)
  ```

  목표: Nexys A7-100T 에서 **≥ 5 fps**, **mAP > 0.2** 를 만족하며 에너지 최소화.

> **중앙대학교 AIX2026 Deep Learning Hardware 설계 경진대회** 출품작 (팀 베타트론).

---

## 2. 시스템 구성

하드웨어가 모든 텐서 연산을 수행하고, 소프트웨어는 YOLO 검출 헤드 연산(sigmoid / softmax / NMS)만 담당합니다.

| 구성 요소             | 역할                                                                             |
| --------------------- | -------------------------------------------------------------------------------- |
| Host PC (`host.py`) | UART 로 이미지·가중치 업로드, YOLO 후처리(sigmoid/softmax/NMS), 검출 결과 표시  |
| MicroBlaze (Vitis)    | 가속기 제어, DMA 트리거, Host PC ↔`yolo_engine` UART 브리지                   |
| `yolo_engine` (RTL) | 22-layer 자동 추론 — Conv/Pool/Upsample/Route + 144-MAC 어레이 + AXI master DMA |
| DDR2 (~4 MB)          | 가중치 + bias, 입력 이미지(L0 IFM), 모든 layer OFM (offset 테이블)               |

**역할 분담**

- **하드웨어 (RTL)**: Conv (3×3, 1×1), Bias + Descaling, ReLU, MaxPool (stride 2 / stride 1), Upsample 2×, **Route** (L16/L19 concat 을 `yolo_engine` FSM 이 DMA/REPACK 단계로 자동 처리 — software `memcpy` 불필요)
- **소프트웨어 (MicroBlaze + Host PC)**: 가속기 제어, DMA 트리거, YOLO 후처리. L0→L20 단일 추론 (double-inference 폐지)

---

## 3. 모델 · 하드웨어 아키텍처

### 3.1 소프트웨어 모델 — YOLOv2 (양자화)

Darknet 기반 C 레퍼런스(`skeleton/`)가 bit-exact 골든 모델입니다. mAP 를 계산하는 동시에 RTL 이 사용하는 `$readmemh` hex 를 생성하므로, RTL 출력을 C 레퍼런스와 layer 단위로 대조할 수 있습니다.

- **입력**: 256×256×3 이미지, **NCHW** (CHW byte order), C 레퍼런스와 100% 동일
- **네트워크**: 22 layer, 2 개 YOLO 헤드 — L14 (8×8×195), L20 (16×16×195)
- **양자화**: INT8 **signed** weight, UINT8 activation; layer 별 arithmetic descale shift 는 `CONV*_param_scales.hex` 실측값 사용
- **Descaling 결과**: float 복원 아닌 `0~255` uint8 클리핑; 검출 헤드는 trunc-toward-zero + INT8 clamp

| 항목                | 값                                                                |
| ------------------- | ----------------------------------------------------------------- |
| 골든 프레임워크     | Darknet 변형 C (`skeleton/`)                                    |
| 입력                | 256×256×3, NCHW byte order                                      |
| Weight / activation | INT8 signed / UINT8                                               |
| 검출 헤드           | L14 → 8×8×195, L20 → 16×16×195                              |
| Descale             | layer 별 arithmetic shift (L0=8, L2~L20=6, L20 헤드 shift=9)      |
| hex 산출물          | `CONV{NN}_param_weight.hex` / `_biases.hex` / `_scales.hex` |

### 3.2 하드웨어 아키텍처 — RTL

**설계 사양** (`hardware/src/`)

| 항목        | 사양                                                                                     |
| ----------- | ---------------------------------------------------------------------------------------- |
| 타겟 보드   | Nexys A7-100T (XC7A100T)                                                                 |
| Top 모듈    | `yolo_engine.v` — 53-state FSM, 22-layer 자동 추론 (`ap_start` → `network_done`) |
| MAC 어레이  | 144 MAC = 36 mul × 4 spatial set → 한 pass 당 2×2 OFM block                           |
| 데이터 표현 | NCHW, INT8 signed weight, UINT8 activation, 16-bit sign-extend bias                      |
| 클럭        | 81.25 MHz 목표 (타이밍 클로징 진행 중, impl 단계 WNS ≈ −0.18 ns)                       |
| 온칩 OFM    | `dpram_wrapper` OFM = 65536 × 32-bit = 256 KB, 5-way port mux                         |
| 외부 메모리 | DDR2 (~4 MB): weight/bias base, IFM base, OFM base (layer 별 offset)                     |
| 인터페이스  | AXI4-Lite slave (제어) + AXI4 master (데이터, FIXED_BURST=256)                           |

**모듈 맵**

| 그룹   | 모듈                                                                                                 |
| ------ | ---------------------------------------------------------------------------------------------------- |
| Top    | `yolo_engine.v` (22-layer FSM), `yolo_engine_axi.v` (AXI4-Lite ctrl_reg0~3)                      |
| DMA    | `axi_dma_rd.v` (IFM/weight/bias read mux), `axi_dma_wr.v` (OFM store)                            |
| Conv   | `conv_top.v` (output-stationary loop), `ifm_line_buf.v` (4-row cyclic window, 3×3/1×1 packing) |
| MAC    | `mac_kern.v` → `mac_stack.v` → `mul.v` ×144 (INT8×INT8→INT16) + `add_tree_36in.v` ×4   |
| Post   | `post_process.v` ×4 (bias → ReLU → arith shift → uint8 clip)                                   |
| 특수   | `max_pool_unit.v` (s2), `max_pool_s1_unit.v` (L11 s1), `upsample_unit.v` (L18 2×)             |
| Memory | `gbuff_param.v` (weight 72/288 비대칭 + bias), `dpram_wrapper.v`, `spram_wrapper.v`            |
| Header | `user_define_h.v` (`` `define FPGA `` — 합성 ON / 시뮬 OFF)                                       |

**네트워크 (22 layer)** — Route/Upsample 은 L18 을 제외하면 전용 연산 모듈 없이 처리.

| Layer          | 타입                         | Input → Output             | 모듈                                          |
| -------------- | ---------------------------- | --------------------------- | --------------------------------------------- |
| L0             | Conv 3×3                    | 256×256×3 → 256×256×16 | `conv_top`                                  |
| L1/3/5/7/9     | MaxPool s2                   | 공간 1/2                    | `max_pool_unit`                             |
| L2/4/6/8/10/13 | Conv 3×3                    | 채널 증가                   | `conv_top` (L8 = L19 Route 분기)            |
| L11            | **MaxPool s1**         | 8×8×512 → 8×8×512      | **`max_pool_s1_unit`** (same-padding) |
| L12            | Conv 1×1                    | 8×8×512 → 8×8×256      | `conv_top` (1×1 mode, L16 Route 분기)      |
| L14            | Conv 1×1                    | 8×8×512 → 8×8×195      | `conv_top` — YOLO 헤드 1                   |
| L16            | **Route** ← L12       | → 8×8×256                | FSM skip + DRAM alias (모듈 없음)             |
| L17            | Conv 1×1                    | 8×8×256 → 8×8×128      | `conv_top`                                  |
| L18            | **Upsample 2×**       | 8×8×128 → 16×16×128    | **`upsample_unit`**                   |
| L19            | **Route** ← L18 ‖ L8 | → 16×16×384              | RTL REPACK FSM (8 states, 모듈 없음)          |
| L20            | Conv 1×1                    | 16×16×384 → 16×16×195  | `conv_top` — YOLO 헤드 2 (shift=9)         |
| L15/L21        | YOLO output                  | —                          | 소프트웨어 후처리                             |

**DRAM 메모리 맵** (`yolo_engine.v`)

- `ctrl_reg1` = `dram_wgt_base` — weights + bias (bias 는 `+0x00A0_0000` offset)
- `ctrl_reg2` = `dram_ifm_base` — 입력 이미지 (L0 IFM)
- `ctrl_reg3` = `dram_ofm_base` — 모든 layer OFM (layer 별 word offset)

---

## 4. 디렉토리 구조

```
Yolo_Accelerator/
├── skeleton/                  # Darknet 변형 C 골든 레퍼런스 + 양자화 hex 생성기
│   ├── src/                   # C 소스 (additionally.c 등 — 양자화 + hex export)
│   ├── bin/                   # ./darknet, aix2024.cfg/weights, yolohw.names
│   │   ├── log_param/         #   → CONV{NN}_param_weight/biases/scales.hex
│   │   └── log_feamap/        #   → layer 별 feature-map dump
│   └── Makefile
│
├── hardware/
│   ├── src/                   # 활성 RTL — 19 .v (yolo_engine + 17 서브모듈 + define stub)
│   ├── testbench/             # 블록 TB + layer 별 verify (l0~l20) + yolo_engine_tb
│   │   ├── inout_data_sw/     #   C 레퍼런스 골든 hex (layer 별 IFM/OFM)
│   │   └── sim_dram_model/    #   AXI-slave DRAM behavioral 모델
│   ├── sim/                   # 컴파일 산출물 (.gitignore)
│   ├── fpga/                  # Vivado 프로젝트(2025) + BMG IP TCL + IP packaging + Vitis workspace
│   └── firmware/              # host.py (Host PC UART 클라이언트)
│
├── documents/
│   ├── technical_reference/   # 16장 기술 레퍼런스 (Markdown)
│   └── tutorial_guide/        # 대회 제공 SDK / Vivado 튜토리얼 PDF
│
├── ARCHITECTURE.md            # 상세 아키텍처 스펙 (네트워크, 모듈 계층, 메모리 맵)
├── CLAUDE.md                  # 작업 가이드 + 치명적 에러 방지 규칙
├── README.md
└── README.ko.md               # 본 문서
```

> `hardware/src/` 전부 합성 대상 (legacy 파일 없음). `define.v` 는 `mul.v` 참조용 include stub 이며, 실제 매크로는 `user_define_h.v` 에 있습니다.

---

## 5. 시작하기

### 5.1 C 골든 레퍼런스 빌드 (Linux)

```bash
cd skeleton
make                          # → ./bin/darknet
cd bin/dataset
python make_list_cur.py       # 테스트 이미지 경로 갱신 (최초 1회)
```

### 5.2 양자화 hex 생성 (Linux)

```bash
cd skeleton/bin
# 단일 이미지 추론 + hex 저장 (-save_params)
./darknet detector test yolohw.names aix2024.cfg aix2024.weights \
  -thresh 0.24 test01.jpg -out_filename test01-det-quantized \
  -quantized -save_params

# 전체 테스트셋 mAP (양자화)
sh script-unix-aix2024-test-all-quantized.sh
```

생성 hex 위치: `skeleton/bin/log_param/`
`CONV{NN}_param_weight.hex` (INT8), `_biases.hex` (16-bit), `_scales.hex` (descale shift).

### 5.3 RTL 시뮬레이션

`hardware/src/user_define_h.v` 의 `` `define FPGA `` 를 **주석 처리(OFF)** 후 시뮬레이션합니다. Chain 검증은 **Vivado 2025** 사용 — Vivado 2021 은 uninitialized 메모리(X) 처리가 달라 ±1 LSB 비결정성이 발생합니다.

**테스트벤치** (`hardware/testbench/`)

| 파일                                      | 대상                                  | 외부 데이터                              |
| ----------------------------------------- | ------------------------------------- | ---------------------------------------- |
| `conv_top_tb.v`                         | Conv wrapper (3×3 / 1×1)            | `inout_data_sw/*.hex`                  |
| `pool_tb.v` / `pool_s1_tb.v`          | MaxPool stride-2 / stride-1           | `inout_data_sw/*.hex`                  |
| `upsample_tb.v`                         | Upsample 2×                          | `inout_data_sw/*.hex`                  |
| `ifm_line_buf_tb.v`                     | 4-row cyclic line buffer              | `inout_data_sw/*.hex`                  |
| `axi_dma_rd_tb.v` / `axi_dma_wr_tb.v` | AXI master read / write               | `sim_dram_model/`                      |
| `l{N}_verify_tb.v`                      | Layer 별 chain 검증 (l0~l20)          | `inout_data_sw/*.hex`                  |
| `yolo_engine_tb.v`                      | 22-layer 전체 추론 (`network_done`) | `inout_data_sw/` + `sim_dram_model/` |

```tcl
# Vivado 2025 프로젝트 + layer 별 / 전체 chain 시뮬
source hardware/fpga/create_project_25.tcl

set_property top conv_top_tb    [get_filesets sim_1]; launch_simulation
set_property top l0_verify_tb   [get_filesets sim_1]; launch_simulation
set_property top yolo_engine_tb [get_filesets sim_1]; launch_simulation
```

> ⚠️ `log_all_signals` 옵션은 **OFF** 유지 — 파형 덤프가 TB 당 수백 MB 까지 폭증합니다.

### 5.4 합성 / 비트스트림 (Vivado)

`user_define_h.v` 의 `` `define FPGA `` 를 **활성화(ON)** (DSP48/BRAM IP 명시적 인스턴스화) 후:

```tcl
cd hardware/fpga
source yolohw.tcl
source gen_bram_ips.tcl
launch_runs synth_1 -jobs 4
wait_on_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 4
```

### 5.5 보드 실행 (Host PC UART 클라이언트)

```bash
cd hardware/firmware
pip install Pillow numpy pyserial

# 가중치 + 이미지 업로드, L0→L20 추론, 검출 결과 수신
python host.py --port /dev/ttyUSB1 --image test01.jpg

# 가중치 재업로드 없이 다른 이미지로 재추론
python host.py --port /dev/ttyUSB1 --image test02.jpg --skip-weights
```

---

## 6. 개발 현황

**현재 상태 — Phase 3 (SoC 통합) 진행 중.** 22-layer `yolo_engine` 은 합성 완료 후 C 골든 레퍼런스와 layer 단위 검증까지 마쳤으며, MicroBlaze + UART + DDR2 통합과 IP packaging 을 81.25 MHz 타이밍 클로징과 함께 진행 중입니다.

### 소프트웨어 (골든 레퍼런스)

- [X] Darknet 변형 C 레퍼런스 빌드 (`skeleton/`) — mAP + bit-exact 골든 모델
- [X] 양자화 hex export (`CONV*_param_weight/biases/scales.hex`)
- [X] `host.py` UART 클라이언트 — 가중치/이미지 업로드 + YOLO 후처리 (sigmoid/softmax/NMS)

### RTL (YOLOv2 가속기)

**Phase 1 — RTL 합성 (yolo_engine 단독)**

- [X] 22-layer 자동 추론 FSM (53 states)
- [X] 144-MAC 어레이 (36 mul × 4 spatial) + 4× post_process
- [X] 3×3 / 1×1 conv 모두 동일 `mac_kern` 재사용
- [X] L11 (MaxPool s1) / L18 (Upsample 2×) 전용 모듈
- [X] AXI master DMA (FIXED_BURST=256) + layer 별 DRAM offset 테이블
- [X] 블록 TB (conv_top / max_pool / max_pool_s1 / upsample)

**Phase 2 — TB 검증 + 정확도 튜닝**

- [X] `mul.v` IFM 부호 수정 (UINT8 → INT8 signed) → conv_top_tb mismatch 31 → **0**
- [X] `yolo_engine.v` layer 별 descale shift 를 scale hex 실측 적용 (L0=8, L2~L20=6)
- [X] SW 골든 hex 단일 추론 기준 재생성, `inout_data_sw/` 동기화
- [X] Layer 별 chain 검증 **L0~L20** (Vivado 2025, 0 mismatch), L19 Route concat + L20 검출 헤드 포함

**Phase 3 — MicroBlaze + UART + DDR2 SoC**

- [X] `yolo_engine` IP packaging (`hardware/fpga/IP_PACKAGING/`)
- [X] Vitis firmware + `host.py` UART 클라이언트 (가중치/이미지 업로드, YOLO 후처리)
- [X] 타이밍 최적화 — WNS @81.25 MHz: −2.6 → ≈ −0.18 ns
- [ ] 블록 디자인: MicroBlaze MCS + UART + DDR2 MIG + interconnect (보드 bring-up)
- [ ] 목표 클럭 타이밍 완전 클로징

**Phase 4 — 비트스트림 + 보드 데모 + 측정**

- [ ] 합성 → 비트스트림 → 보드 적재
- [ ] 100 장 테스트셋 mAP / fps / Energy 측정 → 최종 점수 산출

---

## 7. 기타

### 문서

| 경로                               | 내용                                                                   |
| ---------------------------------- | ---------------------------------------------------------------------- |
| `documents/technical_reference/` | 16장 기술 레퍼런스 (yolo_engine, conv 엔진, DMA, 타이밍)               |
| `documents/tutorial_guide/`      | 대회 제공 SDK 설치 / 양자화 / Vivado / MAC-BRAM 매뉴얼                 |
| `ARCHITECTURE.md`                | 상세 스펙 — 네트워크, 모듈 계층, FSM 흐름, DRAM 맵                    |
| `CLAUDE.md`                      | 작업 가이드 + 치명적 에러 방지 규칙 8가지                              |

### 설계 노트

- **144 MAC** 고정 예산 — 1×1 conv 는 3×3 `mac_kern` 재사용, Route/Upsample 은 신규 연산 모듈 없이 처리 (에너지 우선)
- **Bias** 는 zero-extend 아닌 **sign-extend** 로 32-bit 적재 (`{ {16{b[15]}}, b }`)
- **L11 MaxPool 은 stride-1** — stride-2 유닛이 아닌 `max_pool_s1_unit` 사용
- **Sim 메모리** 는 `initial` 0 초기화 (실제 BRAM 전원 인가 시 0 과 일치) → Vivado 2025 chain 검증 결정성 확보

---

## 8. 참고 자료

- [YOLO9000 / YOLOv2](https://arxiv.org/abs/1612.08242) — Better, Faster, Stronger (Redmon & Farhadi)
- [Darknet](https://pjreddie.com/darknet/) — `skeleton/` C 골든 모델의 기반 프레임워크
- [Nexys A7 (Digilent)](https://digilent.com/reference/programmable-logic/nexys-a7/start) — XC7A100T 타겟 보드
