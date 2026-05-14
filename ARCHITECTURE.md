# YOLOv2 FPGA Accelerator Architecture 

본 문서는 베타트론 팀의 YOLOv2 가속기 설계 상세 스펙 및 디렉토리 구조를 설명합니다. 구현 방향이나 핀맵, 네트워크 구조 확인이 필요할 때 참조하십시오.

## 1. 하드웨어/소프트웨어 역할 분담
- 하드웨어 (RTL): Conv(3x3, 1x1), Bias add + Descaling, ReLU, MaxPool(s=2, s=1), Route/Upsample (메모리 주소 제어 기반)
- 소프트웨어 (MicroBlaze/Host PC): 가속기 제어, DMA 트리거, YOLO 후처리(Sigmoid, Softmax, NMS 등)

## 2. 전체 네트워크 구조 (22 Layers)
| Layer | Type | Filters Size | Input | Output | 비고 |
|---|---|---|---|---|---|
| 0~10 | Conv+Pool | (채널 증가, 공간 감소) | 256x256x3 | 8x8x512 | Layer 8 (16x16x256) 분기점 |
| 11 | Max | - | 8x8x512 | 8x8x512 | Stride=1 (특수 처리) |
| 12 | Conv | 256 (1x1) | 8x8x512 | 8x8x256 | Layer 16 분기점 |
| 13~14 | Conv | - | 8x8x256 | 8x8x195 | - |
| 15 | YOLO | - | - | - | 출력 1 (8x8 격자) |
| 16 | Route | (L12 가져오기) | - | 8x8x256 | - |
| 17~18 | Conv+Up | - | 8x8x256 | 16x16x128 | Upsample 2x |
| 19 | Route | (L18+L8 Concat)| - | 16x16x384 | 메모리 주소 제어로 병합 |
| 20 | Conv | 195 (1x1) | 16x16x384 | 16x16x195 | - |
| 21 | YOLO | - | - | - | 출력 2 (16x16 격자) |

(주의: 최대 메모리는 Layer 0, 최대 MAC 연산은 Layer 8, 10에서 발생. Route를 위해 Layer 8 출력은 DRAM에 보관 필수)

## 3. YOLO Engine 내부 모듈 구조
```text
yolo_engine.v (TOP — 12차시 재작성 예정)
│
├── yolo_engine_axi.v          ← AXI4-Lite Slave (ctrl_reg0~3 / network_done)
├── axi_dma_ctrl.v             ← DMA FSM
│   ├── axi_dma_rd.v           ← DRAM → on-chip
│   └── axi_dma_wr.v           ← on-chip → DRAM
│
├── ifm_line_buf.v (작성 예정)   ← 4-row line buffer + 36-byte window packing
│
├── conv_top.v                 ← Conv wrapper (자체 FSM, output-stationary loop)
│   ├── gbuff_param.v          ← weight 36KB + bias/shift 10KB (한 모듈에 통합)
│   │   ├── dpram_4096x72      ← 72-bit write / 288-bit read 비대칭
│   │   └── spram_2560x32
│   └── mac_kern.v             ← 144-MAC + 4× inline 누적 + 4× post_process
│       ├── mac_stack.v        ← 36 mul × 4 spatial = 144 MAC
│       │   ├── mul.v × 144
│       │   └── add_tree_36in.v × 4
│       └── post_process.v × 4
│
├── max_pool.v                 ← 2×2 maxpool (stride 1/2 둘 다 지원)
│
└── OFM dpram_wrapper          ← 출력 픽셀 버퍼 (크기 결정 예정)