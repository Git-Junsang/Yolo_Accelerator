# YOLOv2 FPGA 가속기 — 종합 기술 레퍼런스

> **팀 베타트론 · 중앙대학교 AIX2026 Deep Learning Hardware 설계 경진대회**
> 22-layer YOLOv2 추론 가속기 SoC (Nexys A7-100T / Artix-7 XC7A100T)

---

## 0. 이 문서에 대하여

본 기술 레퍼런스는 YOLOv2 FPGA 가속기 프로젝트의 **소프트웨어 골든 레퍼런스(skeleton C)부터 RTL 하드웨어, 검증 환경(Testbench), Vivado 프로젝트까지 전 계층을 한 곳에 정리한 종합 문서**입니다. 팀 내부 인수인계·유지보수·설계 검토를 1차 목적으로 하며, 코드를 처음 접하는 사람이 이 문서만으로 시스템의 동작 원리와 구현 세부를 이해할 수 있도록 작성되었습니다.

### 0.1 대상 독자

- 프로젝트에 새로 합류하여 전체 구조를 빠르게 파악해야 하는 팀원
- 특정 RTL 모듈을 수정하기 전에 그 모듈의 정확한 동작·포트·타이밍을 확인하려는 개발자
- 검증 실패(mismatch) 디버깅 시 데이터 포맷·메모리 맵·검증 전략을 추적해야 하는 사람
- Phase 3(MicroBlaze 통합)·Phase 4(보드 데모) 진입을 준비하는 통합 담당자

### 0.2 현재 문서 범위 (집필 시점)

이 레퍼런스는 **L0~L18 검증 완료 + L19~L20 RTL 완성**을 범위로 합니다. L19(Route concat)는 RTL REPACK(`S_L19_RP_*`)으로, L20(detection head 2)은 descale shift=9 로 완성되어 standalone PASS(0 mismatch) 확인되었습니다. L0→L20 full chain 검증과 FPGA 보드 동작 확인이 완료되면 [16장 부록](16_appendix_future.md)의 해당 절을 본문으로 승격합니다.

| 영역 | 상태 | 본 문서 수록 |
|------|------|-------------|
| L0~L18 RTL + 검증 | ✅ Vivado 2025 기준 0 mismatch | 본문 전체 |
| L19~L20 RTL | ✅ 완성 (L19 REPACK, L20 shift=9 standalone PASS) / L0→L20 full chain 검증 진행 중 | 부록(개요)에 기술, 검증 후 승격 |
| L21 (YOLO output) | software 후처리 (Sigmoid/NMS) | Phase 3/4 |
| Phase 3 (MicroBlaze/UART/DDR2) | ⏳ 코드 완성 / 보드 통합 대기 | 부록에 개요 |
| Phase 4 (비트스트림/보드/측정) | ⏳ 대기 | 부록에 계획 |

---

## 1. 챕터 구성

문서는 8개 파트, 16개 장으로 구성됩니다. 위에서 아래로 읽으면 "큰 그림 → 소프트웨어 → 하드웨어 → 동작/검증/툴"의 순서로 자연스럽게 이어집니다.

### Part Ⅰ. 프로젝트와 환경

| 장 | 파일 | 내용 |
|----|------|------|
| 1 | [프로젝트 개요](01_project_overview.md) | 대회·목표·점수 공식, 타겟 보드, 시스템 한눈에 보기, HW/SW 역할 분담 |
| 2 | [개발 환경과 빌드](02_dev_environment.md) | Linux/Windows 이중 환경, SMB 공유, skeleton 빌드, Vivado 합성/시뮬, Vivado 2025 통일 |

### Part Ⅱ. 소프트웨어 골든 레퍼런스

| 장 | 파일 | 내용 |
|----|------|------|
| 3 | [skeleton C 레퍼런스](03_skeleton_reference.md) | Darknet 기반 구조, INT8 양자화 시스템, hex 생성기(`-save_params`), 골든 데이터 워크플로우 |
| 4 | [22-Layer 네트워크 구조](04_network_architecture.md) | `aix2024.cfg` 해석, 레이어별 형상·연산, Route/Upsample/YOLO head, 양자화 multiplier |

### Part Ⅲ. 하드웨어 큰 그림

| 장 | 파일 | 내용 |
|----|------|------|
| 5 | [하드웨어 아키텍처 개요](05_hardware_overview.md) | 모듈 계층 트리, 데이터 흐름, 144-MAC 구조 요약, 22-layer↔모듈 매핑 |
| 6 | [데이터 표현과 메모리 맵](06_data_representation_memory_map.md) | NCHW / NHWC entry / 2×2 packed 포맷, 양자화·descaling, DRAM 메모리 맵, BRAM 자원 |

### Part Ⅳ. RTL 모듈 상세 (전 모듈)

| 장 | 파일 | 내용 |
|----|------|------|
| 7 | [yolo_engine — TOP FSM](07_rtl_yolo_engine_top.md) | 최상위 53-state FSM, layer case table, OFM dpram 5-way 포트 mux, DMA target demux |
| 8 | [Convolution 엔진](08_rtl_convolution_engine.md) | `conv_top` · `mac_kern` · `mac_stack` · `mul` · `add_tree_36in` · `post_process` |
| 9 | [메모리 버퍼](09_rtl_memory_buffers.md) | `ifm_line_buf` · `gbuff_param` · `dpram_wrapper` · `spram_wrapper` |
| 10 | [특수 연산 유닛](10_rtl_special_units.md) | `max_pool_unit` · `max_pool_s1_unit` · `upsample_unit` · REPACK 변환 엔진 |
| 11 | [AXI / DMA 인터페이스](11_rtl_axi_dma.md) | `axi_dma_rd` · `axi_dma_wr` · `yolo_engine_axi` · `user_define_h` · `define` |

### Part Ⅴ. 동작과 타이밍

| 장 | 파일 | 내용 |
|----|------|------|
| 12 | [동작 과정과 타이밍](12_operation_timing.md) | 전체 추론 시퀀스, conv/pool/upsample/REPACK cycle 흐름, MAC 11-cycle 파이프라인, DMA 타이밍, fps/Energy 추정 |

### Part Ⅵ. 검증 (Testbench)

| 장 | 파일 | 내용 |
|----|------|------|
| 13 | [검증 전략과 인프라](13_testbench_strategy.md) | 2-Phase(standalone+chain) 검증, canonical 로그 포맷, tolerance 판정, `sim_dram_model`, hex 데이터 구조 |
| 14 | [Layer별 / 블록 Testbench](14_testbench_per_layer.md) | `l0~l18_verify_tb` 각각의 검증 대상·입력·결과, 블록 TB(conv_top/pool/mul/ifm_line_buf 등) |

### Part Ⅶ. Vivado 프로젝트

| 장 | 파일 | 내용 |
|----|------|------|
| 15 | [Vivado 프로젝트](15_vivado_project.md) | 프로젝트 생성 TCL, BMG IP(BRAM) 설정, FPGA 매크로 토글, 합성/시뮬 흐름, Vivado 2021 vs 2025 이슈 |

### Part Ⅷ. 부록

| 장 | 파일 | 내용 |
|----|------|------|
| 16 | [부록 — 향후 작업 / 용어집](16_appendix_future.md) | L19~L21 개요, Phase 3·4 계획, host.py, 용어집, 약어, 참고 문서 |

---

## 2. 빠른 참조 (Quick Facts)

처음 보는 독자가 가장 자주 찾는 핵심 수치를 한 표에 모았습니다. 상세 근거는 각 장에 있습니다.

| 항목 | 값 | 근거 장 |
|------|----|---------|
| 타겟 보드 / FPGA | Nexys A7-100T / XC7A100T (Artix-7) | [1장](01_project_overview.md) |
| 모델 | YOLOv2-tiny 변형, 22 layer, uint8 양자화 | [4장](04_network_architecture.md) |
| 입력 해상도 | 256 × 256 × 3 | [4장](04_network_architecture.md) |
| MAC 어레이 | 144 = 36 mul × 4 spatial set (한 cycle 4 픽셀) | [8장](08_rtl_convolution_engine.md) |
| MAC 파이프라인 latency | 마지막 vld_i → output_valid 까지 `8 + acc_len + 1` cycle | [8·12장](12_operation_timing.md) |
| 곱셈기 | INT8 × INT8 → INT16, DSP48 4-stage | [8장](08_rtl_convolution_engine.md) |
| 데이터 표현 | NCHW byte order / NHWC 16-byte entry / 2×2 packed word | [6장](06_data_representation_memory_map.md) |
| 활성 RTL | 19 .v (yolo_engine + 17 서브모듈 + `define.v` stub) | [5장](05_hardware_overview.md) |
| TOP FSM | 53 state (conv / pool / REPACK / L11 s1-pool / L18 upsample) | [7장](07_rtl_yolo_engine_top.md) |
| OFM dpram | 65,536 × 32-bit = 256 KB, 5-way port mux | [9장](09_rtl_memory_buffers.md) |
| 검증 환경 | **Vivado 2025** (2021은 X 처리 차이로 chain mismatch) | [15장](15_vivado_project.md) |
| 검증 현황 | L0~L18 chain 0 mismatch | [14장](14_testbench_per_layer.md) |
| 목표 성능 | ≥ 5 fps, mAP > 0.2 | [1장](01_project_overview.md) |
| 점수 공식 | `Score = 10⁴ / Energy × ReLU(mAP − 0.2) × ReLU(fps − 5)` | [1장](01_project_overview.md) |

---

## 3. 문서 표기 규약

- **레이어 표기**: `L0`~`L21`은 네트워크 레이어 인덱스(=`layer_idx`)입니다. `CONV00`~`CONV20`은 skeleton C가 덤프하는 hex 파일 접두사이며 레이어 인덱스와 동일한 번호를 씁니다.
- **신호/포트/모듈명**: 코드 식별자는 `i_start`, `conv_top`, `S_LOAD_BIAS` 처럼 표기합니다.
- **소스 위치 인용**: 가능한 곳에서 [yolo_engine.v](../../yolohw/src/yolo_engine.v) 형태의 상대 링크로 실제 파일을 가리킵니다. 라인 번호는 집필 시점 기준이며, 코드 변경에 따라 달라질 수 있으니 식별자(모듈/state/파라미터 이름)를 우선 기준으로 삼으십시오.
- **다이어그램**: 구조도·FSM·데이터 흐름은 Mermaid, 메모리 맵·타이밍·비트필드는 ASCII 표로 표현합니다. Mermaid는 VSCode·GitHub에서 렌더링됩니다.
- **숫자 단위**: 메모리 크기는 별도 표기가 없으면 32-bit word 또는 byte 단위를 명시합니다. 주소는 byte 오프셋(`0x...`)입니다.

---

## 4. 함께 보면 좋은 1차 자료

본 레퍼런스는 아래 1차 자료를 종합·확장한 것입니다. 충돌 시 **실제 소스 코드가 최우선**이며, 본 문서가 그다음, 아래 자료가 배경입니다.

| 자료 | 위치 | 용도 |
|------|------|------|
| `CLAUDE.md` | [../../CLAUDE.md](../../CLAUDE.md) | 작업 가이드 + 치명적 에러 방지 규칙 8가지 |
| `ARCHITECTURE.md` | [../../ARCHITECTURE.md](../../ARCHITECTURE.md) | 아키텍처 스펙 요약 (네트워크·모듈·메모리 맵) |
| `HISTORY.md` | [../../HISTORY.md](../../HISTORY.md) | layer-by-layer 검증 진행 기록, 버그 수정 이력 |
| `README.md` (루트) | [../../README.md](../../README.md) | 프로젝트 개요 + 빌드/시뮬 방법 |
| 강의 PDF 12종 | [../](../) | DSP/MAC, BRAM, System Integration 등 대회 제공 자료 |

---

*Last updated: 2026-05-24 · 범위: L0~L18 검증 완료 + L19~L20 RTL 완성 · 작성: 팀 베타트론*
