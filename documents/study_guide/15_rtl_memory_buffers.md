# 15장. RTL — 메모리 버퍼 (코드 해설)

> [← 14장 Convolution 엔진](14_rtl_convolution_engine.md) · [목차](README.md) · 다음 장: [16장 특수 연산 유닛 →](16_rtl_special_units.md)
> **이 장을 읽기 위한 준비**: [3장 3.4 BRAM](03_fpga_basics.md), [4장 4.4 BRAM latency](04_rtl_timing_basics.md), [12장 데이터 포맷](12_data_representation_memory_map.md).

---

[14장](14_rtl_convolution_engine.md)의 144-MAC이 매 클럭 굶지 않으려면, 버퍼가 정확한 포맷·타이밍으로 데이터를 공급해야 합니다. 이 장은 네 버퍼를 다룹니다: 입력 윈도우를 만드는 `ifm_line_buf`(가장 복잡), 가중치를 담는 `gbuff_param`, 그리고 그 기반인 `dpram_wrapper`/`spram_wrapper`입니다.

---

## 15.1 ifm_line_buf.v — 입력 윈도우 공장

[ifm_line_buf.v](../../yolohw/src/ifm_line_buf.v)는 이 프로젝트에서 **가장 까다로운 데이터 정렬**을 합니다. 역할: DRAM에서 받은 NHWC entry([12장 12.2-②](12_data_representation_memory_map.md))를 4행으로 쌓고, 합성곱이 요청하는 3×3 윈도우를 36바이트씩 4벌 뽑아주는 것.

💡 **비유**: 합성곱은 이미지 위를 슬라이딩하며 3×3 창문으로 봅니다([1장 1.3](01_cnn_basics.md)). 라인 버퍼는 "지금 필요한 4줄"을 들고 있다가, 요청이 오면 그 위치의 창문(윈도우)을 잘라 건네주는 역할입니다.

### 15.1.1 왜 4줄만 들고 있나

3×3 합성곱은 인접 3줄을 동시에 봅니다. 2×2 출력 블록(아래 줄도 필요)을 위해 1줄 더, 총 **4줄**이면 충분합니다. 줄이 진행되면 가장 오래된 줄을 새 줄로 덮어씁니다(**cyclic**, 순환).

```
4개 bank(줄 저장소): bank0, bank1, bank2, bank3
   줄이 진행 → 가장 오래된 bank를 새 줄로 덮어씀 (원형으로 순환)
   어느 bank에 어느 줄? → "입력행 mod 4"
```

### 🔍 코드 해설 — cyclic 매핑

```verilog
wire [1:0] base_line = i_rb[0] ? 2'd1 : 2'd3;  // (2*Rb-1) mod 4
wire [1:0] line_sel_0 = base_line;
wire [1:0] line_sel_1 = base_line + 2'd1;       // mod 4 (2비트라 자동 wrap)
```

출력 행블록 `i_rb`가 1 진행하면 입력 줄은 2 진행하므로, base가 토글됩니다. 이 매핑으로 "새 줄을 어느 bank에 쓸지"와 "윈도우를 읽을 때 어느 bank를 볼지"가 일치합니다.

### 🔍 코드 해설 — 3×3 윈도우 주소

```verilog
wire signed [13:0] col_start_s  = $signed({1'b0, i_cb, 1'b0}) - 14'sd1;  // 2*Cb - 1
wire signed [13:0] base_entry_s = col_start_s >>> 2;                      // entry 인덱스
wire        [1:0]  offset_3x3   = col_start_s[1:0];                       // entry 내 위치
wire [10:0] rd_addr_a_3x3 = row_off[10:0] + base_entry_u;       // entry A
wire [10:0] rd_addr_b_3x3 = row_off[10:0] + base_entry_u + 1;   // entry B
```

- `col_start = 2*Cb - 1`: 2×2 출력 블록이 보는 입력의 왼쪽 열(패딩 −1 포함, [1장 1.4](01_cnn_basics.md)).
- entry 하나가 4열을 담으므로([12장 12.2-②](12_data_representation_memory_map.md)), 원하는 열이 entry 경계를 걸치면 **두 entry(A, B)를 읽어** offset으로 잘라 붙입니다.

### 🔍 코드 해설 — 경계 패딩

```verilog
if (!i_mode) begin   // 3×3 모드만 패딩
    if (row_inv_r[rr]) begin window[rr][0..3] = 0; end  // 행이 경계 밖이면 0
    else begin
        if (col_inv_r[0]) window[rr][0] = 0;             // 열이 경계 밖이면 0
        ...
    end
end
```

`pad=1` 합성곱의 가장자리 처리([1장 1.4](01_cnn_basics.md)). 윈도우가 이미지 밖으로 나가면 그 칸을 0으로 채웁니다.

### 🔍 코드 해설 — 36바이트로 패킹 (3×3)

```verilog
for (cl_loc=0; cl_loc<4; cl_loc++)         // 입력 채널 4개
  for (kh=0; kh<3; kh++)                    // 커널 행
    for (kw=0; kw<3; kw++) begin            // 커널 열
        idx = cl_loc*9 + kh*3 + kw;          // 0~35
        ifm00_w[idx*8 +: 8] = win_byte(kh,   kw,   cl_loc);  // 출력(0,0)용
        ifm01_w[idx*8 +: 8] = win_byte(kh,   kw+1, cl_loc);  // 출력(0,1)용
        ifm10_w[idx*8 +: 8] = win_byte(kh+1, kw,   cl_loc);  // 출력(1,0)용
        ifm11_w[idx*8 +: 8] = win_byte(kh+1, kw+1, cl_loc);  // 출력(1,1)용
    end
```

- `idx = cl_loc*9 + kh*3 + kw`: [12장 12.4](12_data_representation_memory_map.md)에서 본 가중치 배치(채널×9 + 커널위치)와 **똑같은 순서**로 입력을 배치합니다. 그래야 `mac_stack`의 곱셈기 i번이 "가중치 i × 입력 i"로 짝이 맞습니다([14장 14.4](14_rtl_convolution_engine.md)).
- `ifm00/01/10/11`: 2×2 출력의 네 위치는 윈도우가 1칸씩 어긋납니다(`kw` vs `kw+1`, `kh` vs `kh+1`).

### 🔍 코드 해설 — 1×1 패킹 (채널 정렬)

```verilog
// 1×1 모드: 채널 0~3을 byte 0, 9, 18, 27 위치에 배치
ifm00_w[7:0]     = window[1][col_inblk_r][7:0];     // ch0 @ byte0
ifm00_w[79:72]   = window[1][col_inblk_r][15:8];    // ch1 @ byte9
ifm00_w[151:144] = window[1][col_inblk_r][23:16];   // ch2 @ byte18
ifm00_w[223:216] = window[1][col_inblk_r][31:24];   // ch3 @ byte27
```

- 1×1은 커널이 점 하나라 채널당 입력 1개. 가중치 슬롯이 채널을 byte 0/9/18/27에 두므로([12장 12.4](12_data_representation_memory_map.md)), 입력도 **같은 위치**에 맞춥니다.
- ⚠️ 이 정렬을 빠뜨려 ch1~3 곱셈이 무시되던 것이 Phase 2의 1×1 버그였습니다(수정 후 L12 mismatch 10997→0, [HISTORY](../../HISTORY.md)).

### 15.1.2 타이밍 — latency 2

```
i_rd_en → (BRAM 읽기 1클럭) → 윈도우 추출(조합) → 출력 레지스터(1클럭) → 총 2클럭
```

[4장 4.4](04_rtl_timing_basics.md)에서 본 BRAM latency 때문에, conv_top이 **look-ahead로 다음 좌표를 미리** 보냅니다([14장 14.7](14_rtl_convolution_engine.md)). 라인 버퍼 내부에서도 offset·경계 판정을 1클럭 지연(`offset_r` 등)시켜 BRAM 출력과 맞춥니다.

---

## 15.2 gbuff_param.v — 가중치·bias 창고

[gbuff_param.v](../../yolohw/src/gbuff_param.v)는 현재 레이어의 가중치와 bias를 담습니다.

### 🔍 코드 해설 — 비대칭 가중치 메모리

```verilog
// 읽기: 288비트 entry = 4개의 72비트를 합침
rd_wgt_data_r <= { wgt_mem[{rd_wgt_addr, 2'd3}], wgt_mem[{rd_wgt_addr, 2'd2}],
                   wgt_mem[{rd_wgt_addr, 2'd1}], wgt_mem[{rd_wgt_addr, 2'd0}] };
```

- 쓰기는 72비트씩, **읽기는 288비트(=4×72)** 입니다([12장 12.4](12_data_representation_memory_map.md)). 한 번 읽으면 36개 가중치가 나와 `mac_stack`의 36 곱셈기에 바로 들어갑니다.
- DMA로 들어오는 가중치는 좁게(72비트) 쓰고, 곱셈기에는 넓게(288비트) 한 번에 공급 — 이 비대칭이 효율의 핵심입니다.

### 🔍 코드 해설 — bias 메모리

```verilog
reg [31:0] bias_mem [0:2559];          // 32비트 × 2560칸
rd_bias_data_r <= bias_mem[rd_bias_addr];
```

- entry당 32비트에 `{bias16, shift16}`를 담습니다([12장 12.5](12_data_representation_memory_map.md)). 전체 레이어 필터 수 합(~2294)이 2560 안에 들어가 한 번에 적재합니다.
- 읽기 latency 1클럭. conv_top의 `ST_LOAD`가 이를 흡수합니다([14장 14.7](14_rtl_convolution_engine.md)).

### 15.2.1 가중치 streaming의 그림

[13장 13.6](13_rtl_yolo_engine_top.md)·[14장 14.7](14_rtl_convolution_engine.md)에서 본 streaming을 메모리 관점으로 보면:

```
전체 가중치 (수 MB) → BRAM(36KB)에 다 못 담음
해결: 필터마다 그 필터 가중치만 DMA로 BRAM[0]부터 채움 → 합성곱 → 다음 필터로
```

❓ **왜 streaming?**: L6 이후 레이어는 가중치가 BRAM(4096칸)을 초과합니다. 그래서 전체를 올릴 수 없고, **필터 하나 분량만** 그때그때 가져옵니다. 대신 DRAM 접근이 늘지만, 가중치는 한 번만 읽으면 되므로 감당할 만합니다([3장 3.4](03_fpga_basics.md)).

---

## 15.3 dpram_wrapper.v / spram_wrapper.v — BRAM 껍데기

[dpram_wrapper.v](../../yolohw/src/dpram_wrapper.v)·[spram_wrapper.v](../../yolohw/src/spram_wrapper.v)는 [3장 3.4](03_fpga_basics.md)의 BRAM을 추상화한 래퍼입니다. 출력 버퍼(OFM)와 라인 버퍼 bank의 기반입니다.

- **dpram**(dual-port): 쓰기 포트(A)와 읽기 포트(B)가 따로 있어 동시에 가능. OFM 버퍼(65536×32)와 라인 버퍼 bank(2048×128).
- **spram**(single-port): 한 포트로 읽기/쓰기 시분할. gbuff bias 등.

### 🔍 코드 해설 — 파라미터로 여러 크기 지원

```verilog
parameter DW=64, AW=8, DEPTH=256, N_DELAY=1;
`ifdef FPGA
    if((DEPTH==65536) && (DW==32)) begin   // OFM 버퍼
        dpram_65536x32 u_dpram_65536x32 (...);
    end else if((DEPTH==2048) && (DW==128)) begin  // 라인 버퍼
        dpram_2048x128 u_dpram_2048x128 (...);
    end
    // ...
`else
    reg [DW-1:0] ram[0:DEPTH-1];   // 시뮬: reg 배열
`endif
```

`(DEPTH, DW)` 조합에 따라 맞는 BRAM IP를 고릅니다([3장 3.4 BMG](03_fpga_basics.md)). 같은 래퍼 코드로 여러 크기 메모리를 만듭니다.

### 🔍 코드 해설 — 시뮬 메모리 0 초기화 (중요)

```verilog
`else   // 시뮬레이션 경로
    reg [DW-1:0] ram[0:DEPTH-1];
    integer dpram_init_idx;
    initial begin   // ★ uninitialized X 방지
        for (dpram_init_idx=0; dpram_init_idx<DEPTH; dpram_init_idx++)
            ram[dpram_init_idx] = {DW{1'b0}};
    end
    always @(posedge clk) if(ena && wea) ram[addra] <= dia;   // 쓰기
    // 읽기: N_DELAY=1 → 1클럭 지연
    always @(posedge clk) if(enb) rdata <= ram[addrb];
`endif
```

- `initial`로 메모리를 0으로 채웁니다. [4장 4.7](04_rtl_timing_basics.md)에서 본 "uninitialized X"가 시뮬레이터 버전마다 다르게 처리되어 검증이 비결정적이 되던 문제를 막습니다([21장](21_vivado_project.md)).
- `initial`은 시뮬 전용(합성에는 BMG IP 경로라 무관)이고, 실제 FPGA BRAM의 0 초기화와 일치합니다 → **fps·Energy·정확도에 영향 없음**, 검증 재현성만 확보.
- 읽기 `N_DELAY=1` → BRAM read latency 1클럭([3장 3.4](03_fpga_basics.md), [4장 4.4](04_rtl_timing_basics.md)). BMG의 "No Output Register" 설정과 같습니다.

---

## 15.4 네 버퍼 비교

| 버퍼 | 모양 | 포트 | 특이점 |
|------|------|------|--------|
| `ifm_line_buf` (×4 bank) | 2048×128 | dual | cyclic, 윈도우 추출, latency 2 |
| `gbuff_param` 가중치 | 4096×72 (읽기 288) | dual 비대칭 | 쓰기72/읽기288 |
| `gbuff_param` bias | 2560×32 | single | {bias16,shift16} |
| OFM dpram | 65536×32 | dual | 5방향 공유, latency 1 |

모두 `` `ifdef FPGA `` 로 합성(BMG IP)/시뮬(reg+0초기화) 두 경로를 가집니다.

---

## 15.5 이 장의 요약

- `ifm_line_buf`: 4줄을 cyclic으로 쌓고 3×3/1×1 윈도우를 36바이트씩 4벌 추출(latency 2, look-ahead로 보상).
- 3×3은 entry 경계를 offset으로 잘라 붙이고 가장자리 0 패딩, 1×1은 채널을 byte 0/9/18/27에 정렬(Phase 2 버그 수정점).
- `gbuff_param`: 가중치는 쓰기72/읽기288 비대칭(한 번에 36개 공급), bias는 {bias16,shift16}. 가중치는 필터별 streaming.
- `dpram/spram_wrapper`: 파라미터로 여러 BRAM 크기 지원, 시뮬은 reg+`initial` 0 초기화(X 방지, 검증 재현성).
- 모든 버퍼가 합성/시뮬 두 경로, read latency 1(라인버퍼는 윈도우+레지스터로 2).

다음 장에서는 합성곱이 아닌 **풀링·업샘플·REPACK** 특수 유닛을 봅니다.

---

> [← 14장 Convolution 엔진](14_rtl_convolution_engine.md) · [목차](README.md) · 다음 장: [16장 특수 연산 유닛 →](16_rtl_special_units.md)
