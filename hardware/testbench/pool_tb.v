`timescale 1ns / 1ns
//----------------------------------------------------------------+
// pool_tb.v — max_pool_unit (stride-2) Phase 3 합성 준비 검증
//
// 검증 목표:
//   - max_pool_unit 의 산술 (max-of-4) 및 FSM
//   - yolo_engine 이 실제 사용하는 dpram_wrapper 와의 인터페이스
//     (DEPTH=65536, AW=16, DW=32, N_DELAY=1) — dpram_65536x32 IP 매칭
//   - in-place write 안전성 (read addr 4K+3 vs write addr K)
//   - stream_pool_mode 의 65536-word chunk 처리 검증
//
// 시나리오:
//   Scenario A — small (Co=4, H_b=W_b=8, N_IN=256 word, N_OUT=64 word)
//     알려진 패턴 word i = {i*4+3, i*4+2, i*4+1, i*4} mod 256
//
//   Scenario B — large stream (N_IN=65536 word = dpram 가득)
//     stream_pool_mode 의 한 chunk 와 동일 크기. in-place 안전성 stress.
//     패턴: word i = {(i*4+3)&0xFF, (i*4+2)&0xFF, (i*4+1)&0xFF, (i*4)&0xFF}
//
// SW reference:
//   1 input word = 2×2 OFM block (byte 0..3 = pixel 00, 01, 10, 11)
//   → max-of-4 = 1 output byte
//   4 input word → 1 output word (raster-of-4 order)
//----------------------------------------------------------------+
`include "user_define_h.v"

module pool_tb;

`ifdef FPGA
    initial begin
        $display("[pool_tb][FATAL] FPGA macro 활성. user_define_h.v 의 `define FPGA 주석 처리 필요.");
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
    reg  [19:0]  dut_total_in;
    wire         dut_rd_en;
    wire [15:0]  dut_rd_addr;
    wire [31:0]  dut_rd_data;
    wire         dut_wr_en;
    wire [15:0]  dut_wr_addr;
    wire [31:0]  dut_wr_data;

    //--------------------------------------------------------------
    // OFM dpram — yolo_engine 의 u_ofm 과 동일 파라미터
    //   (yolo_engine.v:772 참조)
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

    max_pool_unit u_dut (
        .clk(clk), .rstn(rstn),
        .i_start         (dut_start),
        .o_done          (dut_done),
        .i_total_in_words(dut_total_in),
        .o_rd_en  (dut_rd_en),  .o_rd_addr(dut_rd_addr), .i_rd_data(dut_rd_data),
        .o_wr_en  (dut_wr_en),  .o_wr_addr(dut_wr_addr), .o_wr_data(dut_wr_data)
    );

    //--------------------------------------------------------------
    // Pattern generator (양쪽 시나리오 공통)
    //--------------------------------------------------------------
    function [31:0] gen_pattern;
        input integer idx;
        reg [7:0] b0, b1, b2, b3;
        begin
            b0 = (idx*4 + 0) & 32'hFF;
            b1 = (idx*4 + 1) & 32'hFF;
            b2 = (idx*4 + 2) & 32'hFF;
            b3 = (idx*4 + 3) & 32'hFF;
            gen_pattern = {b3, b2, b1, b0};
        end
    endfunction

    function [7:0] max_of_word_byte;
        input [31:0] w;
        reg [7:0] b0, b1, b2, b3, m01, m23;
        begin
            b0 = w[ 7: 0]; b1 = w[15: 8]; b2 = w[23:16]; b3 = w[31:24];
            m01 = (b0 > b1) ? b0 : b1;
            m23 = (b2 > b3) ? b2 : b3;
            max_of_word_byte = (m01 > m23) ? m01 : m23;
        end
    endfunction

    //--------------------------------------------------------------
    // Backup (in-place write 후에도 expected 계산 가능하도록)
    //--------------------------------------------------------------
    reg [31:0] backup [0:65535];

    //--------------------------------------------------------------
    // Scenario runner
    //--------------------------------------------------------------
    integer    i, j, mismatch_a, mismatch_b;
    reg [31:0] gen_word, gold_word;

    task automatic load_pattern;
        input integer n_in;
        integer ii;
        begin
            for (ii = 0; ii < 65536; ii = ii + 1) u_ofm.ram[ii] = 32'd0;
            for (ii = 0; ii < n_in; ii = ii + 1) begin
                u_ofm.ram[ii] = gen_pattern(ii);
                backup[ii]    = u_ofm.ram[ii];
            end
        end
    endtask

    task automatic run_pool;
        input [19:0] n_in;
        begin
            @(posedge clk);
            dut_total_in <= n_in;
            dut_start    <= 1'b1;
            @(posedge clk);
            dut_start    <= 1'b0;
            wait (dut_done == 1'b1);
            @(posedge clk);
        end
    endtask

    task automatic verify;
        input integer n_in;
        output integer mm;
        integer ii, jj;
        reg [31:0] gw;
        begin
            mm = 0;
            for (ii = 0; ii < n_in/4; ii = ii + 1) begin
                gw = 32'd0;
                for (jj = 0; jj < 4; jj = jj + 1) begin
                    gw[jj*8 +: 8] = max_of_word_byte(backup[ii*4 + jj]);
                end
                if (u_ofm.ram[ii] !== gw) begin
                    if (mm < 8) begin
                        $display("[MISMATCH] out[%0d]: got=0x%08h exp=0x%08h",
                            ii, u_ofm.ram[ii], gw);
                    end
                    mm = mm + 1;
                end
            end
        end
    endtask

    initial begin
        rstn         = 1'b0;
        dut_start    = 1'b0;
        dut_total_in = 20'd0;
        mismatch_a   = 0;
        mismatch_b   = 0;

        #(8*CLK_PERIOD) rstn = 1'b1;
        #(4*CLK_PERIOD);

        //--------------------------------------------------------------
        // Scenario A: small (Co=4, H_b=W_b=8, N_IN=256, N_OUT=64)
        //--------------------------------------------------------------
        $display("============================================================");
        $display("[pool_tb] Scenario A — small (N_IN=256)");
        $display("============================================================");
        load_pattern(256);
        run_pool(20'd256);
        verify(256, mismatch_a);
        if (mismatch_a == 0)
            $display("[pool_tb][A] *** PASSED *** (64/64 output words match)");
        else
            $display("[pool_tb][A] *** FAILED *** %0d mismatches", mismatch_a);

        #(20*CLK_PERIOD);

        //--------------------------------------------------------------
        // Scenario B: large stream chunk (N_IN=65536, N_OUT=16384)
        //   stream_pool_mode 의 한 chunk 와 동일. dpram 가득 채워서 in-place stress.
        //--------------------------------------------------------------
        $display("============================================================");
        $display("[pool_tb] Scenario B — large stream chunk (N_IN=65536)");
        $display("============================================================");
        rstn = 1'b0;
        #(4*CLK_PERIOD);
        rstn = 1'b1;
        #(4*CLK_PERIOD);

        load_pattern(65536);
        run_pool(20'd65536);
        verify(65536, mismatch_b);
        if (mismatch_b == 0)
            $display("[pool_tb][B] *** PASSED *** (16384/16384 output words match)");
        else
            $display("[pool_tb][B] *** FAILED *** %0d mismatches", mismatch_b);

        //--------------------------------------------------------------
        // 최종 결과
        //--------------------------------------------------------------
        $display("============================================================");
        if (mismatch_a == 0 && mismatch_b == 0)
            $display("[pool_tb] *** ALL PASSED *** (small + large stream chunk)");
        else
            $display("[pool_tb] *** FAILED *** A=%0d  B=%0d", mismatch_a, mismatch_b);
        $display("============================================================");

        #(20*CLK_PERIOD) $finish;
    end

    initial begin
        #(50_000_000 * CLK_PERIOD);
        $display("[pool_tb] *** TIMEOUT ***");
        $finish;
    end

`endif

endmodule
