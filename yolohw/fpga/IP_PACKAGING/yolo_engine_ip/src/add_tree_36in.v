`timescale 1ns / 1ps
//----------------------------------------------------------------+
// add_tree_36in.v — 36-input signed adder tree (4-stage pipeline)
//
// Topology (강의 9차시):
//   L0: 36 inputs (16-bit signed, from mul/mul_dual)
//   L1: 12 × 3-input add → 18-bit
//   L2: 4 × 3-input add  → 20-bit
//   L3: 2 × 2-input add  → 21-bit
//   L4: 1 × 2-input add  → 22-bit
//
// 최대값: 36 × (127×255) = 1,165,860 → 22-bit signed.
// Latency: 4 cycle (mac_stack 의 adder tree latency 와 일치).
//----------------------------------------------------------------+
module add_tree_36in(
    input              clk,
    input              rstn,
    input              vld_i,
    input  [36*16-1:0] muls,    // 36 개 곱셈 결과 (16-bit signed) concat
    output [21:0]      acc_o,   // 22-bit signed sum
    output             vld_o
);

    //--------------------------------------------------------------
    // Unpack 36 inputs
    //--------------------------------------------------------------
    wire signed [15:0] m [0:35];
    genvar gi;
    generate
        for (gi=0; gi<36; gi=gi+1) begin: g_unpack
            assign m[gi] = muls[gi*16 +: 16];
        end
    endgenerate

    //--------------------------------------------------------------
    // Level 1: 36 → 12 (3-input adds, 18-bit)
    //--------------------------------------------------------------
    reg signed [17:0] l1_00, l1_01, l1_02, l1_03;
    reg signed [17:0] l1_04, l1_05, l1_06, l1_07;
    reg signed [17:0] l1_08, l1_09, l1_10, l1_11;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            l1_00 <= 18'sd0; l1_01 <= 18'sd0; l1_02 <= 18'sd0; l1_03 <= 18'sd0;
            l1_04 <= 18'sd0; l1_05 <= 18'sd0; l1_06 <= 18'sd0; l1_07 <= 18'sd0;
            l1_08 <= 18'sd0; l1_09 <= 18'sd0; l1_10 <= 18'sd0; l1_11 <= 18'sd0;
        end else begin
            l1_00 <= $signed(m[ 0]) + $signed(m[ 1]) + $signed(m[ 2]);
            l1_01 <= $signed(m[ 3]) + $signed(m[ 4]) + $signed(m[ 5]);
            l1_02 <= $signed(m[ 6]) + $signed(m[ 7]) + $signed(m[ 8]);
            l1_03 <= $signed(m[ 9]) + $signed(m[10]) + $signed(m[11]);
            l1_04 <= $signed(m[12]) + $signed(m[13]) + $signed(m[14]);
            l1_05 <= $signed(m[15]) + $signed(m[16]) + $signed(m[17]);
            l1_06 <= $signed(m[18]) + $signed(m[19]) + $signed(m[20]);
            l1_07 <= $signed(m[21]) + $signed(m[22]) + $signed(m[23]);
            l1_08 <= $signed(m[24]) + $signed(m[25]) + $signed(m[26]);
            l1_09 <= $signed(m[27]) + $signed(m[28]) + $signed(m[29]);
            l1_10 <= $signed(m[30]) + $signed(m[31]) + $signed(m[32]);
            l1_11 <= $signed(m[33]) + $signed(m[34]) + $signed(m[35]);
        end
    end

    //--------------------------------------------------------------
    // Level 2: 12 → 4 (3-input adds, 20-bit)
    //--------------------------------------------------------------
    reg signed [19:0] l2_00, l2_01, l2_02, l2_03;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            l2_00 <= 20'sd0; l2_01 <= 20'sd0; l2_02 <= 20'sd0; l2_03 <= 20'sd0;
        end else begin
            l2_00 <= $signed(l1_00) + $signed(l1_01) + $signed(l1_02);
            l2_01 <= $signed(l1_03) + $signed(l1_04) + $signed(l1_05);
            l2_02 <= $signed(l1_06) + $signed(l1_07) + $signed(l1_08);
            l2_03 <= $signed(l1_09) + $signed(l1_10) + $signed(l1_11);
        end
    end

    //--------------------------------------------------------------
    // Level 3: 4 → 2 (2-input adds, 21-bit)
    //--------------------------------------------------------------
    reg signed [20:0] l3_00, l3_01;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            l3_00 <= 21'sd0;
            l3_01 <= 21'sd0;
        end else begin
            l3_00 <= $signed(l2_00) + $signed(l2_01);
            l3_01 <= $signed(l2_02) + $signed(l2_03);
        end
    end

    //--------------------------------------------------------------
    // Level 4: 2 → 1 (final sum, 22-bit)
    //--------------------------------------------------------------
    reg signed [21:0] l4;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) l4 <= 22'sd0;
        else       l4 <= $signed(l3_00) + $signed(l3_01);
    end

    //--------------------------------------------------------------
    // Valid pipeline (4 stages, matches data path)
    //--------------------------------------------------------------
    reg vld_d1, vld_d2, vld_d3, vld_d4;
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            vld_d1 <= 1'b0;
            vld_d2 <= 1'b0;
            vld_d3 <= 1'b0;
            vld_d4 <= 1'b0;
        end else begin
            vld_d1 <= vld_i;
            vld_d2 <= vld_d1;
            vld_d3 <= vld_d2;
            vld_d4 <= vld_d3;
        end
    end

    assign acc_o = l4;
    assign vld_o = vld_d4;

endmodule
