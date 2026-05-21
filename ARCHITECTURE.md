# YOLOv2 FPGA Accelerator Architecture

본 문서는 베타트론 팀의 YOLOv2 가속기 설계 상세 스펙 및 디렉토리 구조를 설명합니다. 네트워크 구조, 모듈 계층, 메모리 맵 등 구현 참조용입니다.

## 0. 프로젝트 4-Phase

| Phase | 내용 | 상태 |
|-------|------|------|
| **Phase 1** | MicroBlaze 제외 RTL 합성 완료 (yolo_engine 단독 22-layer 자동 추론) | ✅ 완료 |
| **Phase 2** | TB 일괄 검증 + 정확도 튜닝 (shift 실측, conv_top_tb 0 mismatch, yolo_engine_tb 22-layer 완주) | ✅ 완료 |
| **Phase 3** | MicroBlaze + UART + DDR2 통합 | ✅ 코드 완성 / 보드 통합 대기 |
| Phase 4 | 비트스트림 + 보드 데모 + 측정 | 대기 |

## 1. 하드웨어 / 소프트웨어 역할 분담

- **하드웨어 (RTL, Phase 2 완료)**: Conv(3×3, 1×1), Bias + Descaling, ReLU, MaxPool(stride 2 / stride 1), Upsample, Route(DMA 주소 제어)
- **소프트웨어 (Phase 3 MicroBlaze + Host PC)**: 가속기 제어, DMA 트리거, YOLO 후처리 (Sigmoid, Softmax, NMS)

## 2. 전체 네트워크 구조 (22 Layers)

| Layer | Type | Filters / Size | Input | Output | 비고 |
|---|---|---|---|---|---|
| 0~10 | Conv + Pool (interleave) | 채널 증가, 공간 감소 | 256×256×3 | 8×8×512 | L8 (16×16×256) 분기점 (Route 대상) |
| 11 | MaxPool stride 1 | - | 8×8×512 | 8×8×512 | **특수 처리**, `max_pool_s1_unit.v` |
| 12 | Conv 1×1 | 256 | 8×8×512 | 8×8×256 | L16 분기점 (Route 대상) |
| 13 | Conv 3×3 | 512 | 8×8×256 | 8×8×512 | - |
| 14 | Conv 1×1 | 195 | 8×8×512 | 8×8×195 | YOLO head 1 |
| 15 | YOLO output | - | - | - | 8×8 격자 출력 (software 후처리) |
| 16 | Route (← L12) | - | - | 8×8×256 | FSM skip + DMA 주소 alias |
| 17 | Conv 1×1 | 128 | 8×8×256 | 8×8×128 | - |
| 18 | Upsample 2× | - | 8×8×128 | 16×16×128 | `upsample_unit.v` |
| 19 | Route (← L18 ‖ L8) | - | - | 16×16×384 | FSM skip + software DRAM concat |
| 20 | Conv 1×1 | 195 | 16×16×384 | 16×16×195 | YOLO head 2 |
| 21 | YOLO output | - | - | - | 16×16 격자 출력 |

**주의**: 최대 메모리는 L0 IFM (192 KB), 최대 MAC 연산은 L8/L10. Route 위해 L8/L12 OFM 은 DRAM 보존 필수.

## 3. YOLO Engine 내부 모듈 구조 (Phase 1 완료 시점)

```text
yolo_engine.v ★ TOP — 22-layer 자동 추론 FSM (14 states)
│
├── yolo_engine_axi.v             ← AXI4-Lite slave (ctrl_reg0~3 / network_done)
│
├── axi_dma_rd.v                  ← AXI4 master read (BITS_TRANS=20, FIXED_BURST=256)
│                                   IFM / Weight / Bias 멀티플렉싱 source
│
├── axi_dma_wr.v                  ← AXI4 master write (BITS_TRANS=20, OUT_BITS_TRANS=20)
│                                   OFM store
│
├── ifm_line_buf.v                ← 4-row cyclic line buffer + window packing
│   └─ (FPGA) dpram_2048x128_tdp × 4    True Dual Port BMG IP
│      (sim)  behavioral mem [0:2047]
│   특징: cyclic row mapping (i_rb), 3×3 / 1×1 mode packing, row/col boundary padding
│
├── conv_top.v                    ← Conv wrapper (자체 FSM, output-stationary loop)
│   ├── gbuff_param.v             ← weight 36 KB + bias/shift 10 KB 통합
│   │   ├── (FPGA) dpram_4096x72  ← write 72-bit / read 288-bit 비대칭
│   │   ├── (FPGA) spram_2560x32
│   │   └── (sim)  behavioral wgt_mem / bias_mem
│   │
│   └── mac_kern.v                ← 144-MAC + 4× accumulator + 4× post_process
│       ├── mac_stack.v           ← 36 mul × 4 spatial = 144 MAC
│       │   ├── mul.v × 144       ← genvar(i=0..35) × 4 spatial = 144 (INT8×INT8→INT16)
│       │   │                       w: INT8 signed, x: INT8 signed (Phase 2 수정: UINT8→INT8)
│       │   └── add_tree_36in.v × 4
│       └── post_process.v × 4    ← bias + ReLU + arith shift + UINT8 clip
│
├── max_pool_unit.v               ← stride-2 maxpool (L1/3/5/7/9)
│                                   FSM 1 cycle/word, BRAM 1-cycle latency 정렬
│
├── max_pool_s1_unit.v            ← stride-1 maxpool (L11 전용, same-padding)
│                                   FSM 5 cycle/output block (4 read + 1 write)
│
├── upsample_unit.v               ← 2× nearest neighbor (L18 전용)
│                                   1 input word → 4 output word (2×2 byte 복제)
│
└── dpram_wrapper.v (u_ofm)       ← OFM 65536 × 32-bit = 256 KB
    │                              5-way port mux:
    │                                Port A (write): conv / pool / s1_pool / upsample
    │                                Port B (read) : pool / s1_pool / upsample / DMA store
    └─ (FPGA) dpram_65536x32 BMG IP
       (sim)  behavioral ram [0:65535]
```

### 3.1 22-layer ↔ sub-module 매핑

| Layer | 타입 | 사용 sub-module |
|-------|------|-----------------|
| L0, 2, 4, 6, 8, 10, 13 | conv 3×3 | conv_top + gbuff_param + mac_kern + ifm_line_buf |
| L12, 14, 17, 20 | conv 1×1 | 동일 (ifm_line_buf 의 1×1 mode 활성) |
| L1, 3, 5, 7, 9 | maxpool s2 | `max_pool_unit` |
| L11 | maxpool s1 | `max_pool_s1_unit` |
| L18 | upsample | `upsample_unit` |
| L16, L19 | Route | (no module — FSM skip + software DRAM 사전 배치) |
| L15, L21 | YOLO output | (no module — FSM skip, software 후처리) |

## 4. Top FSM 흐름 (yolo_engine.v, 14 states)

```
ST_IDLE → (ap_start) → ST_INIT
ST_INIT  → Route/YOLO 감지 시 ST_NEXT 로 skip
         → 그 외 ST_DMA_WGT
ST_DMA_WGT       → conv layer 면 weight DMA load
ST_DMA_WGT_WAIT  → dma_rd_done 대기
ST_DMA_BIAS      → bias DMA load
ST_DMA_BIAS_WAIT
ST_DMA_IFM       → conv 면 IFM DMA load
                   pool / s1_pool / upsample 은 dpram 직전 OFM 사용 (DMA skip)
ST_DMA_IFM_WAIT
ST_RUN_CONV      → conv_start (1-pulse) → ST_DMA_OFM
ST_RUN_POOL      → pool_start / s1_pool_start / up_start dispatch → ST_DMA_OFM
ST_DMA_OFM       → done 대기 후 OFM store DMA 시작
ST_DMA_OFM_WAIT  → dma_wr_done 대기
ST_NEXT          → layer_idx++ 또는 ST_DONE
ST_DONE          → network_done assert
```

## 5. DRAM 메모리 맵 (Phase 1 software 약속)

- `ctrl_reg1` = **dram_wgt_base** : weights + bias 영역 base
  - bias 는 dram_wgt_base + **0x00A0_0000** offset (weight ~10 MB 이후 안전 위치)
- `ctrl_reg2` = **dram_ifm_base** : input image (L0 IFM)
- `ctrl_reg3` = **dram_ofm_base** : 모든 layer OFM 영역 (per-layer offset 적용)

### Per-layer OFM offset (32-bit word 단위, yolo_engine.v case table 정의)

| Layer | offset (word) | size (word) |
|-------|--------------|-------------|
| L0  | 0      | 262144 |
| L1  | 262144 | 65536  |
| L2  | 327680 | 131072 |
| L3  | 458752 | 32768  |
| L4  | 491520 | 65536  |
| L5  | 557056 | 16384  |
| L6  | 573440 | 32768  |
| L7  | 606208 | 8192   |
| L8  | 614400 | 16384  |
| L9  | 630784 | 4096   |
| L10 | 634880 | 8192   |
| L11 | 643072 | 8192   |
| L12 | 651264 | 4096   |
| L13 | 655360 | 8192   |
| L14 | 663552 | 3120   |
| L16 | 651264 (alias L12) | 4096 |
| L17 | 666672 | 2048   |
| L18 | 668720 | 8192 (+ 16384 L8 concat = 24576 reserved) |
| L19 | 668720 (alias L18 + L8 concat region) | 24576 |
| L20 | 693296 | 12480  |

## 6. AXI 인터페이스

### AXI4-Lite slave (control, MicroBlaze ↔ yolo_engine, Phase 3)
- 4 × 32-bit register (ctrl_reg0~3)
- ctrl_reg0[0] = ap_start, ctrl_reg0[1] = network_done (read-back)

### AXI4 master (data, yolo_engine ↔ DDR2)
- 32-bit data, 32-bit address
- Burst read (FIXED_BURST=256), Burst write
- Phase 3 에서 MicroBlaze AXI bus 와 공유 (interconnect)

## 7. 디렉토리 구조

```
Yolo_Accelerator/
├── ARCHITECTURE.md          (본 문서)
├── CLAUDE.md                (작업 가이드 + 치명적 규칙)
├── HANDOFF.md               (세션 핸드오프 노트)
├── skeleton/                (C 골든 레퍼런스, hex 파일 생성기)
├── .recycle_bin/            (소프트 삭제 보관함, REASON.md 참조)
└── yolohw/
    ├── fpga/                Vivado 프로젝트 + BMG IP TCL + Vitis firmware
    ├── firmware/            host.py (Host PC UART 클라이언트)
    ├── src/                 활성 RTL (18 파일, legacy 제거 완료)
    ├── testbench/           활성 TB (13 파일) + hex 데이터 + sim_dram_model
    └── sim/                 iverilog 컴파일 출력 전용 (.gitignore)
```

## 8. Phase 1 알려진 한계 / Phase 2 점검 대상

1. **Shift 1차 추정값 (13~16)** — Phase 2 에서 `CONV*_param_scales.hex` 측정 후 정밀화 필요
2. **OFM dpram 256 KB** — L0 conv OFM (1 MB) 일부만 적재. Phase 2 에서 streaming-out 또는 ping-pong 필요시 추가
3. **IFM DMA sliding window 미구현** — 큰 layer (L0~L4) 의 IFM 이 line buffer 용량 초과 시 wraparound. TB 검증 시 row 0 만 신뢰 가능
4. **Route L19 concat** — software 가 L8 OFM 을 L18 OFM 직후 위치에 복사하는 책임 (별도 도구)
