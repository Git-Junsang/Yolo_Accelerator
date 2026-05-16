`timescale 1ns/1ps
`include"user_define_h.v"
//================================================================
// spram_wrapper.v — Single-Port RAM 래퍼 모듈
//
// 역할:
//   FPGA 합성 시에는 Vivado Block Memory Generator(BMG) IP 를 인스턴스화하고,
//   시뮬레이션 시에는 behavioral reg 배열 모델을 사용한다.
//   파라미터(DW, AW, DEPTH)를 바꿔 다양한 크기의 SRAM 에 재사용.
//
// 포트:
//   clk   : 클록 (상승 에지 동기)
//   cs    : Chip Select (1=활성화, 0=비활성화)
//   we    : Write Enable (1=쓰기, 0=읽기)
//   addr  : 주소 (AW 비트)
//   wdata : 쓰기 데이터 (DW 비트)
//   rdata : 읽기 데이터 (DW 비트, N_DELAY 사이클 후 유효)
//
// 동작:
//   - 쓰기: cs=1, we=1 → 다음 클록 상승 에지에서 mem[addr] ← wdata
//   - 읽기: cs=1, we=0 → N_DELAY 사이클 후 rdata = mem[addr]
//
// FPGA 모드에서 지원하는 BRAM 크기 (파라미터 조합):
//   DW=72,  DEPTH=512    → spram_512x72   (Weight buffer용)
//   DW=32,  DEPTH=4096   → spram_4096x32  (중간 크기 버퍼)
//   DW=32,  DEPTH=65536  → spram_65536x32 (OFM/IFM 전체 버퍼)
//   DW=128, DEPTH=2048   → spram_2048x128 (Weight 128-bit 정렬 버퍼)
//   DW=32,  DEPTH=128    → spram_128x32   (Bias 버퍼)
//
// 주의:
//   - FPGA 모드에서는 Vivado IP Catalog 에서 동일 이름의 IP 사전 생성 필요
//   - N_DELAY=1: BMG "No Output Register" 설정과 동일 (1-cycle read latency)
//   - N_DELAY>1: 다단 pipeline register로 추가 지연 모사
//================================================================
module spram_wrapper (
    clk,    // clock
    addr,   // 읽기/쓰기 주소
    we,     // Write Enable (1=쓰기)
    cs,     // Chip Select (1=활성화)
    wdata,  // 쓰기 데이터
    rdata   // 읽기 데이터 (N_DELAY cycle 후 유효)
);

// ──────────────────────────────────────────────────────────────
// 파라미터 — 인스턴스화 시 override 가능
// ──────────────────────────────────────────────────────────────
parameter DW      = 64;     // 워드당 데이터 비트 폭
parameter AW      = 8;      // 주소 비트 폭 (2^AW = DEPTH)
parameter DEPTH   = 256;    // 총 워드 수
parameter N_DELAY = 1;      // 읽기 latency (cycle)

// ──────────────────────────────────────────────────────────────
// 입출력 포트 선언
// ──────────────────────────────────────────────────────────────
input                   clk;
input  [AW-1 : 0]       addr;   // 주소
input                   we;     // Write Enable
input                   cs;     // Chip Select
input  [DW-1 : 0]       wdata;  // 쓰기 데이터
output [DW-1 : 0]       rdata;  // 읽기 데이터

reg [DW-1 : 0] rdata_o;    // 내부 읽기 결과 레지스터

// ──────────────────────────────────────────────────────────────
// FPGA 합성 경로: BMG IP 인스턴스화
//   각 (DEPTH, DW) 조합에 대해 대응하는 IP를 generate 로 선택.
//   Vivado 에서 동일 이름의 Single Port Block RAM IP 를 먼저 생성해야 함.
// ──────────────────────────────────────────────────────────────
`ifdef FPGA
    generate
        if((DEPTH == 512) && (DW == 72)) begin: gen_spram_512x72
            // Weight buffer (72-bit = INT8 × 9 = 3×3 필터 1개 분량)
            spram_512x72 u_spram_512x72(
                .clka(clk), .ena(cs), .wea(we),
                .addra(addr), .dina(wdata), .douta(rdata)
            );
        end

        else if((DEPTH == 4096) && (DW == 32)) begin: gen_spram_4096x32
            // 중간 크기 버퍼 (IFM/OFM 임시 저장 등)
            spram_4096x32 u_spram_4096x32(
                .clka(clk), .ena(cs), .wea(we),
                .addra(addr), .dina(wdata), .douta(rdata)
            );
        end

        else if((DEPTH == 65536) && (DW == 32)) begin: gen_spram_65536x32
            // 대형 IFM/OFM 버퍼 (최대 256KB)
            spram_65536x32 u_spram_65536x32(
                .clka(clk), .ena(cs), .wea(we),
                .addra(addr), .dina(wdata), .douta(rdata)
            );
        end

        // -------------------------------------------------------------
        // AIX2026 추가 케이스 (yolo_engine Tier 1 통합용)
        //   - spram_2048x128 : Weight buffer (L0+L1+L2 가중치, 128-bit aligned)
        //   - spram_128x32   : Bias buffer (INT16 sign-extended 32-bit)
        // FPGA 합성 전 Vivado IP Catalog → Block Memory Generator 로
        // 동일 이름의 IP 생성 필요 (Single-port RAM, Width/Depth = 위 조합)
        // -------------------------------------------------------------
        else if((DEPTH == 2048) && (DW == 128)) begin: gen_spram_2048x128
            // Weight 128-bit 정렬 버퍼 (AXI burst 16-byte 정렬 대응)
            spram_2048x128 u_spram_2048x128(
                .clka(clk), .ena(cs), .wea(we),
                .addra(addr), .dina(wdata), .douta(rdata)
            );
        end

        else if((DEPTH == 128) && (DW == 32)) begin: gen_spram_128x32
            // Bias 버퍼 (레이어당 최대 128개 bias, 각 32bit)
            spram_128x32 u_spram_128x32(
                .clka(clk), .ena(cs), .wea(we),
                .addra(addr), .dina(wdata), .douta(rdata)
            );
        end
    endgenerate

`else
    // ──────────────────────────────────────────────────────────────
    // 시뮬레이션 경로: behavioral reg 배열 모델
    // ──────────────────────────────────────────────────────────────
    reg [DW-1 : 0] mem[0:DEPTH-1];  // 메모리 셀 (reg 배열)

    // 쓰기: cs & we 가 모두 1일 때 상승 에지에서 데이터 저장
    always @(posedge clk) begin
        if(cs && we) mem[addr] <= wdata;
    end

    // 읽기: N_DELAY 에 따라 1-cycle 또는 다단 지연
    generate
        if(N_DELAY == 1) begin: gen_delay_1
            // 1-cycle read latency (BMG "No Output Register" 동작)
            always @(posedge clk)
                if (cs && !(|we)) rdata_o <= mem[addr];  // we=0 일 때만 읽기

            assign rdata = rdata_o;
        end
        else begin: gen_delay_n
            // N_DELAY 사이클 pipeline 지연 (BMG Output Register 추가 시 사용)
            reg [N_DELAY*DW-1:0] rdata_r;

            // 1차 읽기
            always @(posedge clk)
                if (cs && !(|we)) rdata_r[0*DW+:DW] <= mem[addr];

            // 추가 지연 단계
            always @(posedge clk) begin: delay
                integer i;
                for(i = 0; i < N_DELAY-1; i = i+1)
                    if(cs && !(|we))
                        rdata_r[(i+1)*DW+:DW] <= rdata_r[i*DW+:DW];
            end

            assign rdata = rdata_r[(N_DELAY-1)*DW+:DW];
        end
    endgenerate

`endif

endmodule
