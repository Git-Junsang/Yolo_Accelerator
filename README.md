# YOLOv2 FPGA Accelerator — 팀 베타트론

[![Phase](https://img.shields.io/badge/Phase-2%20TB%20Verified-brightgreen)]()
[![Board](https://img.shields.io/badge/Board-Nexys%20A7--100T-blue)]()
[![Tool](https://img.shields.io/badge/Vivado-2020.2+-orange)]()
[![License](https://img.shields.io/badge/License-Academic-lightgrey)]()

> **중앙대학교 AIX2026 Deep Learning Hardware 설계 경진대회** 출품작
> 22-layer YOLOv2 추론 가속기 SoC (FPGA 단독, ≥ 5 fps 목표)

---

## 📑 목차

1. [프로젝트 개요](#1-프로젝트-개요)
2. [디렉토리 구조](#2-디렉토리-구조)
3. [인스턴스 계층](#3-인스턴스-계층)
4. [파일별 상세](#4-파일별-상세)
5. [데이터 흐름](#5-데이터-흐름)
6. [동작 과정 (Top FSM)](#6-동작-과정-top-fsm)
7. [22-Layer ↔ 서브모듈 매핑](#7-22-layer--서브모듈-매핑)
8. [현재 진행 상황](#8-현재-진행-상황)
9. [빌드 / 시뮬레이션 방법](#9-빌드--시뮬레이션-방법)
10. [작업자 가이드라인](#10-작업자-가이드라인)

---

## 1. 프로젝트 개요

| 항목 | 내용 |
|------|------|
| **타겟 보드** | Nexys A7-100T (Xilinx Artix-7 XC7A100T) |
| **모델** | YOLOv2-tiny 변형 (22 layer, uint8 quantized) |
| **MAC 어레이** | 144 MAC = 36 mul × 4 spatial set (한 cycle 4 픽셀) |
| **데이터 표현** | NCHW byte order, 8-bit unsigned activation, 8-bit signed weight |
| **외부 메모리** | DDR2 (4 MB 사용) |
| **목표 성능** | ≥ 5 fps, mAP > 0.2 |
| **점수 공식** | `Score = 10⁴ / Energy × ReLU(mAP − 0.2) × ReLU(fps − 5)` |

---

## 2. 디렉토리 구조

```
AIX Project/
├── README.md                ◀ 본 문서
├── CLAUDE.md                작업 가이드 + 치명적 규칙
├── ARCHITECTURE.md          상세 아키텍처 스펙
├── HANDOFF.md               세션 핸드오프 노트
│
├── skeleton/                C 골든 레퍼런스 + hex 파일 생성기
│   └── bin/
│       ├── script-wins-aix2024-test-one-quantized.cmd
│       └── log_feamap/, log_param/  (생성된 hex 파일)
│
├── 참고자료/                강의자료 / 논문 / 데모 자료
│
└── yolohw/                  ◀ 핵심 RTL/시뮬레이션 디렉토리
    ├── src/                 ★ 활성 RTL — 19 파일
    ├── sim/                 ★ 활성 TB — 5 파일 + hex 데이터 폴더
    │   ├── inout_data_sw/   C 레퍼런스 출력 hex
    │   ├── inout_data_hw/   하드웨어 출력 (시뮬 캡쳐)
    │   ├── input_data/      입력 이미지 hex
    │   └── sim_dram_model/  AXI slave DRAM 모델
    ├── fpga/                Vivado 프로젝트 + BMG IP TCL
    ├── src_backup/          📦 legacy RTL (참조용)
    ├── sim_backup/          📦 legacy TB (참조용)
    └── _archive/            📦 옛 스크린샷 / 초안 자료
```

**합성 / 시뮬 대상은 `yolohw/src/` + `yolohw/sim/` 만**. `*_backup` 과 `_archive` 는 보존용입니다.

---

## 3. 인스턴스 계층

```
yolo_engine.v ★ TOP — 22-layer 자동 추론 FSM
│
├── yolo_engine_axi.v             AXI4-Lite slave (ctrl_reg0~3 / network_done)
│
├── axi_dma_rd.v                  AXI4 master read (BITS_TRANS=20, FIXED_BURST=256)
│                                 IFM / Weight / Bias 멀티플렉싱 source
│
├── axi_dma_wr.v                  AXI4 master write (OUT_BITS_TRANS=20)
│                                 OFM store
│
├── ifm_line_buf.v                4-row cyclic line buffer + window packing
│   └─ (FPGA) dpram_2048x128_tdp × 4       True Dual Port BMG IP
│      (sim)  behavioral mem [0:2047]
│
├── conv_top.v                    Conv wrapper (output-stationary loop)
│   │
│   ├── gbuff_param.v             weight 36 KB + bias/shift 10 KB 통합
│   │   ├── (FPGA) dpram_4096x72  write 72-bit / read 288-bit 비대칭
│   │   ├── (FPGA) spram_2560x32
│   │   └── (sim)  behavioral wgt_mem / bias_mem
│   │
│   └── mac_kern.v                144-MAC + 4× accumulator + 4× post_process
│       │
│       ├── mac_stack.v           36 mul × 4 spatial = 144 MAC
│       │   ├── mul_dual.v        DSP48 packing (2 곱셈 동시) × ~72
│       │   │   └── mul.v         8-bit signed multiplier
│       │   └── add_tree_36in.v × 4
│       │
│       └── post_process.v × 4    bias + ReLU + arith shift + UINT8 clip
│
├── max_pool_unit.v               stride-2 maxpool (L1/3/5/7/9)
│                                 BRAM 1-cycle latency 정렬, in-place write
│
├── max_pool_s1_unit.v            stride-1 maxpool (L11 전용)
│                                 5 cycle/output block, 2×2 same-padding
│
├── upsample_unit.v               2× nearest neighbor (L18 전용)
│                                 1 input word → 4 output word (2×2 byte 복제)
│
└── dpram_wrapper.v (u_ofm)       OFM 65536 × 32-bit = 256 KB
    │                             5-way port mux:
    │                               Port A (write) : conv / pool / s1_pool / upsample
    │                               Port B (read)  : pool / s1_pool / upsample / DMA store
    └─ (FPGA) dpram_65536x32 BMG IP
       (sim)  behavioral ram [0:65535]
```

---

## 4. 파일별 상세

### 🎯 TOP module

| 파일 | 역할 | 비고 |
|------|------|------|
| **yolo_engine.v** | 22-layer 자동 추론 top. 14-state FSM, per-layer DRAM offset table, 5-way OFM dpram port mux | ap_start 1 회 → network_done |

### 🚌 AXI 인터페이스

| 파일 | 역할 |
|------|------|
| **yolo_engine_axi.v** | AXI4-Lite slave. 4 × 32-bit ctrl_reg (ap_start / dram_wgt_base / dram_ifm_base / dram_ofm_base) |
| **axi_dma_rd.v** | AXI4 master read. FIXED_BURST=256, 32-bit data. IFM/Weight/Bias 다중 source 멀티플렉싱 |
| **axi_dma_wr.v** | AXI4 master write. OFM dpram → DDR2 |

### 🔢 산술 building blocks

| 파일 | 역할 |
|------|------|
| **mul.v** | 8-bit signed multiplier (DSP48 추론 가능) |
| **mul_dual.v** | DSP48 1 개로 `a×c + b×c` 2 곱셈 동시 처리 |
| **add_tree_36in.v** | 36-input signed adder tree |
| **mac_stack.v** | 36 mul × 4 spatial set (ifm_00/01/10/11) → 4 partial sum |
| **mac_kern.v** | mac_stack + 4 × 32-bit accumulator + 4 × post_process → 한 cycle 4 픽셀 (2×2 OFM block) |

### 🧮 후처리

| 파일 | 역할 |
|------|------|
| **post_process.v** | bias 덧셈 → ReLU → arithmetic shift → UINT8 clip. mac_kern 내 4 인스턴스 |

### 💾 메모리 wrapper / 파라미터 버퍼

| 파일 | 역할 |
|------|------|
| **spram_wrapper.v** | Single-port RAM wrapper (FPGA BMG IP / behavioral) |
| **dpram_wrapper.v** | Dual-port RAM wrapper. 여러 (DW, AW, DEPTH) 케이스 generate |
| **gbuff_param.v** | weight (4096×72 비대칭, write 72 / read 288) + bias (2560×32) 통합 |

### 🪟 라인 버퍼 + Conv

| 파일 | 역할 |
|------|------|
| **ifm_line_buf.v** | 4 line × 2048 entry × 128-bit cyclic sliding window. 3×3 / 1×1 mode packing, row/col boundary padding. DMA write port |
| **conv_top.v** | Output stationary 4중 loop FSM (`fil_idx × row_idx × col_idx × acc_cyc`). BRAM 1-cycle latency 정렬 |

### 🌊 Max Pooling / Upsample

| 파일 | 역할 |
|------|------|
| **max_pool_unit.v** | stride-2 maxpool (L1/L3/L5/L7/L9). 32-bit packed word = 한 2×2 block → max-of-4 |
| **max_pool_s1_unit.v** | stride-1 maxpool (L11 전용). 2×2 same-padding sliding window |
| **upsample_unit.v** | 2× nearest neighbor (L18 전용). 1 input → 4 output packed word |

### 📋 헤더

| 파일 | 역할 |
|------|------|
| **user_define_h.v** | `` `define FPGA `` 매크로 (합성 ON / 시뮬 OFF). BRAM 매크로 |

---

## 5. 데이터 흐름

```
                              MicroBlaze (Phase 3)
                                    ▲ AXI-Lite
                                    │ (ctrl_reg0~3)
                                    ▼
                           ┌──────────────────┐
                           │ yolo_engine_axi  │
                           └────────┬─────────┘
                                    │
                                    ▼
              ┌─────────────────────────────────────┐
              │   22-layer FSM (yolo_engine.v)      │
              │   ST_INIT → DMA_WGT → DMA_BIAS →    │
              │   DMA_IFM → RUN_CONV/POOL → DMA_OFM │
              │   → NEXT (반복)                     │
              └──────┬──────────────────┬───────────┘
                     │ start            │ start
              ┌──────▼─────┐      ┌─────▼──────┐
              │ axi_dma_rd │      │ axi_dma_wr │   AXI4 Master
              │  (master)  │      │  (master)  │   ◄──► DDR2 (4 MB)
              └──────┬─────┘      └─────▲──────┘
                     │ 32-bit stream    │ 32-bit stream
                     ▼                  │
            ┌────────────────────┐      │
            │ 4-word assembler   │      │
            │ → 128-bit          │      │
            │ + dma_target demux │      │
            └─┬───┬───┬──────────┘      │
        IFM   │   │   │  BIAS           │
              ▼   ▼WGT▼  (32-bit)       │
       ┌──────────────────┐ ┌──────────────────┐
       │  ifm_line_buf    │ │   gbuff_param    │
       │  (4 × 128-bit)   │ │ (wgt 72/288 +    │
       │  cyclic rotation │ │  bias 32-bit)    │
       └────────┬─────────┘ └────────┬─────────┘
                │ 4 × 288-bit IFM    │ 288-bit wgt +
                │ (2×2 spatial set)  │ 32-bit bias
                └──────────┬─────────┘
                           ▼
                  ┌──────────────────────┐
                  │  conv_top + mac_kern │
                  │  144-MAC array       │
                  │  + 4 post_process    │
                  └──────────┬───────────┘
                             │ 32-bit packed pixel
                             │ (4-pix 2×2 block)
                             ▼
                ┌───────────────────────────────────┐
                │   OFM dpram (256 KB, 65K × 32b)   │
                │   5-way port mux                  │
                │   • conv 쓰기                     │
                │   • max_pool / s1_pool 읽기+쓰기  │
                │   • upsample 읽기+쓰기            │
                │   • DMA store 읽기                │
                └──┬──────────────┬──────────────┬──┘
                   ▼              ▼              ▼
          ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
          │ max_pool_unit│ │max_pool_s1   │ │ upsample_unit│
          │  (stride 2)  │ │  (L11)       │ │   (L18)      │
          └──────────────┘ └──────────────┘ └──────────────┘
```

**핵심 포인트**:
- DDR2 ↔ 가속기 모든 데이터 전송은 **AXI master DMA** 한 쌍으로 처리
- IFM 16-byte entry (4 col × 4 ch), Weight 16-byte slot (72-bit valid + padding), Bias 32-bit
- OFM dpram 은 임시 staging — 매 layer 끝나면 DMA write 로 DDR2 에 보존

---

## 6. 동작 과정 (Top FSM)

`yolo_engine.v` 의 14-state FSM 이 22-layer 를 자동 순회합니다:

```
ST_IDLE
  │ ap_start = 1
  ▼
ST_INIT  ─── Route / YOLO 출력 layer?  ─── yes ──┐
  │ no                                             │
  ▼                                                │
ST_DMA_WGT       (conv 시 weight DMA load)        │
  │                                                │
  ▼                                                │
ST_DMA_WGT_WAIT  (dma_rd_done 대기)               │
  │                                                │
  ▼                                                │
ST_DMA_BIAS      (bias DMA load)                  │
  │                                                │
  ▼                                                │
ST_DMA_BIAS_WAIT                                  │
  │                                                │
  ▼                                                │
ST_DMA_IFM       (conv 만 DMA load,               │
  │              pool / s1_pool / upsample 은     │
  │              dpram 직전 OFM 사용)              │
  ▼                                                │
ST_DMA_IFM_WAIT                                   │
  │                                                │
  ▼                                                │
ST_RUN_CONV  /  ST_RUN_POOL                       │
  │                                                │
  ▼                                                │
ST_DMA_OFM       (done 대기 후 OFM store 시작)    │
  │                                                │
  ▼                                                │
ST_DMA_OFM_WAIT                                   │
  │                                                │
  └──────────────────┬──────────────────────────────┘
                     ▼
                ST_NEXT
                     │ layer_idx < 21 ? → 다음 layer (ST_INIT)
                     │ layer_idx == 21 → ST_DONE
                     ▼
                ST_DONE  → network_done = 1
                     │
                     ▼
                ST_IDLE  (대기)
```

---

## 7. 22-Layer ↔ 서브모듈 매핑

| Layer | Type | Input → Output | 사용 서브모듈 |
|-------|------|----------------|-------------|
| L0  | Conv 3×3 | 256×256×3 → 256×256×16 | `conv_top` (+ gbuff_param, mac_kern, ifm_line_buf) |
| L1  | MaxPool s2 | 256×256×16 → 128×128×16 | `max_pool_unit` |
| L2  | Conv 3×3 | 128×128×16 → 128×128×32 | `conv_top` |
| L3  | MaxPool s2 | 128×128×32 → 64×64×32 | `max_pool_unit` |
| L4  | Conv 3×3 | 64×64×32 → 64×64×64 | `conv_top` |
| L5  | MaxPool s2 | 64×64×64 → 32×32×64 | `max_pool_unit` |
| L6  | Conv 3×3 | 32×32×64 → 32×32×128 | `conv_top` |
| L7  | MaxPool s2 | 32×32×128 → 16×16×128 | `max_pool_unit` |
| L8  | Conv 3×3 | 16×16×128 → 16×16×256 | `conv_top` ★ Route 분기 (L19 에서 사용) |
| L9  | MaxPool s2 | 16×16×256 → 8×8×256 | `max_pool_unit` |
| L10 | Conv 3×3 | 8×8×256 → 8×8×512 | `conv_top` |
| L11 | **MaxPool s1** | 8×8×512 → 8×8×512 | **`max_pool_s1_unit`** (특수) |
| L12 | Conv 1×1 | 8×8×512 → 8×8×256 | `conv_top` (1×1 mode) ★ Route 분기 (L16) |
| L13 | Conv 3×3 | 8×8×256 → 8×8×512 | `conv_top` |
| L14 | Conv 1×1 | 8×8×512 → 8×8×195 | `conv_top` (1×1 mode) — YOLO head 1 |
| L15 | YOLO output | — | (no module, software 후처리) |
| L16 | **Route** ← L12 | → 8×8×256 | (no module, FSM skip + DRAM alias) |
| L17 | Conv 1×1 | 8×8×256 → 8×8×128 | `conv_top` (1×1 mode) |
| L18 | **Upsample 2×** | 8×8×128 → 16×16×128 | **`upsample_unit`** |
| L19 | **Route** ← L18 ‖ L8 | → 16×16×384 | (no module, FSM skip + software concat) |
| L20 | Conv 1×1 | 16×16×384 → 16×16×195 | `conv_top` (1×1 mode) — YOLO head 2 |
| L21 | YOLO output | — | (no module, software 후처리) |

---

## 8. 현재 진행 상황

### 📍 프로젝트 4-Phase

| Phase | 내용 | 상태 |
|-------|------|------|
| **Phase 1** | **MicroBlaze 제외 RTL 합성 완료** (yolo_engine 단독 22-layer 자동 추론) | ✅ **완료** |
| **Phase 2** | **TB 일괄 검증 + 정확도 튜닝** (shift 실측, conv_top_tb 0 mismatch, yolo_engine_tb 22-layer 완주) | ✅ **완료** |
| Phase 3 | MicroBlaze + UART + DDR2 통합 | ⏳ 대기 |
| Phase 4 | 비트스트림 + 보드 데모 + 측정 | ⏳ 대기 |

### ✅ Phase 1 완료 사항

- 22-layer 자동 추론 FSM 완성 (14-state)
- 144-MAC array + 4 spatial set output
- 3×3 / 1×1 conv 모두 동일 mac_kern 재사용
- stride-1 maxpool (L11) 전용 모듈
- 2× upsample (L18) 전용 모듈
- AXI master DMA (BITS_TRANS=20, 4 MB session)
- Per-layer DRAM offset table (L0~L20)
- 블록 단위 TB 4 개 작성 (conv_top / max_pool / max_pool_s1 / upsample)

### ✅ Phase 2 완료 사항

- **`mul.v` IFM 부호 수정**: `$signed({1'b0,x})` → `$signed(x)` (UINT8 → INT8 signed). conv_top_tb mismatch 31 → **0**
- **`yolo_engine.v` lyr_shift 전수 수정**: scale 파일 실측 적용 (L0: 8, L2~L20: 6). yolo_engine_tb OFM all-zero → **non-zero 확인**
- **`skeleton/src/additionally.c`** Windows 하드코딩 경로 → 상대경로 (Linux make 빌드 정상화)
- SW 골든 hex 단일 실행 기준으로 재생성 및 `yolohw/sim/inout_data_sw/` 동기화
- `yolo_engine_tb`: 22-layer 완주 + network_done 수신 확인

### ⏳ Phase 3 남은 작업

- Vivado block design: MicroBlaze MCS + UART + DDR2 MIG + yolo_engine
- SDK firmware: `skeleton/` 의 yolo_head + NMS C 코드 재활용
- AXI bus interconnect 구성

### ⏳ Phase 4 남은 작업

- 합성 → 비트스트림 → 보드 적재
- 100 장 테스트셋 mAP / fps / Energy 측정
- 점수 산출

---

## 9. 빌드 / 시뮬레이션 방법

### 사전 준비

1. Vivado 2020.2 이상 설치
2. Windows 절대경로 호환을 위해 정션 생성:
   ```cmd
   mklink /J C:\yolohw "C:\AIX Project\yolohw"
   ```
3. C 골든 레퍼런스 hex 생성:
   ```cmd
   cd skeleton\bin
   script-wins-aix2024-test-one-quantized.cmd
   ```

### 합성 (Synthesis)

`yolohw/src/user_define_h.v` 의 `` `define FPGA `` **활성화** 상태에서:

```tcl
# Vivado tcl console
cd yolohw/fpga
source yolohw.tcl
source gen_bram_ips.tcl
launch_runs synth_1 -jobs 4
wait_on_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 4
```

### 시뮬레이션

`user_define_h.v` 의 `` `define FPGA `` **주석 처리** 후:

```tcl
# 블록 단위 TB 1 개씩 실행
set_property top conv_top_tb       [get_filesets sim_1]
launch_simulation

set_property top max_pool_unit_tb  [get_filesets sim_1]
launch_simulation

set_property top max_pool_s1_unit_tb [get_filesets sim_1]
launch_simulation

set_property top upsample_unit_tb  [get_filesets sim_1]
launch_simulation

# 전체 통합 TB (Phase 2 진입 시)
set_property top yolo_engine_tb    [get_filesets sim_1]
launch_simulation
```

⚠️ **`log_all_signals` 옵션은 OFF 유지** (디스크 폭증 방지).

---

## 10. 작업자 가이드라인

### 코드 수정 전 필독

`CLAUDE.md` 의 **치명적 에러 방지 규칙 7 가지** 를 반드시 읽고 작업.

### 핵심 원칙

1. **수정 전 파일 전체 읽기** — 스니펫만 보고 수정 금지
2. **신호 / 포트 추가 시 동시 갱신** — `yolo_engine.v`, `user_define_h.v`, 관련 TB 모두
3. **점진적 변경** — 한 번에 한 가지, 이유 명시
4. **legacy 파일 건들지 말 것** — `*_backup/` 안 파일은 참조용
5. **SystemVerilog 구문 금지** — Vivado plain Verilog 합성 실패 (`fork`, `join_any`, `let` 등)
6. **Bias sign-extend** — 16-bit hex → 32-bit 적재 시 `{ {16{b[15]}}, b }`
7. **Layer 11 stride 1 별도 처리** — 다른 maxpool 과 같이 두면 안 됨

### Phase 별 진입 권장 순서

```
Phase 1 (완료) → Phase 2 (TB 검증) → Phase 3 (MicroBlaze) → Phase 4 (데모)
```

Phase 를 건너뛰지 않습니다. Phase 2 mismatch 가 해결되지 않은 채 Phase 3 진입 금지.

### 참고 문서

- `ARCHITECTURE.md` — 상세 아키텍처 스펙
- `HANDOFF.md` — 세션 핸드오프 노트
- `CLAUDE.md` — 작업 가이드 + 치명적 규칙

### 협업 흐름

1. **Issue 등록** → 작업 항목 명시 (어느 Phase / 어느 모듈)
2. **Branch 생성** → `phaseN/feature-name` 명명 규칙
3. **PR 시** → CLAUDE.md 의 행동 원칙 준수했는지 self-check
4. **Review** → 합성 / 시뮬 통과 확인 후 merge

---

## 📞 문의 / 참여

- 팀: 베타트론 (중앙대학교 AIX2026)
- 대회: AIX2026 Deep Learning Hardware 설계 경진대회
- 모델 참조: YOLOv2-tiny (Darknet 변형)

---

**Last updated**: Phase 2 완료 시점 (2026-05-15 — mul.v INT8 수정, lyr_shift 실측 적용, yolo_engine_tb 22-layer 완주 확인)
