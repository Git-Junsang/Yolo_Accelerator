# SOLUTION.md — L0/L1/L2 단위 검증 TB + 구조 결함 분석

작성일: 2026-05-22, 브랜치 `phase3_error`

본 문서는 사용자 요구에 따라 **레이어 하나씩 격리 검증할 수 있는 testbench**
3 종 (L0, L1, L2) 을 추가하면서 발견한 RTL 구조적 문제를 정리한다.
TB 컴파일은 본 환경 (Linux iverilog) 에서 검증 완료, 실제 시뮬레이션은
Windows Vivado 에서 사용자가 직접 실행한다.

---

## 1. 추가된 파일

| 파일 | 설명 |
|------|------|
| `yolohw/testbench/yolo_engine_l0_tb.v` | **격리** — L0 단독 conv 검증 (image → DRAM IFM → L0 → DRAM OFM) |
| `yolohw/testbench/yolo_engine_l1_tb.v` | **격리** — L1 단독 maxpool 검증 (OFM dpram seed → L1 → DRAM OFM) |
| `yolohw/testbench/yolo_engine_l2_tb.v` | **격리** — L2 단독 conv 검증 (DRAM IFM seed → L2 → DRAM OFM) |
| `yolohw/testbench/yolo_engine_l012_chain_tb.v` | **연결** — L0 → L1 → L2 연속 실행 + 중간 OFM 검증 (★ L1→L2 실제 전달 검증) |
| `yolohw/src/define.v` | iverilog 컴파일 호환용 빈 stub (mul.v 가 `` `include "define.v" `` 참조하나 파일 미존재) |

**격리 TB vs 연결 TB 의 차이**:
- 격리 TB (L0/L1/L2 각자): 해당 layer 의 입력을 **골든값으로 직접 적재** → 해당 layer 자체의 RTL 동작만 격리 검증. 이전 layer 의 결함과 분리.
- 연결 TB (chain): `ap_start` 로 L0 부터 자연스럽게 실행 → L0 의 실제 출력이 L1 의 입력으로, L1 의 실제 출력이 L2 의 입력으로 전달. **L1 → L2 사이의 데이터 전달 (DRAM → ifm_line_buf) 경로를 실제 RTL 신호로 검증**. 사용자가 보고한 "L1→L2 데이터가 안가는 것 같다" 의 직접 증거 수집.

각 TB 는 `yolo_engine` 최상위 모듈 전체를 instantiate 한 뒤, reset 해제 후
`force u_yolo_engine.layer_idx = N; force u_yolo_engine.top_state = 4'd1`
방식으로 해당 layer 부터 1 cycle 만 강제 → `release` 하여 자연 FSM 진행한다.
종료 조건: `layer_idx` 가 `N+1` 로 증가한 시점.

---

## 2. Vivado 실행 방법 (사용자)

Vivado 프로젝트 `vivado_yolohw.xpr` 의 sim_1 set 에서 TB top 만 교체:

```tcl
# Vivado TCL console 에서 한 줄씩

# (1) 각 layer 격리 검증
set_property top yolo_engine_l0_tb [get_filesets sim_1]
launch_simulation

set_property top yolo_engine_l1_tb [get_filesets sim_1]
relaunch_sim

set_property top yolo_engine_l2_tb [get_filesets sim_1]
relaunch_sim

# (2) L0→L1→L2 연결 검증 (실제 데이터 전달)
set_property top yolo_engine_l012_chain_tb [get_filesets sim_1]
relaunch_sim
```

데이터 파일 (`gen_*_dram.mem`, `log_feamap/CONV*.hex`) 경로는 Vivado xsim cwd 기준
상대 경로 `../../../../../../testbench/inout_data_sw/...` 로 작성되어 있다.
경로 문제가 있으면 TB 상단 `parameter ... = "..."` 부분만 절대 경로로 수정.

---

## 3. 핵심 발견 — L1 → L2 데이터 흐름 결함

사용자가 보고한 "L0 → L1 은 전달 되는데 L1 → L2 는 안 간다" 의 원인 후보 2 가지를
TB 가 분리 검증할 수 있도록 설계되었다.

### 결함 A — OFM dpram 용량 부족 (L1 입력 손상 가능성)

**위치**: `yolo_engine.v` 의 `u_ofm` dpram (`DEPTH=65536, AW=16`)

**문제**:
- L0 OFM = 16 filter × 128 × 128 = **262,144 word** (dpram 의 4 배).
- L0 는 `stream_mode=1` 로 매 필터 마다 DRAM 에 dump 하면서 동시에 dpram 의 동일
  주소 영역에 다음 필터를 덮어쓰기 한다 (`conv_top.frame_offset_r` 가 누적되지만
  dpram 의 `addra[15:0]` 는 wrap).
- 즉 L0 종료 시점 dpram 에는 **마지막 4 필터 (#12..#15) 만** 남아 있다.
- L1 maxpool 은 `i_total_in_words = Co × ofm_w × ofm_h = 262144` 으로 set 되어
  `o_rd_addr = in_addr_r[15:0]` 를 0..262143 으로 진행 → **modulo 65536 wrap**.
- 결과: L1 출력 16 필터가 모두 "pool(L0 #12..#15) 4 회 반복" 으로 채워짐.
- 이 데이터가 그대로 DRAM 으로 dump → L2 가 DRAM 에서 읽어 들이는 IFM 도 손상.

**TB 격리 방법** (`yolo_engine_l1_tb.v`):
- dpram[0..65535] 에 L0 OFM 의 **first 4 filter** (#0..#3) 을 골든값으로 직접 적재
  (`u_yolo_engine.u_ofm.ram[idx] = ...`).
- L1 실행 후 DRAM[L1 OFM] 의 filter 0..3 / 4..15 를 분리 집계.
- 기대 결과:
  - filter 0..3 mismatch = 0 → max_pool 자체 동작 OK
  - filter 4..15 mismatch 대량 → dpram 용량 부족 확정.

### 결함 B — L2 자체 (rb_stream / line_buf / weight DMA)

**위치**: `yolo_engine.v` 의 IFM rb_stream FSM + `ifm_line_buf.v` + `conv_top.v`

**상황** (Phase 3 메모리 노트 기록):
- 이전 세션에서 `lb_addr_calc` 오버플로우 + `rb_stream` 구현으로 수정 완료라고
  기록되어 있으나, 사용자 보고는 여전히 L2 에서 진행 안됨.
- 본 TB 는 결함 A 를 우회 (DRAM IFM 을 골든값으로 직접 packed 형식으로 적재) 하여
  L2 자체의 동작만 확인.

**TB 격리 방법** (`yolo_engine_l2_tb.v`):
- WGT/BIAS 를 기존 `gen_wgt_dram.mem`, `gen_bias_dram.mem` 으로 로드.
- L2 IFM (= L1 OFM 골든, CONV02_input.hex) 을 **L2 의 IFM packed format** 으로
  DRAM[OFM_BASE + 262144 × 4] 에 직접 적재 (TB initial 블록 내 nested loop).
  - row r, eir = g × 32 + cb (g: 0..3 ci_group, cb: 0..31 col_block)
  - 1 entry = 16 byte = 4 col × 4 ch:
    `byte[col_l × 4 + ch_l] = pixel(c=g*4+ch_l, h=r, w=cb*4+col_l)`
- L2 실행 후 DRAM[L2 OFM] 을 CONV02_output.hex 와 비교.
- TB 출력 중 모니터해야 할 항목:
  1. **IFM_LB WR** (각 row 의 첫/마지막 entry) — DMA → line_buf 로의 데이터 흐름.
  2. **rb_stream** rb 인덱스 진행, `rb_stream_ifm_first_r` 갱신 추적.
  3. **LB RD** (첫 32 cycle) — line_buf → conv_top 으로 ifm 데이터가 흐르는지.
  4. **CONV PIX vld** (첫 16 픽셀) — MAC 결과가 0/bias-only 가 아닌 실제 값인지.
  5. **OFM DMA** (각 burst 시작) — `stream_dma_addr` 계산이 올바른지.

---

## 4. RTL 수정 권고 (사용자 결정 필요)

### 권고 1 — L0 OFM 도 외부 DRAM 으로 streaming 한 뒤, L1 도 DRAM 에서 읽기
- 현행: L1 은 dpram 에서 읽는다고 가정 (`yolo_engine.v` L968-973). 이 가정이 깨짐.
- 수정안: L1 이 `lyr_pool_en` 인 경우에도, **이전 layer 가 stream_mode 였다면**
  DRAM 의 prev_layer OFM 영역에서 row 단위로 DMA load 후 pool 처리.
- 영향 layer: L1 (stride-2, L0 직후), L3 (stride-2, L2 직후) 도 동일 패턴.
- 구현 부담: max_pool_unit 에 외부 input source mux + ifm_line_buf 와 유사한
  streaming FSM 추가 필요. **상당량**.

### 권고 2 — OFM dpram 크기 확장
- 현행 65,536 word → 262,144 word 로 4 배 확장 시 결함 A 즉시 해소.
- 비용: 65536 × 32-bit dpram 4 개 ≈ BRAM 36 Kb × 32 개 = 1.15 Mbit.
  Artix-7 XC7A100T 총 BRAM = 4.86 Mb. 약 24% 점유.
  현재 dpram 1 개 = ~6% → 4 개 = ~24%. 다른 BRAM (line_buf 4 × 2048 × 128-bit,
  gbuff_param 등) 합산 시 보드 BRAM 한계 근접 가능.
- 가장 단순한 fix 지만 보드 자원 검토 필요.

### 권고 3 — Layer 별 OFM dpram 영역 재사용을 conv_top 측에서 명시적 제한
- 현행: `conv_top.frame_offset_r` 가 누적 → wrap 으로 인한 데이터 손상.
- 수정안: `stream_mode=1` 일 때 `conv_top` 이 filter 1 개 분량 (dpram 한 영역) 에만
  쓰고 DMA dump 후 같은 영역에 다음 filter 를 덮어쓰도록 변경.
  이미 `stream_mode` 로직이 그렇게 의도되어 있지만 `frame_offset_r` 의 누적이
  의도와 충돌. ofm_wr_addr = `conv_pixel` slot 의 하위 비트만 사용하도록 보정.
- L1 (pool) 은 여전히 dpram 전체를 입력으로 받지 못하므로, **권고 1 과 병행** 필요.

### 권고 4 — 검증 우선 진행: 결함 분리 후 RTL 변경
- 먼저 L2 TB 단독 실행하여 결함 B (L2 자체) 가 사라졌는지 확인.
  - PASS 시 → L1→L2 데이터 전달 문제는 결함 A (dpram wrap) 이 단독 원인.
  - FAIL 시 → L2 자체에도 잔존 버그 존재. TB log 의 LB RD / CONV PIX vld 사용해 추적.
- L2 PASS 확인 후 권고 1~3 중 채택안 결정.

---

## 5. TB 모니터 출력 해석 가이드

### `[Lx-TB][t] L<idx> top_state A→B`
FSM 의 `top_state` 전이.
- 0=IDLE, 1=INIT, 2=DMA_WGT, 3=DMA_WGT_WAIT, 4=DMA_BIAS, 5=DMA_BIAS_WAIT,
  6=DMA_IFM, 7=DMA_IFM_WAIT, 8=RUN_CONV, 9=RUN_POOL, 10=DMA_OFM,
  11=DMA_OFM_WAIT, 12=NEXT, 13=DONE, 14=DMA_IFM_ROW_WAIT (rb_stream).

### `IFM_LB WR row=R bank=B addr=A data[31:0]=W`
DMA 가 line buffer 에 IFM entry 1 개 쓴 시점. row 의 첫/마지막 entry 만 표시.
- bank = `row mod 4` 가 정확한지 확인.
- addr = `eir` (entry-in-row) 0..127 (L2), 0..63 (L0).
- data[31:0] = entry 16 byte 중 첫 word (4 col × 1 ch).

### `rb_stream rb=R (mode=M, ifm_first=F, conv_h_half=H)`
rb_stream FSM 진행. rb 가 0..(ofm_h_half-1) 까지 순차 증가해야 함.
`ifm_first` = 다음 IFM DMA 의 첫 row 번호. `conv_h_half = 1` (rb_stream 모드) 여야.

### `LB RD row=R col=C acc=A  ifm00[31:0]=X ifm01[31:0]=Y`
line_buf 로부터 conv_top 이 ifm window 를 받은 시점.
- `acc` 0..acc_len-1 (L2: 0..3 = 4 ci_group).
- ifm 값이 모두 0 이면 → line_buf 에 데이터가 안 들어옴 (DMA 경로 문제).
- ifm 값이 있는데 conv pixel 이 bias 만 (0x0b 등) 이면 → MAC 경로 또는 weight 문제.

### `CONV PIX vld addr=A data=W`
conv_top 의 출력 픽셀. addr 은 `frame_offset + out_cnt`.
- data 의 4 byte 가 골든 byte 와 일치하는지 spot check.

### `OFM DMA #N addr=A len=L  rb=R`
DRAM 에 OFM 1 burst 를 쓴 시점. L2 의 rb_stream 모드에서는 매 (rb, fil) 별로
짧은 burst (len=ofm_w_half=32) 가 여러 번 발생.

---

## 6. 다음 단계

1. **L0 TB 먼저 실행**. 통과 시 L0 자체와 IFM DMA / stream OFM DMA 경로 OK.
2. **L1 TB 실행**. filter 0..3 PASS / filter 4..15 FAIL 패턴 확인 → 결함 A 확정.
3. **L2 TB 실행**. PASS / FAIL 결과로 결함 B 잔존 여부 판정.
4. 결과에 따라 권고 1~3 중 채택안 결정 후 RTL 수정. 수정 사항은 본 SOLUTION.md
   의 "수정 이력" 섹션에 추가 기록.

---

## 수정 이력

### 2026-05-22 — `lyr_ofm_w_half[15:0]` 범위 초과 슬라이스 (★ 근본 원인 확정)

**증상** (`yolo_engine_l012_chain_tb` 결과):
- L0 OFM mismatch 1,048,576 / 1,048,576 — **DRAM 전체가 `xxxxxxxx`**
- L1 DMA WR `data=xxxxxxxx`, L2 IFM DMA RD `data=xxxxxxxx`
- 단, `dpram pre-L1 sample: [0]=00000100` 은 유효 → conv MAC 자체는 정상 동작

**진단 (Vivado elaborate.log 결정적 단서)**:
```
WARNING: [VRFC 10-3705] select index 15 into 'lyr_ofm_w_half' is out of bounds [yolo_engine.v:781]
```

[yolo_engine.v:781](yolohw/src/yolo_engine.v#L781) 의 `lyr_ofm_w_half[15:0]` — `lyr_ofm_w_half` 는 `wire [11:0]` (12-bit) 이므로 [15:0] 슬라이스 시 상위 4 bit 가 **X** 로 평가됨 (IEEE 1800 §11.5.1).

**전파 경로**:
```
lyr_ofm_w_half[15:12] = X
  → (stream_fil_cnt - 1) * lyr_ofm_w_half[15:0] = 16-bit 결과에 X bit 포함
  → ofm_store_rd_addr_r = X
  → dpram port B addrb = X
  → ofm_rd_data = ram[X] = X
  → dma_wr_indata = X
  → M_WDATA = X
  → DRAM 전체에 X 가 쓰여짐
```

conv 가 port A 로 직접 쓴 dpram cell 자체는 정상 (0x00000100). 하지만 port B 의 read 가 X 주소로 들어가서 invalid 데이터를 읽어 DRAM 으로 출력. **rb_stream + stream_mode 가 활성인 L0/L2 양쪽 모두 영향**.

**수정**:
```verilog
// Before:
ofm_store_rd_addr_r <= rb_stream_mode_r ?
    ((stream_fil_cnt[7:0] - 8'd1) * lyr_ofm_w_half[15:0]) :
    ...
// After (zero-extend 으로 16-bit 정렬):
ofm_store_rd_addr_r <= rb_stream_mode_r ?
    ((stream_fil_cnt[7:0] - 8'd1) * {4'd0, lyr_ofm_w_half}) :
    ...
```

**기대 효과**:
- L0 OFM DRAM 정상화 (사용자가 의심하던 "L0→L1 잘 됨" 도 실은 망가져 있던 것)
- L2 OFM 도 동시 정상화 (같은 stream_mode 경로 사용)
- 단, L1 의 dpram 용량 문제 ("결함 A") 는 여전히 잠재: L1 maxpool 이 dpram[0..262143] 을 wrap 으로 읽음. **L0 OFM 정상 시점에서 L1 결과 재확인 필요** — wrap 의 실제 영향이 어느 정도인지 새 시뮬레이션 후 판단.

**다음 단계**: 동일 chain TB 재실행 → L0/L1/L2 mismatch 분포 확인 → 잔존 문제 식별.

---

### 2026-05-22 (2차) — L1 pool chunked DMA 복원 (★ L1→L2 데이터 전달 결함 해소)

**증상** (1차 fix 후 chain TB 재실행):
- L0 OFM mismatch 681,573 / 1,048,576 — `got=0a exp=0b` 등 실제 byte 값 (XX 없음).
  → 1차 fix 가 L0 자체는 회복시켰지만 정확도 mismatch 잔존 (별개 이슈).
- **L1 OFM mismatch 65,524 / 65,536 (f0..3), 196,271 / 196,608 (f4..15) — 여전히 `got=xx`**.
- L2 OFM 524,288 / 524,288 — 전부 `got=xx` (L1 입력 XX → L2 IFM XX → L2 출력 XX).

**진단**:
이전 작동 commit `5390f33a` ("phase3 문제 해결중", orphan 브랜치) 와 현재 브랜치를 비교한 결과,
L1 의 핵심 동작 메커니즘이 누락되어 있었음:

L0 가 `stream_mode + rb_stream` 으로 OFM 을 DRAM 에만 dump 하는 동안, L0 종료 시점의
**OFM dpram 에는 마지막 rb (= 2 행) 분량의 데이터만 남음** (addr 0..2047). 나머지
addr 2048..65535 는 절대 쓰여지지 않아 `xxxxxxxx`. L1 maxpool 은 dpram[0..262143]
(mod 65536 wrap) 을 읽으므로 대부분이 X → L1 OFM 전부 X → DRAM → L2 IFM → L2 OFM 도 X.

이전 commit `5390f33a` 에서는 이 문제를 **DRAM → dpram 청크 단위 재로드 메커니즘**
(`stream_pool_mode` + `DMA_TGT_DPRAM`) 으로 해결했었음. 이 메커니즘이 현재 브랜치의 cleanup
과정에서 누락된 것으로 판단됨.

**수정 (yolo_engine.v 6 군데)**:

1. **DMA target 추가**: `DMA_TGT_DPRAM = 2'd3` (DRAM → OFM dpram 직접 적재용)
2. **레지스터/와이어 추가**:
   ```verilog
   reg        stream_pool_mode;       // pool 입력 > 65536 word 시 활성
   reg  [2:0] pool_chunk_cnt;          // 현재 처리 중인 청크 인덱스
   wire [3:0] pool_num_chunks = pool_total_in_r[19:16];  // 총 청크 수
   reg  [15:0] dma_dpram_addr_r;       // DPRAM DMA 쓰기 주소
   wire        dma_dpram_we = dma_rd_data_vld && (dma_target_r == DMA_TGT_DPRAM);
   ```
3. **OFM port A mux 확장**: `dma_dpram_we → dma_dpram_wr_addr/data` 입력 추가.
4. **max_pool_unit `i_total_in_words`**: stream_pool_mode 시 `20'd65536` 고정 (청크 단위).
5. **`ofm_store_rd_addr_r` 계산에 `lyr_conv_en` 조건 추가**: pool layer 에서 stream_mode 잔류
   시 stream_fil_cnt 가 의미 없는 값으로 mis-set 되는 것 방지.
6. **FSM 흐름**:
   - `ST_INIT`: `stream_pool_mode <= lyr_pool_en && !lyr_s1_pool_en && (Co×H×W > 65536)`
   - `ST_DMA_IFM` (pool 분기): `stream_pool_mode` 시 `DMA_TGT_DPRAM` 으로 청크 0 (65536 word) 로드.
   - `ST_DMA_IFM_WAIT`: `stream_pool_mode ? ST_RUN_POOL : ST_RUN_CONV`.
   - `ST_DMA_OFM` (pool 분기): `stream_pool_mode` 시 16384 word 만 DRAM dump,
     addr = `addr_ofm + chunk × 16384 × 4 byte`.
   - `ST_DMA_OFM_WAIT`: 남은 청크 있으면 다음 청크 DMA 로드 후 `ST_DMA_IFM_WAIT` 재진입.

**기대 효과**:
- L1: 4 chunks × (DMA load → pool → DMA store) 사이클로 정상 동작.
- L3 (32×128×128 = 524288 word = 8 chunks): 동일 메커니즘으로 자동 처리.
- L5/L7/L9 등 다른 stride-2 pool 도 동일 (입력 ≤ 65536 인 경우 stream_pool_mode 비활성, 기존 dpram 입력 경로).
- L2: L1 출력 정상화 → L2 IFM 정상 → L2 OFM 의 XX 도 해소 기대.
- L0 의 잔존 byte 값 mismatch 는 별개 (1차 fix 후에도 681,573 mismatch → conv 정확도 이슈).

**컴파일 검증**: 4 TB (l0/l1/l2/chain) + golden_tb 모두 iverilog 통과.

**다음 단계**: chain TB 재실행 → L1 f0..3 PASS 여부 + L2 OFM 의 XX 해소 여부 확인 →
L0 의 byte 값 mismatch 원인 추적 (1차 fix 가 정확도까지 보장하지 않으므로, MAC/shift/bias
경로 별도 분석 필요).
