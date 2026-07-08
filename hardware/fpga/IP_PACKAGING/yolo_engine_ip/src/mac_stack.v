`timescale 1ns / 1ps
//----------------------------------------------------------------+
// mac_stack.v — 144-MAC array (4 spatial outputs, shared weights)
//
// 강의 9차시 7-mac_stack 표제 모듈.
//   - 36 weight 를 4 개의 IFM 세트와 각각 곱하여
//     4 개의 출력 누적합 (acc_00, acc_01, acc_10, acc_11) 동시 생성.
//   - 동일 wgt 가 4 세트에 broadcast 되므로 합성기는 weight reuse 를
//     packed-DSP 또는 shared register 로 최적화 가능.
//
// I/O 사이즈:
//   wgt   : 36 × 8 = 288 bit (3×3 필터 4 채널 분 또는 1×1 필터 36 채널 분)
//   ifm_* : 36 × 8 = 288 bit (해당 spatial 좌표의 36 입력 픽셀)
//   acc_* : 22-bit signed (add_tree_36in 출력 폭과 일치)
//
// Latency: 4 (mul) + 4 (add_tree_36in) = 8 cycle.
// vld_o 는 vld_i 입력 후 8 cycle 뒤 high.
//----------------------------------------------------------------+
module mac_stack(
    input              clk,
    input              rstn,
    input              vld_i,

    input  [36*8-1:0]  wgt,     // 공유 가중치 36 × 8 bit
    input  [36*8-1:0]  ifm_00,  // 입력 세트 0 (출력 위치 (0,0) 용 36 픽셀)
    input  [36*8-1:0]  ifm_01,  // 입력 세트 1 (출력 위치 (0,1))
    input  [36*8-1:0]  ifm_10,  // 입력 세트 2 (출력 위치 (1,0))
    input  [36*8-1:0]  ifm_11,  // 입력 세트 3 (출력 위치 (1,1))

    output [21:0]      acc_00,
    output [21:0]      acc_01,
    output [21:0]      acc_10,
    output [21:0]      acc_11,
    output             vld_o
);

    //--------------------------------------------------------------
    // Multiplier arrays — 4 sets × 36 mul = 144 곱셈
    //   가중치 wgt 는 4 세트에 broadcast.
    //--------------------------------------------------------------
    wire [36*16-1:0] muls_00;
    wire [36*16-1:0] muls_01;
    wire [36*16-1:0] muls_10;
    wire [36*16-1:0] muls_11;

    genvar i;
    generate
        for (i=0; i<36; i=i+1) begin: g_mul_arr
            mul u_mul_00 (
                .clk (clk),
                .w   (wgt   [i*8 +: 8]),
                .x   (ifm_00[i*8 +: 8]),
                .y   (muls_00[i*16 +: 16])
            );
            mul u_mul_01 (
                .clk (clk),
                .w   (wgt   [i*8 +: 8]),
                .x   (ifm_01[i*8 +: 8]),
                .y   (muls_01[i*16 +: 16])
            );
            mul u_mul_10 (
                .clk (clk),
                .w   (wgt   [i*8 +: 8]),
                .x   (ifm_10[i*8 +: 8]),
                .y   (muls_10[i*16 +: 16])
            );
            mul u_mul_11 (
                .clk (clk),
                .w   (wgt   [i*8 +: 8]),
                .x   (ifm_11[i*8 +: 8]),
                .y   (muls_11[i*16 +: 16])
            );
        end
    endgenerate

    //--------------------------------------------------------------
    // vld pipeline through multiplier stages (4 cycle)
    //   mul 은 vld 신호가 없으므로 mac_stack 내부에서 동기화.
    //--------------------------------------------------------------
    reg vld_m1, vld_m2, vld_m3, vld_m4;
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            vld_m1 <= 1'b0;
            vld_m2 <= 1'b0;
            vld_m3 <= 1'b0;
            vld_m4 <= 1'b0;
        end else begin
            vld_m1 <= vld_i;
            vld_m2 <= vld_m1;
            vld_m3 <= vld_m2;
            vld_m4 <= vld_m3;
        end
    end

    //--------------------------------------------------------------
    // 4 × add_tree_36in — 한 사이클에 4 출력 픽셀의 부분합 생성
    //--------------------------------------------------------------
    wire vld_at_00, vld_at_01, vld_at_10, vld_at_11;

    add_tree_36in u_at_00 (
        .clk   (clk),  .rstn (rstn),
        .vld_i (vld_m4),
        .muls  (muls_00),
        .acc_o (acc_00),
        .vld_o (vld_at_00)
    );
    add_tree_36in u_at_01 (
        .clk   (clk),  .rstn (rstn),
        .vld_i (vld_m4),
        .muls  (muls_01),
        .acc_o (acc_01),
        .vld_o (vld_at_01)
    );
    add_tree_36in u_at_10 (
        .clk   (clk),  .rstn (rstn),
        .vld_i (vld_m4),
        .muls  (muls_10),
        .acc_o (acc_10),
        .vld_o (vld_at_10)
    );
    add_tree_36in u_at_11 (
        .clk   (clk),  .rstn (rstn),
        .vld_i (vld_m4),
        .muls  (muls_11),
        .acc_o (acc_11),
        .vld_o (vld_at_11)
    );

    // 4 add_tree 가 동일 latency 이므로 어느 vld 를 써도 동일.
    assign vld_o = vld_at_00;

endmodule
