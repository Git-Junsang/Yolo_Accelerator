`timescale 1ns / 1ps
//----------------------------------------------------------------+
// gbuff_param.v — Global Parameter Buffer (weight + bias/shift)
//
// 강의 10차시 "Global Buffer for Parameters" 모듈.
//
//   ┌─────────── DMA Write 측 ───────────┐    ┌─── MAC Read 측 ───┐
//   │ wr_wgt_*  (72-bit / cycle)         │    │ rd_wgt_* (288-bit)│
//   │ wr_bias_* (32-bit / cycle)         │    │ rd_bias_* (32-bit)│
//   └────────────────────────────────────┘    └───────────────────┘
//
// 내부 메모리:
//   - Weight buffer : dpram_4096x72  (write 72 / read 288 비대칭)
//                     4096 × 9 byte = 36 KB
//                     L0/L2/L4 등 작은 layer 는 한 번에 적재.
//                     큰 layer (L8, L10, ...) 는 filter group 단위로 swap.
//   - Bias  buffer  : spram_2560x32 (32-bit single port)
//                     entry 당 {bias[15:0], shift[15:0]} packed.
//                     전 layer filter 수 합 ≈ 2294 < 2560 → 한 번에 적재.
//
// Read 인터페이스 (mac_kern 와 매칭):
//   - rd_wgt_data 는 한 cycle 에 288 bit = 36 byte = 36 weight (INT8) 공급
//   - rd_wgt_addr 는 288-bit entry 단위 → 1024 = 4096/4 entry 깊이
//   - rd_bias_data 는 filter 전환 시점에 한 번 read
//
// FPGA 합성 시 다음 BRAM IP 필요 (Vivado IP Catalog → Block Memory Generator):
//   - dpram_4096x72 : True Dual Port, A=72/4096 write, B=288/1024 read (비대칭)
//   - spram_2560x32 : Single Port, 32-bit × 2560
//----------------------------------------------------------------+
`include "user_define_h.v"

module gbuff_param(
    input              clk,
    input              rstn,

    // ===== DMA Write 인터페이스 =====
    // Weight write port (72-bit, depth 4096)
    input              wr_wgt_en,
    input  [11:0]      wr_wgt_addr,    // 4096 entry
    input  [71:0]      wr_wgt_data,

    // Bias/shift write port (32-bit, depth 2560)
    input              wr_bias_en,
    input  [11:0]      wr_bias_addr,   // 2560 entry → 12-bit (실제 사용 [11:0])
    input  [31:0]      wr_bias_data,

    // ===== MAC Read 인터페이스 =====
    // Weight read port (288-bit, depth 1024 = 4096/4)
    input              rd_wgt_en,
    input  [9:0]       rd_wgt_addr,
    output [287:0]     rd_wgt_data,

    // Bias/shift read port (32-bit, depth 2560)
    input              rd_bias_en,
    input  [11:0]      rd_bias_addr,
    output [31:0]      rd_bias_data
);

`ifdef FPGA
    //--------------------------------------------------------------
    // FPGA 합성 경로 — BRAM IP 인스턴스화
    //--------------------------------------------------------------
    // 비대칭 dual-port BRAM. Block Memory Generator 설정:
    //   - Memory Type: Simple Dual Port RAM
    //   - Port A (write): Width=72,  Depth=4096
    //   - Port B (read) : Width=288, Depth=1024
    //   - Common Clock, No output register (또는 1단 추가하여 timing 여유)
    dpram_4096x72 u_wgt_mem (
        .clka  (clk),
        .ena   (wr_wgt_en),
        .wea   (wr_wgt_en),
        .addra (wr_wgt_addr),
        .dina  (wr_wgt_data),
        .clkb  (clk),
        .enb   (rd_wgt_en),
        .addrb (rd_wgt_addr),
        .doutb (rd_wgt_data)
    );

    // 단일 포트 BRAM (write/read mux 외부 제어 — layer 시작 시점에만 write)
    wire        bias_cs   = wr_bias_en | rd_bias_en;
    wire        bias_we   = wr_bias_en;
    wire [11:0] bias_addr = wr_bias_en ? wr_bias_addr : rd_bias_addr;
    wire [31:0] bias_din  = wr_bias_data;

    spram_2560x32 u_bias_mem (
        .clka  (clk),
        .ena   (bias_cs),
        .wea   (bias_we),
        .addra (bias_addr),
        .dina  (bias_din),
        .douta (rd_bias_data)
    );

`else
    //--------------------------------------------------------------
    // Behavioral simulation 모델
    //--------------------------------------------------------------
    reg [71:0] wgt_mem  [0:4095];
    reg [31:0] bias_mem [0:2559];

    // ----- Write -----
    always @(posedge clk) begin
        if (wr_wgt_en)  wgt_mem [wr_wgt_addr]  <= wr_wgt_data;
        if (wr_bias_en) bias_mem[wr_bias_addr] <= wr_bias_data;
    end

    // ----- Weight read (288-bit = 4 × 72-bit consecutive) -----
    //   rd_wgt_addr 는 288-bit entry index → 실제 wgt_mem 의 base = addr × 4
    reg [287:0] rd_wgt_data_r;
    always @(posedge clk) begin
        if (!rstn) begin
            rd_wgt_data_r <= 288'd0;
        end else if (rd_wgt_en) begin
            rd_wgt_data_r <= { wgt_mem[{rd_wgt_addr, 2'd3}],
                               wgt_mem[{rd_wgt_addr, 2'd2}],
                               wgt_mem[{rd_wgt_addr, 2'd1}],
                               wgt_mem[{rd_wgt_addr, 2'd0}] };
        end
    end
    assign rd_wgt_data = rd_wgt_data_r;

    // ----- Bias read -----
    reg [31:0] rd_bias_data_r;
    always @(posedge clk) begin
        if (!rstn) begin
            rd_bias_data_r <= 32'd0;
        end else if (rd_bias_en && !wr_bias_en) begin
            rd_bias_data_r <= bias_mem[rd_bias_addr];
        end
    end
    assign rd_bias_data = rd_bias_data_r;

`endif

endmodule
