`timescale 1ns / 1ns
//----------------------------------------------------------------+
// pool_s1_tb.v — max_pool_s1_unit (stride-1 same-padding) Phase 3 검증
//
// 검증 목표:
//   - max_pool_s1_unit 의 산술 (3-input/4-input max + oob padding) 및 FSM
//   - yolo_engine 의 dpram_wrapper (DEPTH=65536) 인터페이스 일치
//   - Layer 11 실 사이즈 (Co=512, H_b=W_b=4 → in 8192 + out 8192 word)
//   - in_base=0, out_base=Co × H_b × W_b 의 분리 영역 동작
//
// Packed format (입력/출력 동일):
//   32-bit word = 한 2×2 OFM block (filter f 의 좌표 (2R, 2C)..(2R+1, 2C+1))
//     byte 0 = pix_00 = (2R,   2C  )
//     byte 1 = pix_01 = (2R,   2C+1)
//     byte 2 = pix_10 = (2R+1, 2C  )
//     byte 3 = pix_11 = (2R+1, 2C+1)
//
// SW reference (per output block (f, R, C)):
//   blockRC   = (f, R,   C  )   always valid
//   blockRC1  = (f, R,   C+1)   C+1 >= W_b → 0
//   blockR1C  = (f, R+1, C  )   R+1 >= H_b → 0
//   blockR1C1 = (f, R+1, C+1)   any oob   → 0
//
//   out_pix_00 = max(blockRC.b0, blockRC.b1, blockRC.b2, blockRC.b3)
//   out_pix_01 = max(blockRC.b1, blockRC1.b0, blockRC.b3, blockRC1.b2)
//   out_pix_10 = max(blockRC.b2, blockRC.b3, blockR1C.b0, blockR1C.b1)
//   out_pix_11 = max(blockRC.b3, blockRC1.b2, blockR1C.b1, blockR1C1.b0)
//
// 시나리오:
//   A: 손계산 검증 (Co=2, H_b=W_b=2) — 회귀 안전망
//   B: L11 실 사이즈 (Co=512, H_b=W_b=4)
//----------------------------------------------------------------+
`include "user_define_h.v"

module pool_s1_tb;

`ifdef FPGA
    initial begin
        $display("[pool_s1_tb][FATAL] FPGA macro 활성. user_define_h.v 의 `define FPGA 주석 처리 필요.");
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
    // OFM dpram — yolo_engine 의 u_ofm 과 동일 파라미터
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

    max_pool_s1_unit u_dut (
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
    // Helpers
    //--------------------------------------------------------------
    function [7:0] max4_b;
        input [7:0] a, b, c, d;
        reg [7:0] m1, m2;
        begin
            m1 = (a > b) ? a : b;
            m2 = (c > d) ? c : d;
            max4_b = (m1 > m2) ? m1 : m2;
        end
    endfunction

    // block index → 32-bit packed word (deterministic pattern)
    //   pat[blk] = { (blk*4+3)&0xFF, (blk*4+2)&0xFF, (blk*4+1)&0xFF, (blk*4)&0xFF }
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

    //--------------------------------------------------------------
    // Common runner / verifier (B 시나리오 전용 — A 는 손계산 expected)
    //--------------------------------------------------------------
    integer i, mismatch_a, mismatch_b;

    task automatic run_pool;
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
    // Scenario A — Co=2, H_b=W_b=2 (손계산)
    //--------------------------------------------------------------
    reg [31:0] exp_a [0:7];

    task automatic scenario_A;
        integer ii;
        begin
            $display("============================================================");
            $display("[pool_s1_tb] Scenario A — small (Co=2, H_b=W_b=2)");
            $display("============================================================");

            // 메모리 초기화
            for (ii = 0; ii < 65536; ii = ii + 1) u_ofm.ram[ii] = 32'd0;

            // Filter 0 input blocks (in_base=0, addr 0..3)
            //   block(0,0) = pixels (0,0)(0,1)(1,0)(1,1) = (10, 20, 50, 60)
            //   block(0,1) = pixels (0,2)(0,3)(1,2)(1,3) = (30, 40, 70, 80)
            //   block(1,0) = pixels (2,0)(2,1)(3,0)(3,1) = (12, 22, 52, 62)
            //   block(1,1) = pixels (2,2)(2,3)(3,2)(3,3) = (32, 42, 72, 82)
            u_ofm.ram[0] = {8'd60, 8'd50, 8'd20, 8'd10};
            u_ofm.ram[1] = {8'd80, 8'd70, 8'd40, 8'd30};
            u_ofm.ram[2] = {8'd62, 8'd52, 8'd22, 8'd12};
            u_ofm.ram[3] = {8'd82, 8'd72, 8'd42, 8'd32};

            // Filter 1: 모든 픽셀 = 5 (간단 검증)
            for (ii = 4; ii < 8; ii = ii + 1) u_ofm.ram[ii] = 32'h05050505;

            // Expected (filter 0) — header 참조
            //   out_block(0,0) = (60, 70, 60, 70) → word {70, 60, 70, 60}
            //   out_block(0,1) = (80, 80, 80, 80)
            //   out_block(1,0) = (62, 72, 62, 72)
            //   out_block(1,1) = (82, 82, 82, 82)
            exp_a[0] = {8'd70, 8'd60, 8'd70, 8'd60};
            exp_a[1] = {8'd80, 8'd80, 8'd80, 8'd80};
            exp_a[2] = {8'd72, 8'd62, 8'd72, 8'd62};
            exp_a[3] = {8'd82, 8'd82, 8'd82, 8'd82};
            exp_a[4] = 32'h05050505;
            exp_a[5] = 32'h05050505;
            exp_a[6] = 32'h05050505;
            exp_a[7] = 32'h05050505;

            dut_co_total = 12'd2;
            dut_h_blocks = 12'd2;
            dut_w_blocks = 12'd2;
            dut_in_base  = 16'd0;
            dut_out_base = 16'd16;        // 영역 분리 (in 0..7, out 16..23)

            run_pool;

            mismatch_a = 0;
            for (ii = 0; ii < 8; ii = ii + 1) begin
                if (u_ofm.ram[16 + ii] !== exp_a[ii]) begin
                    $display("[A][MISMATCH] out[%0d] (addr %0d): got=0x%08h exp=0x%08h",
                        ii, 16+ii, u_ofm.ram[16+ii], exp_a[ii]);
                    mismatch_a = mismatch_a + 1;
                end
            end

            if (mismatch_a == 0)
                $display("[pool_s1_tb][A] *** PASSED *** (8/8 output words)");
            else
                $display("[pool_s1_tb][A] *** FAILED *** %0d mismatches", mismatch_a);
        end
    endtask

    //--------------------------------------------------------------
    // Scenario B — L11 실 사이즈 (Co=512, H_b=W_b=4)
    //   in_base=0, out_base=Co*H_b*W_b = 8192
    //   총 dpram 사용량 = 16384 word (< 65536 OK)
    //--------------------------------------------------------------
    localparam integer CO_B = 512;
    localparam integer HB_B = 4;
    localparam integer WB_B = 4;
    localparam integer N_BLK_B = CO_B * HB_B * WB_B;   // 8192
    localparam integer OUT_BASE_B = N_BLK_B;            // 8192

    task automatic scenario_B;
        integer ii, ff, rr, cc;
        integer addr_rc, addr_rc1, addr_r1c, addr_r1c1;
        reg [31:0] blk_rc, blk_rc1, blk_r1c, blk_r1c1;
        reg [7:0] rc_b0, rc_b1, rc_b2, rc_b3, rc1_b0, rc1_b2;
        reg [7:0] r1c_b0, r1c_b1, r1c1_b0;
        reg [7:0] exp_b0, exp_b1, exp_b2, exp_b3;
        reg [31:0] exp_word, got_word;
        integer mm;
        begin
            $display("============================================================");
            $display("[pool_s1_tb] Scenario B — L11 size (Co=%0d, H_b=W_b=%0d, N_in=%0d)",
                CO_B, HB_B, N_BLK_B);
            $display("============================================================");

            // 메모리 초기화 + 패턴 적재
            for (ii = 0; ii < 65536; ii = ii + 1) u_ofm.ram[ii] = 32'd0;
            for (ii = 0; ii < N_BLK_B; ii = ii + 1) u_ofm.ram[ii] = gen_block(ii);

            dut_co_total = CO_B[11:0];
            dut_h_blocks = HB_B[11:0];
            dut_w_blocks = WB_B[11:0];
            dut_in_base  = 16'd0;
            dut_out_base = OUT_BASE_B[15:0];

            run_pool;

            // SW reference: 각 output block 계산 후 비교
            mm = 0;
            for (ff = 0; ff < CO_B; ff = ff + 1) begin
                for (rr = 0; rr < HB_B; rr = rr + 1) begin
                    for (cc = 0; cc < WB_B; cc = cc + 1) begin
                        addr_rc   =  ff * HB_B * WB_B +  rr     * WB_B + cc;
                        addr_rc1  =  ff * HB_B * WB_B +  rr     * WB_B + (cc + 1);
                        addr_r1c  =  ff * HB_B * WB_B + (rr + 1)* WB_B + cc;
                        addr_r1c1 =  ff * HB_B * WB_B + (rr + 1)* WB_B + (cc + 1);

                        blk_rc   = gen_block(addr_rc);
                        blk_rc1  = (cc + 1 < WB_B) ? gen_block(addr_rc1)  : 32'd0;
                        blk_r1c  = (rr + 1 < HB_B) ? gen_block(addr_r1c)  : 32'd0;
                        blk_r1c1 = ((cc + 1 < WB_B) && (rr + 1 < HB_B))
                                   ? gen_block(addr_r1c1) : 32'd0;

                        rc_b0   = blk_rc  [ 7: 0];
                        rc_b1   = blk_rc  [15: 8];
                        rc_b2   = blk_rc  [23:16];
                        rc_b3   = blk_rc  [31:24];
                        rc1_b0  = blk_rc1 [ 7: 0];
                        rc1_b2  = blk_rc1 [23:16];
                        r1c_b0  = blk_r1c [ 7: 0];
                        r1c_b1  = blk_r1c [15: 8];
                        r1c1_b0 = blk_r1c1[ 7: 0];

                        exp_b0 = max4_b(rc_b0,  rc_b1,  rc_b2,  rc_b3);
                        exp_b1 = max4_b(rc_b1,  rc1_b0, rc_b3,  rc1_b2);
                        exp_b2 = max4_b(rc_b2,  rc_b3,  r1c_b0, r1c_b1);
                        exp_b3 = max4_b(rc_b3,  rc1_b2, r1c_b1, r1c1_b0);
                        exp_word = {exp_b3, exp_b2, exp_b1, exp_b0};

                        got_word = u_ofm.ram[OUT_BASE_B + addr_rc];

                        if (got_word !== exp_word) begin
                            if (mm < 8) begin
                                $display("[B][MISMATCH] f=%0d r=%0d c=%0d (out_addr=%0d): got=0x%08h exp=0x%08h",
                                    ff, rr, cc, OUT_BASE_B + addr_rc, got_word, exp_word);
                            end
                            mm = mm + 1;
                        end
                    end
                end
            end

            mismatch_b = mm;
            if (mm == 0)
                $display("[pool_s1_tb][B] *** PASSED *** (%0d/%0d output words)",
                    N_BLK_B, N_BLK_B);
            else
                $display("[pool_s1_tb][B] *** FAILED *** %0d mismatches / %0d",
                    mm, N_BLK_B);
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

        // Scenario B 전 reset (FSM 깨끗하게)
        #(20*CLK_PERIOD);
        rstn = 1'b0;
        #(4*CLK_PERIOD);
        rstn = 1'b1;
        #(4*CLK_PERIOD);

        scenario_B;

        $display("============================================================");
        if (mismatch_a == 0 && mismatch_b == 0)
            $display("[pool_s1_tb] *** ALL PASSED *** (A + B)");
        else
            $display("[pool_s1_tb] *** FAILED *** A=%0d  B=%0d",
                mismatch_a, mismatch_b);
        $display("============================================================");

        #(20*CLK_PERIOD) $finish;
    end

    initial begin
        #(100_000_000 * CLK_PERIOD);
        $display("[pool_s1_tb] *** TIMEOUT ***");
        $finish;
    end

`endif

endmodule
