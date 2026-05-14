`timescale 1ns / 1ns
//----------------------------------------------------------------+
// pool_tb.v — max_pool_unit (stride 2) 합성 데이터 검증
//
// 시나리오:
//   - 작은 OFM dpram 모델 (1024 × 32-bit) 을 TB 가 보유
//   - 8 × 4 × 4 = 128 input packed word (Co=8, H_b=W_b=4)
//   - 각 word 의 4 byte 에 알려진 값 적재
//   - max_pool_unit 동작 후 결과를 검증
//
// 동작 검증:
//   - 1 input word = 2×2 OFM block → max-of-4 = 1 output byte
//   - 4 output byte 묶임 = 1 output word
//   - 전체: 128 input word → 32 output word
//----------------------------------------------------------------+
`include "user_define_h.v"

module pool_tb;

    parameter CLK_PERIOD = 10;
    reg clk;
    reg rstn;

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    // ---- DUT 신호 ----
    reg         start;
    wire        done;
    reg  [19:0] total_in_words;
    wire        rd_en;
    wire [15:0] rd_addr;
    reg  [31:0] rd_data;
    wire        wr_en;
    wire [15:0] wr_addr;
    wire [31:0] wr_data;

    max_pool_unit u_dut (
        .clk(clk), .rstn(rstn),
        .i_start(start), .o_done(done),
        .i_total_in_words(total_in_words),
        .o_rd_en(rd_en), .o_rd_addr(rd_addr), .i_rd_data(rd_data),
        .o_wr_en(wr_en), .o_wr_addr(wr_addr), .o_wr_data(wr_data)
    );

    //--------------------------------------------------------------
    // 메모리 모델 (1 cycle read latency 모사)
    //--------------------------------------------------------------
    reg [31:0] mem [0:1023];
    reg [31:0] rd_data_r;

    always @(posedge clk) begin
        if (rd_en)  rd_data_r <= mem[rd_addr];
        if (wr_en)  mem[wr_addr] <= wr_data;
    end
    always @(*) rd_data = rd_data_r;

    //--------------------------------------------------------------
    // Test 시나리오
    //--------------------------------------------------------------
    integer i, idx;
    integer mismatch;
    reg [7:0] expected_b0, expected_b1, expected_b2, expected_b3;
    reg [7:0] got_b0, got_b1, got_b2, got_b3;

    initial begin
        rstn = 1'b0;
        start = 1'b0;
        total_in_words = 20'd0;
        mismatch = 0;

        // 메모리 초기화 — 알려진 패턴
        //   word i = (i*4+3 << 24) | (i*4+2 << 16) | (i*4+1 << 8) | (i*4+0)
        //   단, 각 byte 가 0~255 범위 내 (i ≤ 63 시 OK)
        for (i = 0; i < 1024; i = i + 1) mem[i] = 32'd0;
        for (i = 0; i < 128; i = i + 1) begin
            mem[i] = {
                ((i*4+3) & 8'hFF),
                ((i*4+2) & 8'hFF),
                ((i*4+1) & 8'hFF),
                ((i*4+0) & 8'hFF)
            };
        end

        // Reset 해제
        #(8*CLK_PERIOD) rstn = 1'b1;
        #(4*CLK_PERIOD);

        // Pool start: 128 input → 32 output
        @(posedge clk);
        total_in_words = 20'd128;
        start          = 1'b1;
        @(posedge clk);
        start = 1'b0;

        // Done 대기
        $display("[pool_tb] Pool started — waiting for done...");
        wait (done == 1'b1);
        #(4*CLK_PERIOD);
        $display("[pool_tb] Done at t=%0t", $time);

        // 검증: input word i 의 4 byte 중 max → output byte
        //       4 input → 1 output word
        //       output word j 의 4 byte = max(input[4j..4j+3]의 4 byte) 각각
        for (i = 0; i < 32; i = i + 1) begin
            // input word 4i..4i+3 의 max-of-4 4 개
            expected_b0 = max_of_word(mem_input_word(4*i + 0));
            expected_b1 = max_of_word(mem_input_word(4*i + 1));
            expected_b2 = max_of_word(mem_input_word(4*i + 2));
            expected_b3 = max_of_word(mem_input_word(4*i + 3));
            got_b0 = mem[i][7:0];
            got_b1 = mem[i][15:8];
            got_b2 = mem[i][23:16];
            got_b3 = mem[i][31:24];
            if (expected_b0 !== got_b0 || expected_b1 !== got_b1 ||
                expected_b2 !== got_b2 || expected_b3 !== got_b3) begin
                $display("[pool_tb][MISMATCH] out[%0d]: got %02h_%02h_%02h_%02h, expected %02h_%02h_%02h_%02h",
                    i, got_b3, got_b2, got_b1, got_b0,
                    expected_b3, expected_b2, expected_b1, expected_b0);
                mismatch = mismatch + 1;
            end
        end

        $display("============================================================");
        if (mismatch == 0) $display("[pool_tb] *** PASSED *** (32/32 output words match)");
        else               $display("[pool_tb] *** FAILED *** %0d mismatches", mismatch);
        $display("============================================================");
        #(10*CLK_PERIOD) $finish;
    end

    //--------------------------------------------------------------
    // Helper: input word i 의 4 byte 중 max
    //--------------------------------------------------------------
    function [7:0] max_of_word;
        input [31:0] w;
        reg [7:0] b0, b1, b2, b3, m01, m23;
        begin
            b0 = w[7:0]; b1 = w[15:8]; b2 = w[23:16]; b3 = w[31:24];
            m01 = (b0 > b1) ? b0 : b1;
            m23 = (b2 > b3) ? b2 : b3;
            max_of_word = (m01 > m23) ? m01 : m23;
        end
    endfunction

    // mem 의 원본 input word 를 가져오기 위한 helper (in-place 처리 후 검증 위해
    // 보존된 영역을 별도 reg array 에 백업).
    // pool 은 in-place 가 아니므로 mem 의 원본은 유지됨.
    // 단, write 가 0..31 영역에 일어나므로 그 영역은 덮어써짐.
    // 백업본을 별도로 저장:
    reg [31:0] mem_backup [0:127];
    initial begin
        // mem 적재와 함께 백업
        // (always 가 아닌 다른 initial 에서 백업)
        @(posedge rstn);
        for (idx = 0; idx < 128; idx = idx + 1) mem_backup[idx] = mem[idx];
    end

    function [31:0] mem_input_word;
        input integer index;
        begin
            mem_input_word = mem_backup[index];
        end
    endfunction

    //--------------------------------------------------------------
    // Watchdog
    //--------------------------------------------------------------
    initial begin
        #(100_000 * CLK_PERIOD);
        $display("[pool_tb] *** TIMEOUT ***");
        $finish;
    end

endmodule
