`timescale 1ns/1ns
`include"user_define_h.v"
//================================================================
// dpram_wrapper.v — Simple Dual-Port RAM 래퍼 모듈
//
// 역할:
//   FPGA 합성 시에는 Vivado Block Memory Generator(BMG) IP를 인스턴스화하고,
//   시뮬레이션 시에는 behavioral reg 배열 모델을 사용한다.
//   spram_wrapper와 달리 쓰기 포트(A)와 읽기 포트(B)가 분리되어 있어
//   같은 클록에서 서로 다른 주소에 동시 읽기/쓰기 가능하다.
//
// 포트 구성 (Simple Dual-Port):
//   포트 A (쓰기 전용):  clk, ena, wea, addra, dia
//   포트 B (읽기 전용):  clk, enb, addrb → dob (N_DELAY 사이클 후 유효)
//
// 포트 상세:
//   clk   : 공용 클록 (상승 에지 동기, 포트 A/B 동일)
//   ena   : 포트 A Chip Select (1=활성화)
//   wea   : Write Enable (1=쓰기 수행)
//   addra : 쓰기 주소 (AW 비트)
//   dia   : 쓰기 데이터 (DW 비트)
//   enb   : 포트 B Chip Select (1=활성화)
//   addrb : 읽기 주소 (AW 비트)
//   dob   : 읽기 데이터 (DW 비트, N_DELAY 사이클 후 유효)
//
// 동작:
//   - 쓰기: ena=1, wea=1 → 다음 클록 상승 에지에서 ram[addra] ← dia
//   - 읽기: enb=1       → N_DELAY 사이클 후 dob = ram[addrb]
//   - 포트 A/B가 같은 주소를 동시에 접근하면 BMG IP 설정에 따라
//     "read-first" 또는 "write-first" 동작 (행동 모델은 read-first)
//
// FPGA 모드에서 지원하는 BRAM 크기 (파라미터 조합):
//   DW=72,  DEPTH=512    → dpram_512x72   (Weight buffer 용)
//   DW=32,  DEPTH=4096   → dpram_4096x32  (중간 크기 버퍼)
//   DW=32,  DEPTH=65536  → dpram_65536x32 (대형 IFM/OFM 버퍼)
//   DW=128, DEPTH=16384  → dpram_16384x128 (구 IFM 핑퐁 버퍼, 미사용)
//   DW=128, DEPTH=2048   → dpram_2048x128 (IFM line buffer, 4행 슬라이딩 윈도우용)
//   DW=32,  DEPTH=8192   → dpram_8192x32  (OFM 4-pixel packed 버퍼)
//
// 주의:
//   - FPGA 모드에서는 Vivado IP Catalog 에서 동일 이름의 IP 사전 생성 필요
//   - N_DELAY=1: BMG "No Output Register" 설정과 동일
//   - spram_wrapper 와 달리 읽기 시 we 체크 불필요 (포트 B는 read-only)
//================================================================
module dpram_wrapper (
    clk,    // 공용 클록 (포트 A/B 동일)
    ena,    // 포트 A Chip Select (쓰기 포트 활성화)
    addra,  // 포트 A 쓰기 주소
    wea,    // Write Enable (1=쓰기)
    enb,    // 포트 B Chip Select (읽기 포트 활성화)
    addrb,  // 포트 B 읽기 주소
    dia,    // 쓰기 데이터
    dob     // 읽기 데이터 (N_DELAY cycle 후 유효)
);

// ──────────────────────────────────────────────────────────────
// 파라미터 — 인스턴스화 시 override 가능
// ──────────────────────────────────────────────────────────────
parameter DW      = 64;   // 워드당 데이터 비트 폭
parameter AW      = 8;    // 주소 비트 폭 (2^AW = DEPTH)
parameter DEPTH   = 256;  // 총 워드 수
parameter N_DELAY = 1;    // 읽기 latency (cycle)

// ──────────────────────────────────────────────────────────────
// 입출력 포트 선언
// ──────────────────────────────────────────────────────────────
input                  clk;
// 포트 A: 쓰기 포트
input  [AW-1 : 0]     addra;  // 쓰기 주소
input                  wea;    // Write Enable
input                  ena;    // 포트 A Chip Select
input  [DW-1 : 0]     dia;    // 쓰기 데이터
// 포트 B: 읽기 포트
input  [AW-1 : 0]     addrb;  // 읽기 주소
input                  enb;    // 포트 B Chip Select
output [DW-1 : 0]     dob;    // 읽기 데이터

reg [DW-1 : 0] rdata;  // 내부 읽기 결과 레지스터

// ──────────────────────────────────────────────────────────────
// FPGA 합성 경로: BMG IP 인스턴스화
//   각 (DEPTH, DW) 조합에 대해 대응하는 Simple Dual-Port BRAM IP를 generate로 선택.
//   Vivado에서 동일 이름의 Simple Dual-Port Block RAM IP를 먼저 생성해야 함.
//   (상세 설정: gen_bram_ips.tcl 참조)
// ──────────────────────────────────────────────────────────────
`ifdef FPGA
    generate
        if((DEPTH == 512) && (DW == 72)) begin: gen_dpram_512x72
            // Weight buffer (72-bit = INT8 × 9 = 3×3 필터 1행 분량)
            dpram_512x72 u_dpram_512x72 (
                // 포트 A: 쓰기
                .clka  (clk),
                .ena   (ena),
                .wea   (wea),
                .addra (addra),
                .dina  (dia),
                // 포트 B: 읽기
                .clkb  (clk),
                .enb   (enb),
                .addrb (addrb),
                .doutb (dob)
            );
        end

        else if((DEPTH == 4096) && (DW == 32)) begin: gen_dpram_4096x32
            // 중간 크기 버퍼 (IFM/OFM 임시 저장 등)
            dpram_4096x32 u_dpram_4096x32 (
                // 포트 A: 쓰기
                .clka  (clk),
                .ena   (ena),
                .wea   (wea),
                .addra (addra),
                .dina  (dia),
                // 포트 B: 읽기
                .clkb  (clk),
                .enb   (enb),
                .addrb (addrb),
                .doutb (dob)
            );
        end

        else if((DEPTH == 65536) && (DW == 32)) begin: gen_dpram_65536x32
            // 대형 IFM/OFM 버퍼 (최대 256KB)
            dpram_65536x32 u_dpram_65536x32 (
                // 포트 A: 쓰기
                .clka  (clk),
                .ena   (ena),
                .wea   (wea),
                .addra (addra),
                .dina  (dia),
                // 포트 B: 읽기
                .clkb  (clk),
                .enb   (enb),
                .addrb (addrb),
                .doutb (dob)
            );
        end

        // -------------------------------------------------------------
        // 구 IFM 핑퐁 버퍼 케이스 (Tier 1 legacy, 현재 미사용)
        //   144-MAC 경로에서는 ifm_line_buf + OFM dpram 방식을 사용하므로
        //   이 IP는 instantiate 되지 않지만 호환성을 위해 유지.
        // -------------------------------------------------------------
        else if((DEPTH == 16384) && (DW == 128)) begin: gen_dpram_16384x128
            dpram_16384x128 u_dpram_16384x128 (
                .clka  (clk),
                .ena   (ena),
                .wea   (wea),
                .addra (addra),
                .dina  (dia),
                .clkb  (clk),
                .enb   (enb),
                .addrb (addrb),
                .doutb (dob)
            );
        end

        // -------------------------------------------------------------
        // ifm_line_buf 내부 슬라이딩 윈도우 버퍼 케이스
        //   dpram_2048x128: 4-col × 4-ch 픽셀 packed (128-bit/entry)
        //                   ifm_line_buf 에서 4개 인스턴스 사용 (4행 슬라이딩)
        //   dpram_8192x32:  OFM 버퍼 (4-pixel packed = 32bit/entry)
        //                   한 filter의 모든 spatial 결과 보관
        // -------------------------------------------------------------
        else if((DEPTH == 2048) && (DW == 128)) begin: gen_dpram_2048x128
            // IFM line buffer: 4행 슬라이딩 윈도우의 한 행 저장
            dpram_2048x128 u_dpram_2048x128 (
                .clka  (clk),
                .ena   (ena),
                .wea   (wea),
                .addra (addra),
                .dina  (dia),
                .clkb  (clk),
                .enb   (enb),
                .addrb (addrb),
                .doutb (dob)
            );
        end

        else if((DEPTH == 8192) && (DW == 32)) begin: gen_dpram_8192x32
            // OFM 버퍼: 4-pixel packed 결과 저장
            dpram_8192x32 u_dpram_8192x32 (
                .clka  (clk),
                .ena   (ena),
                .wea   (wea),
                .addra (addra),
                .dina  (dia),
                .clkb  (clk),
                .enb   (enb),
                .addrb (addrb),
                .doutb (dob)
            );
        end
    endgenerate

`else
    // ──────────────────────────────────────────────────────────────
    // 시뮬레이션 경로: behavioral reg 배열 모델
    //   - 포트 A: ena=1, wea=1 → 쓰기 (상승 에지)
    //   - 포트 B: enb=1       → N_DELAY 사이클 후 읽기
    //   - 동일 주소 동시 접근: 이 모델에서는 read-first 동작
    //     (먼저 읽기 수행 후, 같은 사이클에 쓰기 적용)
    // ──────────────────────────────────────────────────────────────
    reg [DW-1 : 0] ram[0:DEPTH-1];  // 메모리 셀 (reg 배열)

    // sim 재현성: uninitialized RAM(X) 으로 인한 시뮬레이터/버전 간 결과 차이 방지.
    //   X 상태가 chain 검증에서 ±1 LSB 비결정성을 유발하므로 0 으로 초기화.
    //   (FPGA 합성 경로는 위 BMG IP 분기라 무관)
    integer dpram_init_idx;
    initial begin
        for (dpram_init_idx = 0; dpram_init_idx < DEPTH; dpram_init_idx = dpram_init_idx + 1)
            ram[dpram_init_idx] = {DW{1'b0}};
    end

    // 쓰기: ena=1, wea=1 일 때 상승 에지에서 데이터 저장
    always @(posedge clk) begin
        if(ena) begin
            if(wea) ram[addra] <= dia;
        end
    end

    // 읽기: N_DELAY에 따라 1-cycle 또는 다단 지연
    generate
        if(N_DELAY == 1) begin: delay_1
            // 1-cycle read latency (BMG "No Output Register" 동작)
            reg [DW-1:0] rdata;  // 1-cycle 지연 레지스터
            initial rdata = {DW{1'b0}};   // sim 재현성: read 레지스터 X 제거

            always @(posedge clk) begin: read
                if(enb) rdata <= ram[addrb];
            end
            assign dob = rdata;
        end
        else begin: delay_n
            // N_DELAY 사이클 pipeline 지연
            reg [N_DELAY*DW-1:0] rdata_r;
            initial rdata_r = {(N_DELAY*DW){1'b0}};   // sim 재현성: read 레지스터 X 제거

            // 1차 읽기 (포트 B)
            always @(posedge clk) begin: read
                if(enb) rdata_r[0+:DW] <= ram[addrb];
            end

            // 추가 지연 단계 (N_DELAY-1 회 shift)
            always @(posedge clk) begin: delay
                integer i;
                for(i = 0; i < N_DELAY-1; i = i+1)
                    if(enb)
                        rdata_r[(i+1)*DW+:DW] <= rdata_r[i*DW+:DW];
            end

            assign dob = rdata_r[(N_DELAY-1)*DW+:DW];
        end
    endgenerate

`endif

endmodule
