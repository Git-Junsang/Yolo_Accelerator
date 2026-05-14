`timescale 1ns / 1ns
//----------------------------------------------------------------+
// upsample_unit_tb.v — 2× nearest-neighbor upsample (L18) 검증
//
// 검증 시나리오:
//   1. behavioral OFM dpram + upsample_unit 결선
//   2. 작은 크기 (Co=2, in_H_b=W_b=2 → in 4×4 spatial, out 8×8) 입력 패턴
//   3. i_start → o_done 대기
//   4. SW reference 로 4 byte → 4 packed word 확장 후 비교
//
// SW reference (per input block (R, C)):
//   input pixel pix_xx → output 2×2 block 의 4 byte (모두 동일 값)
//   pix_00 (입력 byte0) → output block at (2R,   2C  ) = {pix_00, pix_00, pix_00, pix_00}
//   pix_01 (입력 byte1) → output block at (2R,   2C+1) = {pix_01, pix_01, pix_01, pix_01}
//   pix_10 (입력 byte2) → output block at (2R+1, 2C  ) = {pix_10, pix_10, pix_10, pix_10}
//   pix_11 (입력 byte3) → output block at (2R+1, 2C+1) = {pix_11, pix_11, pix_11, pix_11}
//
//   output block 인덱싱 (output W_b = 2 × in_W_b):
//     out_addr = f × (out_H_b × out_W_b) + out_R × out_W_b + out_C
//----------------------------------------------------------------+
`include "user_define_h.v"

module upsample_unit_tb;

`ifdef FPGA
    initial begin
        $display("[FATAL] FPGA macro 활성. user_define_h.v 의 `define FPGA 주석 처리 필요.");
        $finish;
    end
`else

    parameter CLK_PERIOD = 10;
    reg clk, rstn;
    initial begin clk = 1'b0; forever #(CLK_PERIOD/2) clk = ~clk; end

    //--------------------------------------------------------------
    // Test 크기 — 작게 (in 4×4 = HB=WB=2, out 8×8)
    //--------------------------------------------------------------
    localparam integer CO    = 2;
    localparam integer IN_HB = 2;
    localparam integer IN_WB = 2;
    localparam integer OUT_HB = 2*IN_HB;
    localparam integer OUT_WB = 2*IN_WB;
    localparam integer N_IN  = CO * IN_HB * IN_WB;    // 8
    localparam integer N_OUT = CO * OUT_HB * OUT_WB;  // 32

    //--------------------------------------------------------------
    // DUT signals
    //--------------------------------------------------------------
    reg          dut_start;
    wire         dut_done;
    wire         dut_rd_en;
    wire [15:0]  dut_rd_addr;
    wire [31:0]  dut_rd_data;
    wire         dut_wr_en;
    wire [15:0]  dut_wr_addr;
    wire [31:0]  dut_wr_data;

    wire [15:0]  out_base_w = CO * IN_HB * IN_WB;     // 8

    dpram_wrapper #(.DW(32), .AW(16), .DEPTH(65536), .N_DELAY(1)) u_ofm (
        .clk   (clk),
        .ena   (dut_wr_en),
        .addra (dut_wr_addr),
        .wea   (dut_wr_en),
        .dia   (dut_wr_data),
        .enb   (dut_rd_en),
        .addrb (dut_rd_addr),
        .dob   (dut_rd_data)
    );

    upsample_unit u_dut (
        .clk(clk), .rstn(rstn),
        .i_start    (dut_start),
        .o_done     (dut_done),
        .i_co_total (CO[11:0]),
        .i_h_blocks (IN_HB[11:0]),
        .i_w_blocks (IN_WB[11:0]),
        .i_in_base  (16'd0),
        .i_out_base (out_base_w),
        .o_rd_en(dut_rd_en), .o_rd_addr(dut_rd_addr), .i_rd_data(dut_rd_data),
        .o_wr_en(dut_wr_en), .o_wr_addr(dut_wr_addr), .o_wr_data(dut_wr_data)
    );

    //--------------------------------------------------------------
    // 패턴 생성: 각 input block 의 4 byte = (f, R, C, sub) 함수
    //--------------------------------------------------------------
    function [31:0] gen_block;
        input integer f;
        input integer rr;
        input integer cc;
        reg [7:0] bb0, bb1, bb2, bb3;
        begin
            bb0 = ((f*16 + rr*4 + cc)*4 + 0) & 32'hFF;
            bb1 = ((f*16 + rr*4 + cc)*4 + 1) & 32'hFF;
            bb2 = ((f*16 + rr*4 + cc)*4 + 2) & 32'hFF;
            bb3 = ((f*16 + rr*4 + cc)*4 + 3) & 32'hFF;
            gen_block = {bb3, bb2, bb1, bb0};
        end
    endfunction

    //--------------------------------------------------------------
    // SW reference — 입력 block (R, C) 의 4 byte → 4 output block
    //--------------------------------------------------------------
    function [31:0] expected_out;
        input integer f;
        input integer out_R;
        input integer out_C;
        reg  [31:0] in_blk;
        reg  [7:0]  pixval;
        integer in_R, in_C, sub_row, sub_col;
        begin
            in_R    = out_R >> 1;
            in_C    = out_C >> 1;
            sub_row = out_R & 1;
            sub_col = out_C & 1;
            in_blk  = gen_block(f, in_R, in_C);
            // sub_row=0, sub_col=0 → pix_00 (byte 0)
            // sub_row=0, sub_col=1 → pix_01 (byte 1)
            // sub_row=1, sub_col=0 → pix_10 (byte 2)
            // sub_row=1, sub_col=1 → pix_11 (byte 3)
            case ({sub_row[0], sub_col[0]})
                2'b00: pixval = in_blk[ 7: 0];
                2'b01: pixval = in_blk[15: 8];
                2'b10: pixval = in_blk[23:16];
                2'b11: pixval = in_blk[31:24];
            endcase
            expected_out = {pixval, pixval, pixval, pixval};
        end
    endfunction

    //--------------------------------------------------------------
    // Stimulus + verify
    //--------------------------------------------------------------
    integer f, rr, cc, idx, mismatch;
    reg [31:0] got, exp;

    initial begin
        rstn      = 1'b0;
        dut_start = 1'b0;
        mismatch  = 0;

        // 입력 패턴 적재
        for (idx = 0; idx < 65536; idx = idx + 1) u_ofm.ram[idx] = 32'd0;
        for (f = 0; f < CO; f = f + 1) begin
            for (rr = 0; rr < IN_HB; rr = rr + 1) begin
                for (cc = 0; cc < IN_WB; cc = cc + 1) begin
                    idx = f*IN_HB*IN_WB + rr*IN_WB + cc;
                    u_ofm.ram[idx] = gen_block(f, rr, cc);
                end
            end
        end
        $display("[upsample_unit_tb] Input pattern written (%0d blocks)", N_IN);

        #(8*CLK_PERIOD) rstn = 1'b1;
        #(4*CLK_PERIOD);

        @(posedge clk);
        dut_start <= 1'b1;
        @(posedge clk);
        dut_start <= 1'b0;
        $display("[upsample_unit_tb] start @ t=%0t", $time);

        wait (dut_done == 1'b1);
        @(posedge clk);
        $display("[upsample_unit_tb] done @ t=%0t", $time);

        // 비교
        for (f = 0; f < CO; f = f + 1) begin
            for (rr = 0; rr < OUT_HB; rr = rr + 1) begin
                for (cc = 0; cc < OUT_WB; cc = cc + 1) begin
                    idx = out_base_w + f*OUT_HB*OUT_WB + rr*OUT_WB + cc;
                    got = u_ofm.ram[idx];
                    exp = expected_out(f, rr, cc);
                    if (got !== exp) begin
                        if (mismatch < 8) begin
                            $display("[MISMATCH] f=%0d outR=%0d outC=%0d  got=0x%08h exp=0x%08h",
                                     f, rr, cc, got, exp);
                        end
                        mismatch = mismatch + 1;
                    end
                end
            end
        end

        if (mismatch == 0)
            $display("[upsample_unit_tb] *** PASSED (%0d output blocks) ***", N_OUT);
        else
            $display("[upsample_unit_tb] *** FAILED (%0d mismatches / %0d) ***",
                     mismatch, N_OUT);

        #(20*CLK_PERIOD) $finish;
    end

    initial begin
        #(10_000_000 * CLK_PERIOD);
        $display("[upsample_unit_tb] TIMEOUT");
        $finish;
    end
`endif

endmodule
