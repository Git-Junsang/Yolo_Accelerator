`timescale 1ns / 1ns
//----------------------------------------------------------------+
// max_pool_s1_unit_tb.v — stride-1 maxpool (L11) 단일 모듈 검증
//
// 검증 시나리오:
//   1. behavioral OFM dpram + max_pool_s1_unit 결선
//   2. 작은 크기 (Co=2, H_b=W_b=4 = 8×8 spatial) 입력 패턴 생성
//      각 word 의 byte 가 (filter, row, col, sub) 함수의 known 값
//   3. i_start → o_done 대기
//   4. SW reference 로 4 input block 의 stride-1 same-padding max 계산 후 비교
//
// SW reference (per output block (R, C)):
//   blockRC   = input[R][C]               (always valid)
//   blockRC1  = input[R][C+1]             (zero if C+1 >= W_b)
//   blockR1C  = input[R+1][C]             (zero if R+1 >= H_b)
//   blockR1C1 = input[R+1][C+1]           (zero if either oob)
//
//   out_b0 (pix 2R, 2C    ) = max4(rc.b0, rc.b1, rc.b2, rc.b3)
//   out_b1 (pix 2R, 2C+1  ) = max4(rc.b1, rc1.b0, rc.b3, rc1.b2)
//   out_b2 (pix 2R+1, 2C  ) = max4(rc.b2, rc.b3, r1c.b0, r1c.b1)
//   out_b3 (pix 2R+1, 2C+1) = max4(rc.b3, rc1.b2, r1c.b1, r1c1.b0)
//----------------------------------------------------------------+
`include "user_define_h.v"

module max_pool_s1_unit_tb;

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
    // Test 크기 (작게)
    //--------------------------------------------------------------
    localparam integer CO = 2;
    localparam integer HB = 4;
    localparam integer WB = 4;
    localparam integer N_BLOCKS = CO * HB * WB;       // 32

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

    wire [15:0]  out_base_w = CO * HB * WB;       // 32 → output base addr

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

    max_pool_s1_unit u_dut (
        .clk(clk), .rstn(rstn),
        .i_start    (dut_start),
        .o_done     (dut_done),
        .i_co_total (CO[11:0]),
        .i_h_blocks (HB[11:0]),
        .i_w_blocks (WB[11:0]),
        .i_in_base  (16'd0),
        .i_out_base (out_base_w),
        .o_rd_en(dut_rd_en), .o_rd_addr(dut_rd_addr), .i_rd_data(dut_rd_data),
        .o_wr_en(dut_wr_en), .o_wr_addr(dut_wr_addr), .o_wr_data(dut_wr_data)
    );

    //--------------------------------------------------------------
    // 패턴 생성: 각 block 의 4 byte 가 (f, R, C, sub) 함수
    //--------------------------------------------------------------
    function [31:0] gen_block;
        input integer f;
        input integer rr;
        input integer cc;
        reg [7:0] bb0, bb1, bb2, bb3;
        begin
            // byte = (f*16 + rr*4 + cc) << 2 + sub, mod 256
            bb0 = ((f*16 + rr*4 + cc)*4 + 0) & 32'hFF;
            bb1 = ((f*16 + rr*4 + cc)*4 + 1) & 32'hFF;
            bb2 = ((f*16 + rr*4 + cc)*4 + 2) & 32'hFF;
            bb3 = ((f*16 + rr*4 + cc)*4 + 3) & 32'hFF;
            gen_block = {bb3, bb2, bb1, bb0};
        end
    endfunction

    //--------------------------------------------------------------
    // SW reference — stride-1 max
    //--------------------------------------------------------------
    function [7:0] max4f;
        input [7:0] a, b, c, d;
        reg [7:0] m1, m2;
        begin
            m1 = (a > b) ? a : b;
            m2 = (c > d) ? c : d;
            max4f = (m1 > m2) ? m1 : m2;
        end
    endfunction

    function [31:0] expected_out;
        input integer f;
        input integer rr;
        input integer cc;
        reg [31:0] brc, brc1, br1c, br1c1;
        reg [7:0]  o0, o1, o2, o3;
        begin
            brc   = gen_block(f, rr, cc);
            brc1  = ((cc + 1) >= WB) ? 32'd0 : gen_block(f, rr,   cc + 1);
            br1c  = ((rr + 1) >= HB) ? 32'd0 : gen_block(f, rr+1, cc    );
            br1c1 = (((rr + 1) >= HB) || ((cc + 1) >= WB))
                    ? 32'd0 : gen_block(f, rr+1, cc + 1);

            o0 = max4f(brc[7:0],   brc[15:8],  brc[23:16], brc[31:24]);
            o1 = max4f(brc[15:8],  brc1[7:0],  brc[31:24], brc1[23:16]);
            o2 = max4f(brc[23:16], brc[31:24], br1c[7:0],  br1c[15:8]);
            o3 = max4f(brc[31:24], brc1[23:16], br1c[15:8], br1c1[7:0]);

            expected_out = {o3, o2, o1, o0};
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
            for (rr = 0; rr < HB; rr = rr + 1) begin
                for (cc = 0; cc < WB; cc = cc + 1) begin
                    idx = f*HB*WB + rr*WB + cc;
                    u_ofm.ram[idx] = gen_block(f, rr, cc);
                end
            end
        end
        $display("[max_pool_s1_unit_tb] Pattern written (%0d blocks)", N_BLOCKS);

        #(8*CLK_PERIOD) rstn = 1'b1;
        #(4*CLK_PERIOD);

        @(posedge clk);
        dut_start <= 1'b1;
        @(posedge clk);
        dut_start <= 1'b0;
        $display("[max_pool_s1_unit_tb] start @ t=%0t", $time);

        wait (dut_done == 1'b1);
        @(posedge clk);
        $display("[max_pool_s1_unit_tb] done @ t=%0t", $time);

        // 비교 (output base 부터)
        for (f = 0; f < CO; f = f + 1) begin
            for (rr = 0; rr < HB; rr = rr + 1) begin
                for (cc = 0; cc < WB; cc = cc + 1) begin
                    idx = out_base_w + f*HB*WB + rr*WB + cc;
                    got = u_ofm.ram[idx];
                    exp = expected_out(f, rr, cc);
                    if (got !== exp) begin
                        if (mismatch < 8) begin
                            $display("[MISMATCH] f=%0d R=%0d C=%0d  got=0x%08h exp=0x%08h",
                                     f, rr, cc, got, exp);
                        end
                        mismatch = mismatch + 1;
                    end
                end
            end
        end

        if (mismatch == 0)
            $display("[max_pool_s1_unit_tb] *** PASSED (%0d output blocks) ***", N_BLOCKS);
        else
            $display("[max_pool_s1_unit_tb] *** FAILED (%0d mismatches / %0d) ***",
                     mismatch, N_BLOCKS);

        #(20*CLK_PERIOD) $finish;
    end

    initial begin
        #(10_000_000 * CLK_PERIOD);
        $display("[max_pool_s1_unit_tb] TIMEOUT");
        $finish;
    end
`endif

endmodule
