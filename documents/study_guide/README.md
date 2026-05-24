# YOLOv2 FPGA 가속기 — 학습 해설서

> **팀 베타트론 · 중앙대학교 AIX2026 Deep Learning Hardware 설계 경진대회**
> 22-layer YOLOv2 추론 가속기 SoC (Nexys A7-100T / Artix-7 XC7A100T)

---

## 0. 이 해설서를 읽기 전에

### 0.1 이 문서는 무엇인가요?

이 문서는 **프로젝트를 처음 접하는 학부생이 RTL의 구조와 동작을 스스로 이해할 수 있도록** 만든 학습 해설서입니다. 단순히 "무엇이 있는지"를 나열하는 것이 아니라, **"왜 이렇게 만들었는지", "이 코드가 정확히 무슨 일을 하는지"** 를 처음부터 끝까지 따라갈 수 있게 설명합니다.

이 프로젝트에는 두 종류의 문서가 있습니다.

| 문서 | 위치 | 대상 | 성격 |
|------|------|------|------|
| **기술 레퍼런스** | [../technical_reference/](../technical_reference/) | Claude(AI)·숙련자 | 간결·정확, 찾아보는 용 |
| **학습 해설서 (본 문서)** | `study_guide/` | 사람·학부생 | 배경지식 + 코드 해설, 읽고 배우는 용 |

두 문서는 같은 시스템을 다루지만, 본 해설서는 **배경 지식을 충실히 깔고, 설명을 두 배로 자세히 하며, 중요한 코드를 직접 짚어가며** 설명합니다. 깊은 정확성이 필요하면 기술 레퍼런스를, 처음 배운다면 본 해설서를 권합니다.

### 0.2 독자에게 가정하는 것

- **알고 있다고 가정**: 디지털 논리 회로(게이트·플립플롭·레지스터), Verilog 기본 문법(`reg`/`wire`, `always`, 비트 표기 `8'd5`, `if/case`), 2진수·16진수, 기초 프로그래밍(C/Python).
- **처음이라고 가정하고 설명**: 합성곱 신경망(CNN), 신경망 양자화, FPGA 자원(DSP48·BRAM), RTL 파이프라인·타이밍, AXI 버스 프로토콜, YOLO 객체 탐지. → 이 6가지는 [Part 0 기초 개념](#part-0-기초-개념-foundations)에서 차근차근 설명합니다.

### 0.3 읽는 순서

```
처음 배우는 사람:  Part 0 → Part 1 → ... → Part 8  (순서대로)
HW 지식이 있는 사람: Part 0 건너뛰고 Part 1부터, 필요할 때 Part 0 참조
특정 모듈만 볼 사람: 해당 장으로 직행, 모르는 개념은 Part 0 링크 따라가기
```

각 기술 장은 시작 부분에 **"이 장을 읽기 위한 준비"** 로 필요한 Part 0 개념을 링크합니다.

### 0.4 이 문서의 표기 약속

본 해설서는 이해를 돕기 위해 몇 가지 장치를 씁니다.

- **💡 비유 박스**: 어려운 하드웨어 개념을 일상적인 비유로 풀어줍니다.
- **🔍 코드 해설**: 실제 RTL 코드를 인용하고 **한 줄 한 줄** 무슨 일을 하는지 설명합니다.
- **❓ 왜 이렇게 했을까?**: 설계 결정의 이유와 대안을 설명합니다.
- **⚠️ 흔한 오해 / 함정**: 처음 배울 때 헷갈리기 쉬운 지점을 짚습니다.
- 코드 식별자는 `i_start`, `conv_top` 처럼 표기하고, 파일은 [yolo_engine.v](../../yolohw/src/yolo_engine.v)처럼 링크합니다.

---

## Part 0. 기초 개념 (Foundations)

RTL을 읽기 전에 알아야 할 6가지 배경 지식입니다. 이미 아는 주제는 건너뛰어도 됩니다.

| 장 | 파일 | 무엇을 배우나 |
|----|------|---------------|
| 1 | [CNN과 합성곱 기초](01_cnn_basics.md) | 합성곱·풀링·활성화·채널·stride·padding, 1×1 vs 3×3, 이 가속기가 다루는 연산 |
| 2 | [신경망 양자화 기초](02_quantization_basics.md) | 왜 정수로? 고정소수점, scale, INT8 곱셈-누적, descaling, 반올림 |
| 3 | [FPGA 하드웨어 기초](03_fpga_basics.md) | LUT·FF·DSP48·BRAM이 뭔지, 합성/구현/비트스트림, 클럭과 면적·전력 |
| 4 | [RTL 설계와 타이밍 기초](04_rtl_timing_basics.md) | FSM, 파이프라인, BRAM read latency, valid 신호, signed 연산, 왜 타이밍이 까다로운가 |
| 5 | [AXI 버스 프로토콜 기초](05_axi_basics.md) | master/slave, AXI4-Lite vs AXI4, burst, handshake, DMA |
| 6 | [YOLO 객체 탐지 기초](06_yolo_basics.md) | 객체 탐지란, grid·anchor·bounding box, 검출 헤드, NMS, 출력 195채널의 의미 |

---

## Part 1. 프로젝트와 환경

| 장 | 파일 | 내용 |
|----|------|------|
| 7 | [프로젝트 개요](07_project_overview.md) | 대회·목표·점수 공식, 시스템 큰 그림, HW/SW 역할 분담 |
| 8 | [개발 환경과 빌드](08_dev_environment.md) | Linux/Windows 이중 환경, skeleton 빌드, Vivado 합성/시뮬 |

## Part 2. 소프트웨어 골든 레퍼런스

| 장 | 파일 | 내용 |
|----|------|------|
| 9 | [skeleton C 레퍼런스](09_skeleton_reference.md) | darknet 기반 정수 추론, hex 생성, 코드 해설 |
| 10 | [22-Layer 네트워크 구조](10_network_architecture.md) | cfg 해석, 레이어별 형상·연산, skip connection |

## Part 3. 하드웨어 큰 그림

| 장 | 파일 | 내용 |
|----|------|------|
| 11 | [하드웨어 아키텍처 개요](11_hardware_overview.md) | 모듈 계층, 데이터 흐름, 144-MAC 한눈에 |
| 12 | [데이터 표현과 메모리 맵](12_data_representation_memory_map.md) | 세 가지 데이터 포맷, descaling, DRAM/BRAM 맵 |

## Part 4. RTL 모듈 상세 (코드 해설 중심)

| 장 | 파일 | 내용 |
|----|------|------|
| 13 | [yolo_engine — 최상위 FSM](13_rtl_yolo_engine_top.md) | 53-state FSM, 파라미터 mux, 포트 demux, 코드 해설 |
| 14 | [Convolution 엔진](14_rtl_convolution_engine.md) | mul→add_tree→mac_stack→mac_kern→conv_top, 한 줄씩 해설 |
| 15 | [메모리 버퍼](15_rtl_memory_buffers.md) | line buffer·param buffer·dpram/spram |
| 16 | [특수 연산 유닛](16_rtl_special_units.md) | pooling·upsample·REPACK |
| 17 | [AXI / DMA 인터페이스](17_rtl_axi_dma.md) | DMA read/write, AXI-Lite slave |

## Part 5. 동작과 타이밍

| 장 | 파일 | 내용 |
|----|------|------|
| 18 | [동작 과정과 타이밍](18_operation_timing.md) | 추론 시퀀스, MAC 파이프라인, 성능 추정 |

## Part 6. 검증 (Testbench)

| 장 | 파일 | 내용 |
|----|------|------|
| 19 | [검증 전략과 인프라](19_testbench_strategy.md) | 2-Phase 검증, 로그 포맷, tolerance |
| 20 | [Layer별 / 블록 Testbench](20_testbench_per_layer.md) | L0~L18 + 블록 TB, 결과 해석 |

## Part 7. Vivado 프로젝트

| 장 | 파일 | 내용 |
|----|------|------|
| 21 | [Vivado 프로젝트](21_vivado_project.md) | 프로젝트·BMG IP·합성/시뮬·2021/2025 이슈 |

## Part 8. 부록

| 장 | 파일 | 내용 |
|----|------|------|
| 22 | [부록 — 향후 작업 / 용어집](22_appendix_future.md) | L19~L21, Phase 3·4, host.py, 용어집 |

---

## 진행 상태

본 해설서는 **L0~L18 검증 완료 + L19~L20 RTL 완성** 기준으로 작성됩니다(L19=Route REPACK, L20=detection shift 9, standalone PASS). L0→L20 full chain 검증과 FPGA 보드 동작이 완료되면 [22장 부록](22_appendix_future.md)의 해당 내용을 본문으로 승격합니다.

> 더 깊은 정확성이나 빠른 참조가 필요하면 [기술 레퍼런스](../technical_reference/README.md)를, 충돌 시에는 **실제 소스 코드**를 최우선으로 삼으십시오.

---

*Last updated: 2026-05-24 · 범위: L0~L18 검증 완료 + L19~L20 RTL 완성 · 대상: 학부생 입문자 · 작성: 팀 베타트론*
