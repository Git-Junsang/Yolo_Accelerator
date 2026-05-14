
# 📂 yolohw/src/ — 최종 RTL 트리 (24 .v 파일)

## 🌳 모듈 인스턴스 계층 (top → leaf)

```text
yolo_engine.v ★ TOP (22-layer 자동 추론, MicroBlaze 없이 단독 동작)
│
├── yolo_engine_axi.v
│     └─ AXI4-Lite slave. ctrl_reg0~3 (ap_start / dram_wgt_base / ifm_base / ofm_base)
│        + network_done LED.
│
├── axi_dma_rd.v
│     └─ AXI4 master read (FIXED_BURST_SIZE=256, BITS_TRANS=20).
│        DRAM → 32-bit streaming. IFM/Weight/Bias 멀티플렉싱 source.
│
├── axi_dma_wr.v
│     └─ AXI4 master write (BITS_TRANS=20, OUT_BITS_TRANS=20).
│        OFM dpram → DRAM. indata_req 펄스 단위로 32-bit 공급 받음.
│
├── ifm_line_buf.v   (4 line × 2048 entry × 128-bit, cyclic row mapping)
│     └─ 내부에 `ifdef FPGA 분기: BMG IP `dpram_2048x128_tdp` × 4 인스턴스.
│        시뮬레이션 시 behavioral `reg [127:0] mem [0:2047]` × 4.
│        column offset mux + row/col boundary padding + 3×3 / 1×1 mode packing.
│
├── conv_top.v   (output-stationary 4중 loop, BRAM latency 정렬)
│   ├── gbuff_param.v
│   │     ├─ 내부 `ifdef FPGA: `dpram_4096x72` (weight, BMG IP, 72/288 비대칭)
│   │     │                    + `spram_2560x32` (bias/shift, BMG IP)
│   │     └─ 시뮬: behavioral wgt_mem[0:4095]=72-bit, bias_mem[0:2559]=32-bit
│   │
│   └── mac_kern.v   (한 cycle 4 픽셀 = 2×2 OFM block 생성)
│         ├── mac_stack.v
│         │     ├── mul_dual.v (DSP48 1 개로 2 곱셈 packing) × 18 inst
│         │     │     └── mul.v (8-bit signed multiplier, base)
│         │     └── add_tree_36in.v (36-input signed adder tree) × 4
│         │
│         └── post_process.v × 4 (bias + ReLU + arith shift + UINT8 clip)
│
├── max_pool_unit.v   ★ stride-2 maxpool (BRAM 1-cycle latency 정렬)
│     └─ L1/L3/L5/L7/L9 담당. 32-bit packed word = 한 2×2 block → max-of-4
│
├── max_pool_s1_unit.v   ★ stride-1 maxpool (L11 전용)
│     └─ 2×2 same-padding sliding window. 한 output block 당 4 input block 필요.
│        FSM 5 cycle/output block.
│
├── upsample_unit.v   ★ 2× nearest neighbor (L18 전용)
│     └─ 1 input packed word → 4 output packed word (각 pixel × 2×2 복제).
│
└── dpram_wrapper.v   (u_ofm 인스턴스, 65536 × 32-bit = 256 KB OFM dpram)
      └─ 내부 generate: DEPTH/DW 별 BMG IP 케이스 (FPGA mode) 또는 behavioral.
         OFM 임시 저장. conv/pool/s1_pool/upsample 가 write, DMA wr 가 read.

```

---

## 📋 파일별 상세 (24 .v 파일)

### 🎯 TOP module (1)

| 파일 | 역할 |
| --- | --- |
| **yolo_engine.v** ★ | 22-layer FSM + 모든 sub-module 통합. AXI master/slave 노출. Phase 5 (Route/Upsample/L11 모두 포함, DMA 20-bit) |

### 🚌 AXI 인터페이스 (4)

| 파일 | 역할 |
| --- | --- |
| **yolo_engine_axi.v** | AXI4-Lite slave. 4 × control register (ap_start + 3 DRAM base) |
| **axi_dma_rd.v** | AXI4 master read. FIXED_BURST 256 word. 한 인스턴스로 IFM/Weight/Bias load 멀티플렉싱 |
| **axi_dma_wr.v** | AXI4 master write. OFM dpram 의 데이터를 DRAM 으로 burst 전송 |
| **axi_dma_ctrl.v** | (legacy) 별도 read/write coordinate FSM — 현재 미사용 |

### 🔢 산술 building blocks (5, 9차시)

| 파일 | 역할 |
| --- | --- |
| **mul.v** | 8-bit signed multiplier (DSP48 추론 가능) |
| **mul_dual.v** | DSP48 1 개로 (a×c + b×c) 2 곱셈 동시 처리. mac_stack 내부에서 다수 인스턴스 |
| **add_tree_36in.v** | 36-input signed adder tree (mac_stack 의 partial sum 합산) |
| **mac_stack.v** | 36 mul × 4 spatial set (ifm_00/01/10/11) → 4 partial sum (mac_00/01/10/11) |
| **mac_kern.v** | mac_stack + 4 × 32-bit accumulator + 4 × post_process → 한 cycle 4 픽셀 |

### 🧮 후처리 (1)

| 파일 | 역할 |
| --- | --- |
| **post_process.v** | bias 덧셈 → ReLU → arithmetic shift → UINT8 clip. mac_kern 내 4 개 인스턴스 |

### 💾 메모리 wrapper / 파라미터 버퍼 (3, 10차시)

| 파일 | 역할 |
| --- | --- |
| **spram_wrapper.v** | Single-port RAM wrapper. `ifdef FPGA 로 BMG IP / behavioral 분기 |
| **dpram_wrapper.v** | Dual-port RAM wrapper. 여러 (DW, AW, DEPTH) 케이스 generate. u_ofm 으로 인스턴스화 |
| **gbuff_param.v** | weight (4096×72 비대칭, write 72 / read 288) + bias (2560×32) 통합. conv_top 내부 |

### 🪟 라인 버퍼 + Conv (3, 11차시)

| 파일 | 역할 |
| --- | --- |
| **ifm_line_buf.v** | 4-line cyclic sliding window. 3×3/1×1 mode packing + column/row boundary padding. DMA write port |
| **conv_top.v** | Output stationary 4중 loop FSM. gbuff_param + mac_kern 인스턴스 포함. BRAM latency 정렬 (mac_vld_d + pre-reset) |
| **cnn_ctrl.v** | (legacy) 강의 표준 4-state FSM (IDLE/VSYNC/HSYNC/DATA). conv_top 이 흡수하여 미사용 |

### 🌊 Max Pooling (3)

| 파일 | 역할 |
| --- | --- |
| **max_pool_unit.v** ★ | stride-2 maxpool. BRAM-aware FSM (issued_d 1-cycle delay). L1/L3/L5/L7/L9 담당 |
| **max_pool_s1_unit.v** ★ | stride-1 maxpool (L11 전용). 2×2 same-padding sliding window. 4-read + 1-write per output |
| **max_pool.v** | (legacy) 구버전 streaming max pool. 현재 미사용 |

### 🔼 Upsample (1)

| 파일 | 역할 |
| --- | --- |
| **upsample_unit.v** ★ | 2× nearest neighbor (L18 전용). 1 input → 4 output packed word |

### 📋 헤더 / 매크로 (3)

| 파일 | 역할 |
| --- | --- |
| **user_define_h.v** | `FPGA 매크로 (합성 ON / 시뮬 OFF), BRAM_WIDTH 등 매크로 |
| **define.v** | (legacy) 강의 원본 매크로. user_define_h.v 가 대체 |
| **user_param_h.v** | (legacy) 단일 layer debug 파라미터 (구버전 TB 용). yolo_engine 미사용 |

---

## 🔗 데이터 흐름 다이어그램

```text
                                    ┌─────────────────┐
              ctrl_reg0~3           │  yolo_engine_axi │
            ◄──────────────────────►│  (AXI-Lite slave)│
                                    └────────┬─────────┘
                                             │
                                             ▼ ap_start / 3 base addr
                                    ┌─────────────────┐
                                    │  22-layer FSM   │
                                    │  (yolo_engine)  │
                                    └────┬────────┬───┘
                              ┌──────────┘        └──────────┐
                              ▼                              ▼
                      ┌──────────────┐               ┌──────────────┐
                      │  axi_dma_rd  │               │  axi_dma_wr  │
                      │   (master)   │               │   (master)   │
                      └──────┬───────┘               └──────▲───────┘
                             │ 32-bit                       │ 32-bit
                             │ stream                       │ stream
       ┌─────────────────────┴────────────────┐             │
       │                                      │             │
       ▼                                      ▼             │
┌──────────────────┐  4-word→128-bit  ┌──────────────┐      │
│ 4-word assembler │ ─────────────────│   demux      │      │
│  (asm_data)      │                  │ (dma_target) │      │
└──────┬───┬───┬───┘                  └──┬──┬──┬─────┘      │
       │   │   │                         │  │  │            │
   IFM │   │WGT│                  BIAS   │  │  │            │
       ▼   ▼   ▼ 72-bit                  ▼  ▼  ▼            │
   ┌──────────────────┐         ┌──────────────────┐        │
   │  ifm_line_buf    │         │   gbuff_param    │        │
   │  (4 × 128-bit)   │         │ (wgt 72/288 +    │        │
   │  cyclic rotation │         │  bias 32-bit)    │        │
   └────────┬─────────┘         └────────┬─────────┘        │
            │ 4 × 288-bit IFM            │ 288-bit wgt +    │
            │                            │ 32-bit bias      │
            └─────────┬──────────────────┘                  │
                      ▼                                     │
            ┌──────────────────────┐                        │
            │      conv_top        │                        │
            │  (mac_kern 내부)     │                        │
            │   = 144 MAC array    │                        │
            └────────┬─────────────┘                        │
                     │ 32-bit packed pixel (4-pix block)    │
                     ▼                                      │
              ┌────────────────────────────────────┐        │
              │   OFM dpram (dpram_wrapper)        │◄───────┘
              │   65536 × 32-bit = 256 KB          │  (DMA-store read)
              │   5-way port mux:                  │
              │   - conv_pixel write               │
              │   - pool / s1_pool / upsample      │
              │     read+write                     │
              │   - DMA store read                 │
              └──┬──────────────┬──────────────┬───┘
                 │              │              │
                 ▼              ▼              ▼
        ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
        │ max_pool_unit│ │max_pool_s1_  │ │ upsample_unit│
        │  (stride 2)  │ │  unit (L11)  │ │    (L18)     │
        └──────────────┘ └──────────────┘ └──────────────┘

```

---

## 🗺️ 22-layer 가 사용하는 sub-module 매핑

| Layer | 타입 | 사용 sub-module |
| --- | --- | --- |
| **L0, 2, 4, 6, 8, 10, 13** | conv 3×3 | conv_top + gbuff_param + mac_kern + ifm_line_buf |
| **L12, 14, 17, 20** | conv 1×1 | 동일 (ifm_line_buf 의 1×1 mode 활성) |
| **L1, 3, 5, 7, 9** | maxpool s2 | max_pool_unit |
| **L11** | maxpool s1 | max_pool_s1_unit |
| **L18** | upsample | upsample_unit |
| **L16, L19** | Route | (no module — FSM skip + software DRAM 사전 배치) |
| **L15, L21** | YOLO output | (no module — FSM skip) |

---

## 📦 파일 카테고리별 카운트

* **활성 RTL:** 18 파일 (TOP 1 + AXI 3 + 산술 5 + 후처리 1 + 메모리 3 + 라인/Conv 2 + Pool 2 + Upsample 1)
* **Legacy 유지:** 3 파일 (cnn_ctrl, max_pool, axi_dma_ctrl)
* **헤더:** 3 파일 (user_define_h 활성, define + user_param_h legacy)
* **합계:** 24 .v 파일

