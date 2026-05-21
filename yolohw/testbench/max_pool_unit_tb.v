`timescale 1ns / 1ns
//----------------------------------------------------------------+
// max_pool_unit_tb.v — stride-2 maxpool 단일 모듈 검증
//
// 검증 시나리오:
//   1. behavioral OFM dpram (256 KB, 65536 × 32-bit) 인스턴스화
//   2. 합성 입력 패턴 작성: 작은 Co × H_b × W_b (예: 4 × 8 × 8 = 256 word)
//      각 32-bit word 의 4 byte 는 known 값 (max-of-4 가 계산 가능한 패턴)
//   3. i_start 펄스 → o_done 대기
//   4. dpram 의 output 영역에서 packed word 읽어 expected 와 byte-by-byte 비교
//
// max-of-4 reference:
//   input word = {b3, b2, b1, b0}
//   max-of-4 = max(b0, b1, b2, b3)
//
// 4 input word → 1 output word (4 byte packed in raster-of-4 order)
//----------------------------------------------------------------+
`include "user_define_h.v"

module max_pool_unit_tb;

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
    // Test scale (작게)
    //--------------------------------------------------------------
    localparam integer CO  = 4;
    localparam integer HB  = 8;     // input H_b
    localparam integer WB  = 8;     // input W_b
    localparam integer N_IN = CO * HB * WB;       // 256
    localparam integer N_OUT = N_IN / 4;          // 64

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
    // OFM dpram (dpram_wrapper) — Port A write, Port B read
    //   pool unit 의 wr/rd 를 직접 연결
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

    //--------------------------------------------------------------
    // DUT
    //--------------------------------------------------------------
    max_pool_unit u_dut (
        .clk(clk), .rstn(rstn),
        .i_start         (dut_start),
        .o_done          (dut_done),
        .i_total_in_words(dut_total_in),
        .o_rd_en  (dut_rd_en),  .o_rd_addr(dut_rd_addr), .i_rd_data(dut_rd_data),
        .o_wr_en  (dut_wr_en),  .o_wr_addr(dut_wr_addr), .o_wr_data(dut_wr_data)
    );

    //--------------------------------------------------------------
    // Stimulus + verify
    //--------------------------------------------------------------
    integer    i, j, mismatch;
    reg [31:0] gen_word, gold_word;
    reg [7:0]  b0, b1, b2, b3;
    reg [7:0]  m01, m23, mx;

    function [31:0] gen_pattern;
        input integer idx;
        reg [7:0] bb0, bb1, bb2, bb3;
        begin
            bb0 = (idx*4 + 0) & 32'hFF;
            bb1 = (idx*4 + 1) & 32'hFF;
            bb2 = (idx*4 + 2) & 32'hFF;
            bb3 = (idx*4 + 3) & 32'hFF;
            gen_pattern = {bb3, bb2, bb1, bb0};
        end
    endfunction

    initial begin
        rstn      = 1'b0;
        dut_start = 1'b0;
        dut_total_in = 20'd0;
        mismatch  = 0;

        // dpram 초기화 + 입력 패턴 생성
        //   word i 의 4 byte = {i*4+3, i*4+2, i*4+1, i*4} mod 256
        for (i = 0; i < 65536; i = i + 1) u_ofm.ram[i] = 32'd0;
        for (i = 0; i < N_IN; i = i + 1) begin
            u_ofm.ram[i] = gen_pattern(i);
        end
        $display("[max_pool_unit_tb] Input pattern written (%0d words)", N_IN);

        #(8*CLK_PERIOD) rstn = 1'b1;
        #(4*CLK_PERIOD);

        @(posedge clk);
        dut_total_in <= N_IN[19:0];
        dut_start    <= 1'b1;
        @(posedge clk);
        dut_start    <= 1'b0;
        $display("[max_pool_unit_tb] start @ t=%0t", $time);

        wait (dut_done == 1'b1);
        @(posedge clk);
        $display("[max_pool_unit_tb] done @ t=%0t", $time);

        // 비교: 4 input word → 1 output word (byte 0..3 = max-of-4 of 4 input words)
        for (i = 0; i < N_OUT; i = i + 1) begin
            // 4 input words at i*4..i*4+3, compute expected max bytes
            gold_word = 32'd0;
            for (j = 0; j < 4; j = j + 1) begin
                gen_word = u_ofm.ram[i*4 + j];   // pool 후에도 이 위치는 valid (in-place 안전)
                // Actually input was overwritten? No — pool 의 in-place 는 read 가 write 보다 앞서서 안전.
                //   But in this TB we wrote pattern before pool, pool reads then writes lower addr.
                //   We need expected from ORIGINAL pattern. Re-compute from i*4+j.
                gen_word = gen_pattern(i*4 + j);
                m01 = (gen_word[ 7: 0] > gen_word[15: 8]) ? gen_word[ 7: 0] : gen_word[15: 8];
                m23 = (gen_word[23:16] > gen_word[31:24]) ? gen_word[23:16] : gen_word[31:24];
                mx  = (m01 > m23) ? m01 : m23;
                gold_word[j*8 +: 8] = mx;
            end

            if (u_ofm.ram[i] !== gold_word) begin
                if (mismatch < 8) begin
                    $display("[MISMATCH] out[%0d]: got=0x%08h exp=0x%08h", i, u_ofm.ram[i], gold_word);
                end
                mismatch = mismatch + 1;
            end
        end

        if (mismatch == 0)
            $display("[max_pool_unit_tb] *** PASSED (%0d output words verified) ***", N_OUT);
        else
            $display("[max_pool_unit_tb] *** FAILED (%0d mismatches / %0d) ***", mismatch, N_OUT);

        #(20*CLK_PERIOD) $finish;
    end

    initial begin
        #(10_000_000 * CLK_PERIOD);
        $display("[max_pool_unit_tb] TIMEOUT");
        $finish;
    end
`endif

endmodule
