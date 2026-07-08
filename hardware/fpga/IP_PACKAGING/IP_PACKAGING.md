# YOLO Engine IP Packaging & MicroBlaze 통합 가이드

> YOLOv2-tiny 22-layer FPGA Accelerator  
> Target: Nexys A7-100T (Artix-7 XC7A100T-CSG324-1)  
> Vivado 2025.1 / IP Version 1.0

---

## 1. 시스템 아키텍처 개요

```
+---------------------+          AXI4-Lite (Control)         +------------------+
|                     |  ctrl_reg0~3 (ap_start, base addrs)  |                  |
|    MicroBlaze CPU   | ──────────────────────────────────── |   yolo_engine    |
|   (Bare-metal C)    |                                      |   (RTL IP)       |
|                     |  network_done polling (bit[1])        |                  |
+---------------------+                                      +------------------+
         |                                                           |
         | AXI4 (Data)                                    AXI4 Master (Data)
         |                                                           |
    +----v----+                                                 +----v----+
    | AXI SMC |  ←── AXI Smart Interconnect (Bus Arbiter) ───  | AXI SMC |
    +---------+                                                 +---------+
         |                                                           |
         +-------------------+-------------------+-------------------+
                             |
                    +--------v--------+
                    |  MIG 7 Series   |
                    |  DDR2 Controller|
                    |  (128MB DRAM)   |
                    +-----------------+
```

### 주요 컴포넌트
| 컴포넌트 | 역할 |
|----------|------|
| `microblaze_0` | 32-bit soft processor, 제어 및 데이터 전송 |
| `yolo_engine_0` | YOLOv2-tiny CNN 가속기 (144-MAC array) |
| `mig_7series_0` | DDR2 SDRAM 컨트롤러 (MT47H64M16HR-25E, 128MB) |
| `axi_smc` / `axi_smc_1` | AXI Smart Interconnect (버스 중재) |
| `axi_uartlite_0` | UART 인터페이스 (115200 baud, Host PC 통신) |
| `clk_wiz_1` | 클록 생성 (100MHz diff input -> 50MHz) |
| `mdm_1` | MicroBlaze Debug Module |
| `reset_inv_0` | 리셋 극성 반전 (util_vector_logic) |

---

## 2. 프로젝트 구조

### 2.1 전체 디렉터리 구조 (상대경로)

```
<project_root>/                                  # 예: Yolo_Accelerator-main/
├── yolohw/                                      # RTL + 시뮬레이션
│   ├── src/                                     # ★ RTL 소스 (개발 작업 폴더)
│   │   ├── yolo_engine.v                        # Top-level 엔진 FSM (22-layer)
│   │   ├── yolo_engine_axi.v                    # AXI4-Lite 슬레이브 래퍼
│   │   ├── conv_top.v                           # 컨볼루션 가속기
│   │   ├── mac_kern.v                           # MAC 커널 (36 multipliers)
│   │   ├── mac_stack.v                          # MAC 누적기
│   │   ├── mul.v                                # 8x8 곱셈기
│   │   ├── add_tree_36in.v                      # 36-input 덧셈 트리
│   │   ├── post_process.v                       # Bias + ReLU + Descale
│   │   ├── ifm_line_buf.v                       # IFM 라인 버퍼
│   │   ├── dpram_wrapper.v                      # Dual-port RAM 래퍼
│   │   ├── gbuff_param.v                        # Weight/Bias BRAM 버퍼
│   │   ├── axi_dma_rd.v                         # DMA 읽기 마스터
│   │   ├── axi_dma_wr.v                         # DMA 쓰기 마스터
│   │   ├── max_pool_unit.v                      # MaxPool (stride=2)
│   │   ├── max_pool_s1_unit.v                   # MaxPool (stride=1)
│   │   ├── upsample_unit.v                      # Upsample (2x)
│   │   └── user_define_h.v                      # 매크로 정의
│   ├── testbench/                               # 시뮬레이션 TB
│   │   ├── l*_verify_tb.v                       # 레이어별 검증 TB
│   │   └── inout_data_sw/                       # .mem / golden hex 파일
│   ├── sim/                                     # 시뮬레이션 유틸
│   │   └── gen_sim_dram_origin.py               # DRAM .mem 파일 생성기
│   └── fpga/
│       └── gen_bram_ips.tcl                     # BRAM IP 생성 스크립트
│
├── skeleton/                                    # 소프트웨어 (MicroBlaze C 코드)
│   ├── src/
│   │   ├── main.c                               # 메인 애플리케이션
│   │   └── yolov2_forward_network_quantized.c   # 양자화 추론 (골든 생성)
│   └── bin/
│       ├── log_param/CONV*_param_*.hex           # 골든 파라미터
│       └── log_feamap/CONV*_output.hex           # 골든 피처맵
│
├── <ip_repo>/                                   # IP Repository (component.xml 위치)
│   ├── component.xml                            # IP-XACT 정의
│   ├── src/                                     # IP에 포함된 RTL 복사본
│   │   └── (yolohw/src/ 와 동일한 17개 .v 파일)
│   └── xgui/
│       └── yolo_engine_v1_0.tcl                 # IP GUI 스크립트
│
└── <fpga_yolohw>/                               # Vivado 시스템 프로젝트
    ├── fpga_yolohw.xpr                          # Vivado 프로젝트 파일
    ├── system_top.xdc                           # 핀 제약 조건
    ├── update_ip_and_build.tcl                  # ★ 원클릭 빌드 스크립트
    └── fpga_yolohw.srcs/sources_1/bd/system/
        └── system.bd                            # Block Design
```

### 2.2 핵심 규칙: RTL 소스 관리

```
★ RTL 수정은 반드시 yolohw/src/ 에서만 한다.
★ IP repo의 src/는 빌드 시 자동 복사되므로 직접 수정하지 않는다.
★ update_ip_and_build.tcl 이 복사 + 리패키징 + 빌드를 자동 처리한다.
```

---

## 3. AXI 인터페이스 상세

### 3.1 AXI4-Lite Slave (S_AXI) - 제어 인터페이스

| 파라미터 | 값 | 설명 |
|---------|-----|------|
| Data Width | 32-bit | 레지스터 폭 |
| Address Width | 4-bit | 주소 공간 0x0~0xF |
| 레지스터 개수 | 4개 | slv_reg0 ~ slv_reg3 |
| Address Range | 4KB (Vivado 할당) | Block Design 기준 |

#### 제어 레지스터 맵

| Offset | 이름 | 방향 | 비트 필드 | 설명 |
|--------|------|------|----------|------|
| `0x0` | ctrl_reg0 | R/W | `[0]` ap_start | 1 쓰기 = 추론 시작 |
| | | Read | `[1]` network_done | 추론 완료 플래그 (polling) |
| | | | `[31:2]` reserved | |
| `0x4` | ctrl_reg1 | W | `[31:0]` dram_wgt_base | Weight+Bias DRAM 시작 주소 |
| `0x8` | ctrl_reg2 | W | `[31:0]` dram_ifm_base | IFM (입력 이미지) DRAM 주소 |
| `0xC` | ctrl_reg3 | W | `[31:0]` dram_ofm_base | OFM (출력) DRAM 주소 |

**읽기 특수 처리 (slv_reg0):**
```verilog
reg_data_out = {slv_reg0[31:2], network_done, slv_reg0[0]};
```
- bit[1]에 `network_done` 하드웨어 신호가 삽입됨
- MicroBlaze가 `ctrl_reg0`을 polling하여 bit[1]로 완료 감지

### 3.2 AXI4 Master (M) - 데이터 경로

| 파라미터 | 값 | 설명 |
|---------|-----|------|
| Data Width | 32-bit | DRAM word 단위 |
| Address Width | 32-bit | 4GB 주소 공간 |
| Burst Size | 256 words (1KB) | INCR burst |
| Max Transfer (Read) | 262,144 words (1MB) | BITS_TRANS=18 |
| Max Transfer (Write) | 8,192 words | OFM write 단위 |

#### DMA 모듈

| 모듈 | 방향 | AXI 채널 | 용도 |
|------|------|---------|------|
| `axi_dma_rd` | Read | AR + R | Weight, Bias, IFM 읽기 |
| `axi_dma_wr` | Write | AW + W + B | OFM 결과 쓰기 |

---

## 4. DRAM 메모리 맵

### 4.1 전체 메모리 영역

```
DRAM 주소 공간 (ctrl_reg1/2/3 기준 상대 오프셋)
──────────────────────────────────────────────────
0x00000000 ┌──────────────────────────┐
           │  Weight (전체 11 conv)    │  ← dram_wgt_base + 0x00000000
           │  약 9.84 MB              │
0x00A00000 ├──────────────────────────┤
           │  Bias (전체 11 conv)      │  ← dram_wgt_base + 0x00A00000
           │  2,294 words = 9,176 B   │
0x00B00000 ├──────────────────────────┤
           │  IFM (L0 Input)          │  ← dram_ifm_base
           │  256x256x3 = 65,536 words│
0x00C00000 ├──────────────────────────┤
           │  OFM (전체 레이어 출력)    │  ← dram_ofm_base
           │  레이어별 오프셋 사용      │
           └──────────────────────────┘
```

### 4.2 OFM 레이어별 오프셋 (dram_ofm_base 기준)

| 레이어 | Byte Offset | Size | 해상도 |
|--------|------------|------|--------|
| L0 OFM (CONV00) | 0x000000 | 1MB | 256x256x16 -> pool후 128x128x16 |
| L1 OFM (POOL) | 0x100000 | 256KB | 128x128x16 |
| L2 OFM (CONV02) | 0x180000 | 512KB | 128x128x32 -> pool후 64x64x32 |
| L3 OFM (POOL) | 0x200000 | 256KB | 64x64x32 |
| L4 OFM (CONV04) | 0x240000 | 256KB | 64x64x64 -> pool후 32x32x64 |
| L5 OFM (POOL) | 0x280000 | 128KB | 32x32x64 |
| L6 OFM (CONV06) | 0x2A0000 | 128KB | 32x32x128 -> pool후 16x16x128 |
| L7 OFM (POOL) | 0x2C0000 | 64KB | 16x16x128 |
| L8 OFM (CONV08) | 0x2D0000 | 64KB | 16x16x256 -> pool후 8x8x256 |
| L9 OFM (POOL) | 0x2E0000 | 32KB | 8x8x256 |
| L10 OFM (CONV10) | 0x2E8000 | 32KB | 8x8x512 |
| L11 OFM (POOL_S1) | 0x2F0000 | 32KB | 8x8x512 (stride=1) |
| L12 OFM (CONV12) | 0x300000 | 32KB | 8x8x256 (1x1 conv) |
| L13 OFM (CONV13) | 0x308000 | 64KB | 8x8x512 (3x3 conv) |
| L14 OFM (CONV14) | 0x318000 | 16KB | 8x8x195 (detection head) |
| L17 OFM (CONV17) | 0x320000 | 32KB | 8x8x128 (1x1 conv) |
| L18 OFM (Upsample) | 0x328000 | 128KB | 16x16x128 |
| L20 OFM (CONV20) | 0x358000 | - | 16x16x195 (detection head) |

---

## 5. MicroBlaze 통합

### 5.1 시스템 구성

```
MicroBlaze (microblaze_0)
+-- Local Memory (DLMB + ILMB + BRAM)
+-- Debug Module (mdm_1)
+-- UART (axi_uartlite_0) --> Host PC (COM port)
+-- AXI Smart Interconnect (axi_smc)
|   +-- -> MIG 7 Series (DDR2 DRAM)
|   +-- -> yolo_engine_0 (S_AXI slave)
+-- Clock: 50 MHz (clk_wiz_1: 100MHz diff -> 50MHz)
```

### 5.2 소프트웨어 동작 흐름 (main.c)

```c
// 1. UART 통신 초기화
HANDLE comport = open_port("COM4");
test_hello(comport);    // 연결 확인
test_echo(comport);     // 에코 테스트

// 2. DRAM에 데이터 적재 (Host -> UART -> MicroBlaze -> DDR2)
//    2-1. 입력 이미지
write_from_file_to_fpga(comport, "CONV00_input_32b.hex", base_addr, 256*256);

//    2-2. Weight, Bias, Scale (11개 conv 레이어)
for (i = 0; i < 11; i++) {
    write_from_file_to_fpga(comport, weight_file, weight_addr, weight_size);
    write_from_file_to_fpga(comport, bias_file,   bias_addr,   bias_size);
    write_from_file_to_fpga(comport, scale_file,  scale_addr,  scale_size);
}

// 3. YOLO Engine 시작
//    ctrl_reg1 = wgt_base, ctrl_reg2 = ifm_base, ctrl_reg3 = ofm_base
//    ctrl_reg0[0] = 1 (ap_start)
start_engine(comport);

// 4. 완료 대기 (ctrl_reg0[1] = network_done polling)

// 5. 결과 읽기 (DDR2 -> MicroBlaze -> UART -> Host)
read_from_fpga_to_file(comport, output_file, ofm_addr, ofm_size);
```

### 5.3 통신 프로토콜 (Host <-> FPGA)

| 모드 코드 | 이름 | 설명 |
|----------|------|------|
| `0x01` | TEST_HELLO | 연결 확인 |
| `0x02` | TEST_ECHO | 에코 테스트 |
| `0x03` | STORE_RAM | Host -> FPGA DRAM 쓰기 |
| `0x04` | LOAD_RAM | FPGA DRAM -> Host 읽기 |
| `0x05` | STORE_CFG | 설정 레지스터 쓰기 |
| `0x06` | RUN_ENGINE | 추론 시작 (ap_start) |
| `0x07` | PAUSE | 일시 정지 |

---

## 6. 핀 배치 (Constraints)

### system_top.xdc

```
UART (USB):       C4 (RxD), D4 (TxD)         LVCMOS33
LED:              H17 (network_done_led)      LVCMOS33
LED:              K15 (o_network_done)        LVCMOS33
Reset:            N17 (BTNC, active-low)      LVCMOS33
DDR2:             MIG IP가 자동 생성           (Bank 34/35)
Diff Clock:       Board Connection 자동 매핑   100MHz
```

---

## 7. IP 패키징 구조

### 7.1 component.xml (IP-XACT 정의)

```xml
<spirit:vendor>xilinx.com</spirit:vendor>
<spirit:library>user</spirit:library>
<spirit:name>yolo_engine</spirit:name>
<spirit:version>1.0</spirit:version>
```

**버스 인터페이스:**

| 인터페이스 | 프로토콜 | 역할 | 설명 |
|-----------|---------|------|------|
| `S_AXI` | AXI4-Lite | Slave | 제어 레지스터 접근 (MicroBlaze -> IP) |
| `M` | AXI4 (Full) | Master | DRAM 데이터 R/W (IP -> DDR2) |

### 7.2 IP에 포함된 RTL 파일 (17개)

```
yolo_engine.v        yolo_engine_axi.v    conv_top.v
post_process.v       mac_kern.v           mac_stack.v
mul.v                add_tree_36in.v      axi_dma_rd.v
axi_dma_wr.v         ifm_line_buf.v       dpram_wrapper.v
gbuff_param.v        max_pool_unit.v      max_pool_s1_unit.v
upsample_unit.v      user_define_h.v
```

---

## 8. RTL 수정 후 FPGA 빌드 가이드

### 8.1 사전 조건

- Vivado 2025.1 설치
- 프로젝트 폴더 구조가 위 2.1절과 일치
- `<fpga_yolohw>/fpga_yolohw.xpr` 존재
- `<ip_repo>/component.xml` 존재

### 8.2 원클릭 빌드 (권장)

RTL 수정 완료 후, Vivado Tcl 콘솔에서:

```tcl
cd <fpga_yolohw 경로>
source update_ip_and_build.tcl
```

이 스크립트가 자동으로 수행하는 작업:

```
STEP 0: yolohw/src/ -> IP repo/src/ 로 RTL 17개 파일 복사
STEP 1: component.xml 리패키징 (revision 증가)
STEP 2: fpga_yolohw 프로젝트에서 IP 업그레이드 + BD 검증
STEP 3: Synthesis -> Implementation -> Bitstream 생성
```

출력: `<fpga_yolohw>/fpga_yolohw.runs/impl_1/system_wrapper.bit`

### 8.3 수동 빌드 (단계별)

#### STEP 0: RTL 소스 복사

`yolohw/src/` 의 17개 .v 파일을 `<ip_repo>/src/` 에 덮어쓰기 복사.

#### STEP 1: IP 리패키징

```tcl
# Vivado Tcl 콘솔
ipx::open_core <ip_repo>/component.xml
ipx::merge_project_changes files [ipx::current_core]
ipx::merge_project_changes ports [ipx::current_core]
set_property core_revision [expr {[get_property core_revision [ipx::current_core]] + 1}] [ipx::current_core]
ipx::update_checksums [ipx::current_core]
ipx::save_core [ipx::current_core]
ipx::unload_core [ipx::current_core]
```

#### STEP 2: 시스템 프로젝트 IP 갱신

```tcl
open_project <fpga_yolohw>/fpga_yolohw.xpr
set_property IP_REPO_PATHS <ip_repo> [current_project]
update_ip_catalog -rebuild
open_bd_design [get_files system.bd]
upgrade_ip [get_ips system_yolo_engine_0_3] -quiet
validate_bd_design
generate_target all [get_files system.bd]
close_bd_design [current_bd_design]
make_wrapper -files [get_files system.bd] -top -force
```

#### STEP 3: 합성 + 비트스트림

```tcl
reset_runs synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
```

### 8.4 경로 설정 (update_ip_and_build.tcl)

스크립트 상단의 경로를 자신의 환경에 맞게 수정:

```tcl
set IP_REPO_PATH     "<ip_repo 절대경로>"        # component.xml 위치
set SYSTEM_PROJECT   "<fpga_yolohw>/fpga_yolohw.xpr"
set BD_YOLO_IP_INST  "system_yolo_engine_0_3"     # BD 내 IP 인스턴스 이름
set RTL_SRC_DIR      "<project_root>/yolohw/src"   # RTL 소스 폴더
```

### 8.5 주의사항

| 항목 | 설명 |
|------|------|
| **RTL 수정 위치** | 반드시 `yolohw/src/` 에서만 수정. IP repo는 자동 복사됨 |
| **포트 변경 없으면** | BD 수정 불필요 (IP Upgrade만 하면 됨) |
| **포트 변경 시** | component.xml portMap 업데이트 + BD 재연결 필요 |
| **BD 변경 불필요 조건** | conv_top, mac_kern, post_process 등 내부 서브모듈만 수정한 경우 |
| **BD 변경 필요 조건** | yolo_engine.v 또는 yolo_engine_axi.v의 최상위 포트가 바뀐 경우 |

---

## 9. 양자화 파라미터

### 9.1 I/W 스케일 값 (Original, hex 파일 생성 기준)

| 레이어 | I (Input Scale) | W (Weight Scale) | I*W | Shift |
|--------|----------------|-----------------|-----|-------|
| CONV00 | 128 | 16 | 2048 | 8 (div 256) |
| CONV02 | 8 | 64 | 512 | 6 (div 64) |
| CONV04~CONV20 | 8 | 64 | 512 | 6 |

### 9.2 Descaling 방식

- **C Golden (SW)**: `pixel = (int16_t)(output_q / (I*W) * next_I)` (float)
- **Hardware (RTL)**: `pixel = activated >>> shift_amount` (산술 우측 시프트)
- Original I/W가 모두 2의 거듭제곱이므로 두 방식은 수학적으로 동일

---

## 10. 레이어별 Weight 크기

| 레이어 | 커널 | In Ch | Out Ch | Weight (bytes) | Bias |
|--------|------|-------|--------|---------------|------|
| CONV00 | 3x3 | 3 | 16 | 432 | 16 |
| CONV02 | 3x3 | 16 | 32 | 4,608 | 32 |
| CONV04 | 3x3 | 32 | 64 | 18,432 | 64 |
| CONV06 | 3x3 | 64 | 128 | 73,728 | 128 |
| CONV08 | 3x3 | 128 | 256 | 294,912 | 256 |
| CONV10 | 3x3 | 256 | 512 | 1,179,648 | 512 |
| CONV12 | 1x1 | 512 | 256 | 131,072 | 256 |
| CONV13 | 3x3 | 256 | 512 | 1,179,648 | 512 |
| CONV14 | 1x1 | 512 | 195 | 99,840 | 195 |
| CONV17 | 1x1 | 256 | 128 | 32,768 | 128 |
| CONV20 | 1x1 | 384 | 195 | 74,880 | 195 |

---

## 11. BRAM IP 구성

YOLO Engine 내부에서 사용하는 BRAM IP 목록:

| IP 이름 | 타입 | 크기 | 폭 | 용도 |
|---------|------|------|-----|------|
| `dpram_4096x72_288` | Dual Port | 4096 x 72 | Read: 288-bit | Weight 버퍼 (conv_top) |
| `spram_2560x32` | Single Port | 2560 x 32 | 32-bit | Bias/Shift 버퍼 |

BRAM IP 생성 스크립트: `yolohw/fpga/gen_bram_ips.tcl`

---

## 12. Block Design 내 IP 인스턴스 목록

| 인스턴스 | IP | 버전 |
|---------|-----|------|
| `microblaze_0` | MicroBlaze | v11.0 |
| `microblaze_0_local_memory` | LMB + BRAM | - |
| `mdm_1` | MicroBlaze Debug Module | - |
| `clk_wiz_1` | Clocking Wizard | 6.0 |
| `rst_clk_wiz_1_100M` | Proc Sys Reset | 5.0 |
| `rst_mig_7series_0_50M` | Proc Sys Reset | 5.0 |
| `axi_uartlite_0` | AXI UARTLite | 2.0 |
| `mig_7series_0` | MIG 7Series | 4.2 |
| `axi_smc` | SmartConnect | 1.0 |
| `axi_smc_1` | SmartConnect | 1.0 |
| `yolo_engine_0` (system_yolo_engine_0_3) | yolo_engine | 1.0 |
| `reset_inv_0` | Utility Vector Logic | 2.0 |

---

## 13. 외부 포트 (Block Design -> FPGA 핀)

| 포트 이름 | 방향 | 연결 대상 | FPGA 핀 |
|----------|------|----------|---------|
| `DDR2_0` | Inout | MIG DDR2 버스 | Bank 34/35 (자동) |
| `diff_clock_rtl` | Input | 100MHz 차동 클록 | Board 자동 매핑 |
| `usb_uart_rxd` | Input | UART 수신 | C4 |
| `usb_uart_txd` | Output | UART 송신 | D4 |
| `reset_0` | Input | 리셋 버튼 (BTNC) | N17 |
| `network_done_led_0` | Output | LED 표시 | H17 |
| `o_network_done_0` | Output | 완료 신호 LED | K15 |
