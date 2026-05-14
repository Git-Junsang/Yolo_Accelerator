`timescale 1ns / 1ns
//----------------------------------------------------------------+
// pool_s1_tb.v — max_pool_s1_unit (stride 1 same-padding) 검증
//
// 시나리오 (Co=2, H_b=W_b=2 → 출력 dim 2×2 block per filter):
//   input pixel grid (filter 0):
//     col → 0  1  2  3
//   row 0   10 20 30 40
//   row 1   50 60 70 80
//   row 2   12 22 32 42
//   row 3   52 62 72 82
//
//   stride-1 maxpool same padding:
//     output[r][c] = max(in[r][c], in[r][c+1], in[r+1][c], in[r+1][c+1])
//                    (oob → 0)
//   기대 output (filter 0):
//   row 0   60 70 80 40   (col 3 의 oob 처리: in[0][4]=0, in[1][4]=0 → max(40, 0, 80, 0) = 80? 아냐 위치 다름)
//
// 정확히:
//   out[0][0] = max(in[0][0], in[0][1], in[1][0], in[1][1]) = max(10,20,50,60) = 60
//   out[0][1] = max(20,30,60,70) = 70
//   out[0][2] = max(30,40,70,80) = 80
//   out[0][3] = max(40, 0,80, 0) = 80
//   out[1][0] = max(50,60,12,22) = 60
//   out[1][1] = max(60,70,22,32) = 70
//   out[1][2] = max(70,80,32,42) = 80
//   out[1][3] = max(80, 0,42, 0) = 80
//   out[2][0] = max(12,22,52,62) = 62
//   out[2][1] = max(22,32,62,72) = 72
//   out[2][2] = max(32,42,72,82) = 82
//   out[2][3] = max(42, 0,82, 0) = 82
//   out[3][0] = max(52,62, 0, 0) = 62
//   out[3][1] = max(62,72, 0, 0) = 72
//   out[3][2] = max(72,82, 0, 0) = 82
//   out[3][3] = max(82, 0, 0, 0) = 82
//
// Packed (2×2 block) format → input/output 모두 같음:
//   input block (R, C) (R, C in 0..1) packs 4 pixels at (2R, 2C)..(2R+1, 2C+1).
//   filter 0 input blocks:
//     block(0,0) = pixels at (0,0)(0,1)(1,0)(1,1) = (10, 20, 50, 60) → word {60, 50, 20, 10}
//     block(0,1) = pixels at (0,2)(0,3)(1,2)(1,3) = (30, 40, 70, 80) → word {80, 70, 40, 30}
//     block(1,0) = pixels at (2,0)(2,1)(3,0)(3,1) = (12, 22, 52, 62) → word {62, 52, 22, 12}
//     block(1,1) = pixels at (2,2)(2,3)(3,2)(3,3) = (32, 42, 72, 82) → word {82, 72, 42, 32}
//
// 출력 block 도 같은 packing:
//   out_block(0,0) = pixels at (0,0)(0,1)(1,0)(1,1) = (60, 70, 60, 70) → word {70, 60, 70, 60}
//   out_block(0,1) = pixels at (0,2)(0,3)(1,2)(1,3) = (80, 80, 80, 80) → word {80, 80, 80, 80}
//   out_block(1,0) = pixels at (2,0)(2,1)(3,0)(3,1) = (62, 72, 62, 72) → word {72, 62, 72, 62}
//   out_block(1,1) = pixels at (2,2)(2,3)(3,2)(3,3) = (82, 82, 82, 82) → word {82, 82, 82, 82}
//----------------------------------------------------------------+
`include "user_define_h.v"

module pool_s1_tb;

    parameter CLK_PERIOD = 10;
    reg clk;
    reg rstn;

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    // ---- DUT ----
    reg         start;
    wire        done;
    wire        rd_en;
    wire [15:0] rd_addr;
    reg  [31:0] rd_data;
    wire        wr_en;
    wire [15:0] wr_addr;
    wire [31:0] wr_data;

    max_pool_s1_unit u_dut (
        .clk(clk), .rstn(rstn),
        .i_start(start), .o_done(done),
        .i_co_total(12'd2),
        .i_h_blocks(12'd2),
        .i_w_blocks(12'd2),
        .i_in_base (16'd0),
        .i_out_base(16'd16),       // output 영역은 16 word 이후
        .o_rd_en(rd_en), .o_rd_addr(rd_addr), .i_rd_data(rd_data),
        .o_wr_en(wr_en), .o_wr_addr(wr_addr), .o_wr_data(wr_data)
    );

    //--------------------------------------------------------------
    // 메모리 모델 (1 cycle read latency)
    //--------------------------------------------------------------
    reg [31:0] mem [0:63];
    reg [31:0] rd_data_r;

    always @(posedge clk) begin
        if (rd_en) rd_data_r <= mem[rd_addr];
        if (wr_en) mem[wr_addr] <= wr_data;
    end
    always @(*) rd_data = rd_data_r;

    //--------------------------------------------------------------
    // Test
    //--------------------------------------------------------------
    integer i, mismatch;
    reg [31:0] expected [0:7];   // 2 filters × 4 blocks = 8 output word

    initial begin
        rstn = 1'b0;
        start = 1'b0;
        mismatch = 0;

        // Clear mem
        for (i = 0; i < 64; i = i + 1) mem[i] = 32'd0;

        // Filter 0 input (4 blocks at addr 0..3)
        mem[0] = {8'd60, 8'd50, 8'd20, 8'd10};   // block(0,0)
        mem[1] = {8'd80, 8'd70, 8'd40, 8'd30};   // block(0,1)
        mem[2] = {8'd62, 8'd52, 8'd22, 8'd12};   // block(1,0)
        mem[3] = {8'd82, 8'd72, 8'd42, 8'd32};   // block(1,1)
        // Filter 1 input — 모두 동일 값 (간단 검증)
        for (i = 4; i < 8; i = i + 1) mem[i] = 32'h05050505;

        // Expected output (filter 0)
        expected[0] = {8'd70, 8'd60, 8'd70, 8'd60};  // out_block(0,0)
        expected[1] = {8'd80, 8'd80, 8'd80, 8'd80};  // out_block(0,1)
        expected[2] = {8'd72, 8'd62, 8'd72, 8'd62};  // out_block(1,0)
        expected[3] = {8'd82, 8'd82, 8'd82, 8'd82};  // out_block(1,1)
        // Filter 1 — 모두 동일 값 → max-of-4 = 5, packed = 0x05050505
        expected[4] = 32'h05050505;
        expected[5] = 32'h05050505;
        expected[6] = 32'h05050505;
        expected[7] = 32'h05050505;

        // Reset 해제
        #(8*CLK_PERIOD) rstn = 1'b1;
        #(4*CLK_PERIOD);

        // Start
        @(posedge clk);
        start = 1'b1;
        @(posedge clk);
        start = 1'b0;

        $display("[pool_s1_tb] Started — waiting for done...");
        wait (done == 1'b1);
        #(4*CLK_PERIOD);
        $display("[pool_s1_tb] Done at t=%0t", $time);

        // 검증 — 출력 영역 addr 16..23
        for (i = 0; i < 8; i = i + 1) begin
            if (mem[16 + i] !== expected[i]) begin
                $display("[pool_s1_tb][MISMATCH] out[%0d] (addr %0d): got %h, expected %h",
                    i, 16+i, mem[16+i], expected[i]);
                mismatch = mismatch + 1;
            end else begin
                $display("[pool_s1_tb][OK]       out[%0d]: %h", i, mem[16+i]);
            end
        end

        $display("============================================================");
        if (mismatch == 0) $display("[pool_s1_tb] *** PASSED *** (8/8 output words match)");
        else               $display("[pool_s1_tb] *** FAILED *** %0d mismatches", mismatch);
        $display("============================================================");
        #(10*CLK_PERIOD) $finish;
    end

    initial begin
        #(100_000 * CLK_PERIOD);
        $display("[pool_s1_tb] *** TIMEOUT ***");
        $finish;
    end

endmodule
