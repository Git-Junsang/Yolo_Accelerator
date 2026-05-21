`timescale 1ns / 1ns
//----------------------------------------------------------------+
// upsample_tb.v — upsample_unit (2× nearest neighbor, L18 전용) Phase 3 검증
//
// 검증 목표:
//   - upsample_unit 의 산술 (input pixel → 2×2 output block 복제) 및 FSM
//   - yolo_engine 의 dpram_wrapper (DEPTH=65536, AW=16, DW=32) 인터페이스 일치
//   - L18 실 사이즈 (Co=128, in H_b=W_b=4 → in 2048 + out 8192 word)
//   - in_base=0, out_base=Co × in_H_b × in_W_b 분리 영역 동작
//
// Packed format (입력/출력 동일):
//   32-bit word = 한 2×2 OFM block (filter f, 좌표 (2R, 2C)..(2R+1, 2C+1))
//
// SW reference (per input block (f, R, C)):
//   input pixel pix_xx → output 2×2 block 의 4 byte (모두 동일 값)
//     pix_00 → output block at out (f, 2R,   2C  ) = {pix_00 × 4}
//     pix_01 → output block at out (f, 2R,   2C+1) = {pix_01 × 4}
//     pix_10 → output block at out (f, 2R+1, 2C  ) = {pix_10 × 4}
//     pix_11 → output block at out (f, 2R+1, 2C+1) = {pix_11 × 4}
//
//   output W_b = 2 × in_W_b, output H_b = 2 × in_H_b
//   out_addr  = out_base + f × (out_H_b × out_W_b) + out_R × out_W_b + out_C
//
// 시나리오:
//   A — 손계산 (Co=2, in H_b=W_b=2)
//   B — L18 실 사이즈 (Co=128, in H_b=W_b=4)
//----------------------------------------------------------------+
`include "user_define_h.v"

module upsample_tb;

`ifdef FPGA
    initial begin
        $display("[upsample_tb][FATAL] FPGA macro 활성. user_define_h.v 의 `define FPGA 주석 처리 필요.");
        $finish;
    end
`else

    parameter CLK_PERIOD = 10;
    reg clk, rstn;
    initial begin clk = 1'b0; forever #(CLK_PERIOD/2) clk = ~clk; end

    //--------------------------------------------------------------
    // DUT signals
    //--------------------------------------------------------------
    reg          dut_start;
    wire         dut_done;
    reg  [11:0]  dut_co_total;
    reg  [11:0]  dut_h_blocks;
    reg  [11:0]  dut_w_blocks;
    reg  [15:0]  dut_in_base;
    reg  [15:0]  dut_out_base;

    wire         dut_rd_en;
    wire [15:0]  dut_rd_addr;
    wire [31:0]  dut_rd_data;
    wire         dut_wr_en;
    wire [15:0]  dut_wr_addr;
    wire [31:0]  dut_wr_data;

    //--------------------------------------------------------------
    // OFM dpram — yolo_engine u_ofm 과 동일 파라미터
    //--------------------------------------------------------------
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
        .i_co_total (dut_co_total),
        .i_h_blocks (dut_h_blocks),
        .i_w_blocks (dut_w_blocks),
        .i_in_base  (dut_in_base),
        .i_out_base (dut_out_base),
        .o_rd_en  (dut_rd_en),  .o_rd_addr(dut_rd_addr), .i_rd_data(dut_rd_data),
        .o_wr_en  (dut_wr_en),  .o_wr_addr(dut_wr_addr), .o_wr_data(dut_wr_data)
    );

    //--------------------------------------------------------------
    // Pattern: input block(f, R, C) at addr (f * H_b*W_b + R*W_b + C)
    //   pat[blk] = { (blk*4+3)&0xFF, (blk*4+2)&0xFF, (blk*4+1)&0xFF, (blk*4)&0xFF }
    //--------------------------------------------------------------
    function [31:0] gen_block;
        input integer blk;
        reg [7:0] b0, b1, b2, b3;
        begin
            b0 = (blk*4 + 0) & 32'hFF;
            b1 = (blk*4 + 1) & 32'hFF;
            b2 = (blk*4 + 2) & 32'hFF;
            b3 = (blk*4 + 3) & 32'hFF;
            gen_block = {b3, b2, b1, b0};
        end
    endfunction

    integer i, mismatch_a, mismatch_b;

    task automatic run_up;
        begin
            @(posedge clk);
            dut_start <= 1'b1;
            @(posedge clk);
            dut_start <= 1'b0;
            wait (dut_done == 1'b1);
            @(posedge clk);
        end
    endtask

    //--------------------------------------------------------------
    // Scenario A — Co=2, in H_b=W_b=2 (손계산)
    //--------------------------------------------------------------
    task automatic check_a;
        input integer addr;
        input [7:0]   pix;
        reg [31:0] exp_word;
        begin
            exp_word = {pix, pix, pix, pix};
            if (u_ofm.ram[addr] !== exp_word) begin
                $display("[A][MISMATCH] mem[%0d]: got=0x%08h exp=0x%08h (pix=%0d)",
                    addr, u_ofm.ram[addr], exp_word, pix);
                mismatch_a = mismatch_a + 1;
            end
        end
    endtask

    task automatic scenario_A;
        integer ii;
        begin
            $display("============================================================");
            $display("[upsample_tb] Scenario A — small (Co=2, in H_b=W_b=2)");
            $display("============================================================");

            for (ii = 0; ii < 65536; ii = ii + 1) u_ofm.ram[ii] = 32'd0;

            // Filter 0 input (in_base=0, addr 0..3)
            u_ofm.ram[0] = {8'd40, 8'd30, 8'd20, 8'd10};   // block(0,0)
            u_ofm.ram[1] = {8'd80, 8'd70, 8'd60, 8'd50};   // block(0,1)
            u_ofm.ram[2] = {8'd140,8'd130,8'd120,8'd110};  // block(1,0)
            u_ofm.ram[3] = {8'd180,8'd170,8'd160,8'd150};  // block(1,1)
            // Filter 1 input (addr 4..7)
            u_ofm.ram[4] = {8'd44, 8'd33, 8'd22, 8'd11};
            u_ofm.ram[5] = {8'd88, 8'd77, 8'd66, 8'd55};
            u_ofm.ram[6] = {8'd144,8'd133,8'd122,8'd111};
            u_ofm.ram[7] = {8'd188,8'd177,8'd166,8'd155};

            dut_co_total = 12'd2;
            dut_h_blocks = 12'd2;
            dut_w_blocks = 12'd2;
            dut_in_base  = 16'd0;
            dut_out_base = 16'd8;       // in 0..7, out 8..(8+32-1=39)

            run_up;

            mismatch_a = 0;
            // Filter 0 output addr 8..23 (out_W_b = 4):
            //   in block(0,0) pix_00=10 → out (0,0) addr 8
            //   in block(0,0) pix_01=20 → out (0,1) addr 9
            //   in block(0,0) pix_10=30 → out (1,0) addr 12
            //   in block(0,0) pix_11=40 → out (1,1) addr 13
            check_a(8 +  0, 10);
            check_a(8 +  1, 20);
            check_a(8 +  4, 30);
            check_a(8 +  5, 40);
            //   in block(0,1) pix_00=50 → out (0,2) addr 10
            check_a(8 +  2, 50);
            check_a(8 +  3, 60);
            check_a(8 +  6, 70);
            check_a(8 +  7, 80);
            //   in block(1,0) pix_00=110 → out (2,0) addr 16
            check_a(8 +  8, 110);
            check_a(8 +  9, 120);
            check_a(8 + 12, 130);
            check_a(8 + 13, 140);
            //   in block(1,1) pix_00=150 → out (2,2) addr 18
            check_a(8 + 10, 150);
            check_a(8 + 11, 160);
            check_a(8 + 14, 170);
            check_a(8 + 15, 180);
            // Filter 1 spot check (output addr 24..39 = 8 + filter*16)
            check_a(24 +  0, 11);
            check_a(24 + 15, 188);

            if (mismatch_a == 0)
                $display("[upsample_tb][A] *** PASSED *** (18 spot checks)");
            else
                $display("[upsample_tb][A] *** FAILED *** %0d mismatches", mismatch_a);
        end
    endtask

    //--------------------------------------------------------------
    // Scenario B — L18 실 사이즈 (Co=128, in H_b=W_b=4)
    //   in_base=0, out_base = Co × in_H_b × in_W_b = 2048
    //   N_in = 2048, N_out = 8192, dpram 사용 = 10240 word (< 65536)
    //--------------------------------------------------------------
    localparam integer CO_B = 128;
    localparam integer IN_HB_B = 4;
    localparam integer IN_WB_B = 4;
    localparam integer N_IN_B = CO_B * IN_HB_B * IN_WB_B;        // 2048
    localparam integer OUT_BASE_B = N_IN_B;                       // 2048
    localparam integer OUT_HB_B = 2 * IN_HB_B;                    // 8
    localparam integer OUT_WB_B = 2 * IN_WB_B;                    // 8

    task automatic scenario_B;
        integer ii, ff, rr, cc;
        integer in_blk, in_addr;
        reg [31:0] blk;
        reg [7:0]  pix [0:3];   // pix_00, pix_01, pix_10, pix_11
        reg [31:0] exp_word [0:3];
        integer    out_addr [0:3];
        integer    mm, sub;
        begin
            $display("============================================================");
            $display("[upsample_tb] Scenario B — L18 (Co=%0d, in H_b=W_b=%0d)",
                CO_B, IN_HB_B);
            $display("============================================================");

            for (ii = 0; ii < 65536; ii = ii + 1) u_ofm.ram[ii] = 32'd0;
            for (ii = 0; ii < N_IN_B; ii = ii + 1) u_ofm.ram[ii] = gen_block(ii);

            dut_co_total = CO_B[11:0];
            dut_h_blocks = IN_HB_B[11:0];
            dut_w_blocks = IN_WB_B[11:0];
            dut_in_base  = 16'd0;
            dut_out_base = OUT_BASE_B[15:0];

            run_up;

            // SW reference: 각 input block 의 4 pixel → 4 output block 검증
            mm = 0;
            for (ff = 0; ff < CO_B; ff = ff + 1) begin
                for (rr = 0; rr < IN_HB_B; rr = rr + 1) begin
                    for (cc = 0; cc < IN_WB_B; cc = cc + 1) begin
                        in_blk = ff * IN_HB_B * IN_WB_B + rr * IN_WB_B + cc;
                        blk = gen_block(in_blk);

                        pix[0] = blk[ 7: 0];   // pix_00
                        pix[1] = blk[15: 8];   // pix_01
                        pix[2] = blk[23:16];   // pix_10
                        pix[3] = blk[31:24];   // pix_11

                        // 출력 좌표 (out_H_b = 2 × IN_HB, out_W_b = 2 × IN_WB)
                        //   pix_00 → out (2R,   2C  )
                        //   pix_01 → out (2R,   2C+1)
                        //   pix_10 → out (2R+1, 2C  )
                        //   pix_11 → out (2R+1, 2C+1)
                        out_addr[0] = OUT_BASE_B + ff * OUT_HB_B * OUT_WB_B
                                     + (2*rr    ) * OUT_WB_B + (2*cc    );
                        out_addr[1] = OUT_BASE_B + ff * OUT_HB_B * OUT_WB_B
                                     + (2*rr    ) * OUT_WB_B + (2*cc + 1);
                        out_addr[2] = OUT_BASE_B + ff * OUT_HB_B * OUT_WB_B
                                     + (2*rr + 1) * OUT_WB_B + (2*cc    );
                        out_addr[3] = OUT_BASE_B + ff * OUT_HB_B * OUT_WB_B
                                     + (2*rr + 1) * OUT_WB_B + (2*cc + 1);

                        for (sub = 0; sub < 4; sub = sub + 1) begin
                            exp_word[sub] = {pix[sub], pix[sub], pix[sub], pix[sub]};
                            if (u_ofm.ram[out_addr[sub]] !== exp_word[sub]) begin
                                if (mm < 8) begin
                                    $display("[B][MISMATCH] f=%0d r=%0d c=%0d sub=%0d (out_addr=%0d): got=0x%08h exp=0x%08h",
                                        ff, rr, cc, sub, out_addr[sub],
                                        u_ofm.ram[out_addr[sub]], exp_word[sub]);
                                end
                                mm = mm + 1;
                            end
                        end
                    end
                end
            end

            mismatch_b = mm;
            if (mm == 0)
                $display("[upsample_tb][B] *** PASSED *** (%0d/%0d output words)",
                    N_IN_B*4, N_IN_B*4);
            else
                $display("[upsample_tb][B] *** FAILED *** %0d mismatches / %0d",
                    mm, N_IN_B*4);
        end
    endtask

    //--------------------------------------------------------------
    // Main
    //--------------------------------------------------------------
    initial begin
        rstn         = 1'b0;
        dut_start    = 1'b0;
        dut_co_total = 12'd0;
        dut_h_blocks = 12'd0;
        dut_w_blocks = 12'd0;
        dut_in_base  = 16'd0;
        dut_out_base = 16'd0;
        mismatch_a   = 0;
        mismatch_b   = 0;

        #(8*CLK_PERIOD) rstn = 1'b1;
        #(4*CLK_PERIOD);

        scenario_A;

        #(20*CLK_PERIOD);
        rstn = 1'b0;
        #(4*CLK_PERIOD);
        rstn = 1'b1;
        #(4*CLK_PERIOD);

        scenario_B;

        $display("============================================================");
        if (mismatch_a == 0 && mismatch_b == 0)
            $display("[upsample_tb] *** ALL PASSED *** (A + B)");
        else
            $display("[upsample_tb] *** FAILED *** A=%0d  B=%0d",
                mismatch_a, mismatch_b);
        $display("============================================================");

        #(20*CLK_PERIOD) $finish;
    end

    initial begin
        #(100_000_000 * CLK_PERIOD);
        $display("[upsample_tb] *** TIMEOUT ***");
        $finish;
    end

`endif

endmodule
