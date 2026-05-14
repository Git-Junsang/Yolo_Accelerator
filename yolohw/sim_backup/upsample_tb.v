`timescale 1ns / 1ns
//----------------------------------------------------------------+
// upsample_tb.v — upsample_unit 검증 (2× nearest neighbor)
//
// 시나리오 (Co=2, in H_b = W_b = 2 → output 16 blocks per filter):
//   filter 0 input block (R, C) = packed (4 pixel × 1 channel):
//     block(0,0): {p11=40, p10=30, p01=20, p00=10}
//     block(0,1): {p11=80, p10=70, p01=60, p00=50}
//     block(1,0): {p11=140,p10=130,p01=120,p00=110}
//     block(1,1): {p11=180,p10=170,p01=160,p00=150}
//
//   각 input pixel → 2×2 output pixel (값 복제)
//   1 input word → 4 output word (각 word 의 4 byte 가 같은 값)
//
//   기대 output for input block(0,0):
//     p00=10 → 4 output blocks at (4R+0, 4C+0): {10,10,10,10}
//     p01=20 → output addr offset (4R+0, 4C+1): {20,20,20,20}
//     p10=30 → output addr offset (4R+1, 4C+0): {30,30,30,30}
//     p11=40 → output addr offset (4R+1, 4C+1): {40,40,40,40}
//
//   filter 0 output dimension: 4 out_H_b × 4 out_W_b = 16 blocks
//
//   filter 0 output addr (out_W_b = 2 × in_W_b = 4):
//     out_addr = out_row × 4 + out_col
//     for input block(0,0) → 4 output blocks at:
//       (out_row 0, out_col 0): p00 → addr 0  = {10,10,10,10}
//       (out_row 0, out_col 1): p01 → addr 1  = {20,20,20,20}
//       (out_row 1, out_col 0): p10 → addr 4  = {30,30,30,30}
//       (out_row 1, out_col 1): p11 → addr 5  = {40,40,40,40}
//     for input block(0,1) → at out (0,2)(0,3)(1,2)(1,3) = addr 2,3,6,7
//     for input block(1,0) → at out (2,0)(2,1)(3,0)(3,1) = addr 8,9,12,13
//     for input block(1,1) → at out (2,2)(2,3)(3,2)(3,3) = addr 10,11,14,15
//----------------------------------------------------------------+
`include "user_define_h.v"

module upsample_tb;

    parameter CLK_PERIOD = 10;
    reg clk;
    reg rstn;
    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    // DUT
    reg         start;
    wire        done;
    wire        rd_en;
    wire [15:0] rd_addr;
    reg  [31:0] rd_data;
    wire        wr_en;
    wire [15:0] wr_addr;
    wire [31:0] wr_data;

    upsample_unit u_dut (
        .clk(clk), .rstn(rstn),
        .i_start(start), .o_done(done),
        .i_co_total(12'd2),
        .i_h_blocks(12'd2),
        .i_w_blocks(12'd2),
        .i_in_base (16'd0),
        .i_out_base(16'd8),         // 8 input words → output starts at 8
        .o_rd_en(rd_en), .o_rd_addr(rd_addr), .i_rd_data(rd_data),
        .o_wr_en(wr_en), .o_wr_addr(wr_addr), .o_wr_data(wr_data)
    );

    // 메모리 모델
    reg [31:0] mem [0:127];
    reg [31:0] rd_data_r;

    always @(posedge clk) begin
        if (rd_en) rd_data_r <= mem[rd_addr];
        if (wr_en) mem[wr_addr] <= wr_data;
    end
    always @(*) rd_data = rd_data_r;

    integer i, mismatch;
    reg [31:0] expected;
    reg [7:0]  p;

    initial begin
        rstn  = 1'b0;
        start = 1'b0;
        mismatch = 0;

        for (i = 0; i < 128; i = i + 1) mem[i] = 32'd0;

        // Filter 0 input (4 blocks at addr 0..3)
        mem[0] = {8'd40, 8'd30, 8'd20, 8'd10};   // block(0,0)
        mem[1] = {8'd80, 8'd70, 8'd60, 8'd50};   // block(0,1)
        mem[2] = {8'd140,8'd130,8'd120,8'd110};  // block(1,0)
        mem[3] = {8'd180,8'd170,8'd160,8'd150};  // block(1,1)
        // Filter 1 input — addr 4..7
        mem[4] = {8'd44, 8'd33, 8'd22, 8'd11};
        mem[5] = {8'd88, 8'd77, 8'd66, 8'd55};
        mem[6] = {8'd144,8'd133,8'd122,8'd111};
        mem[7] = {8'd188,8'd177,8'd166,8'd155};

        #(8*CLK_PERIOD) rstn = 1'b1;
        #(4*CLK_PERIOD);

        @(posedge clk);
        start = 1'b1;
        @(posedge clk);
        start = 1'b0;

        $display("[upsample_tb] Started — waiting for done...");
        wait (done == 1'b1);
        #(4*CLK_PERIOD);

        // 검증 — 출력 영역 addr 8..(8+32-1=39)
        //   filter 0 output (addr 8..23): 16 blocks
        //   filter 1 output (addr 24..39): 16 blocks
        check_output(8,  10);   // addr 8 (out_row 0, col 0): p00 = 10
        check_output(9,  20);   // addr 9 (out_row 0, col 1): p01 = 20
        check_output(12, 30);   // addr 12 (out_row 1, col 0): p10 = 30
        check_output(13, 40);   // addr 13 (out_row 1, col 1): p11 = 40
        check_output(10, 50);   // block(0,1): p00 = 50, at out(0,2)
        check_output(11, 60);   // p01 at out(0,3)
        check_output(14, 70);   // p10 at out(1,2)
        check_output(15, 80);   // p11 at out(1,3)
        check_output(16, 110);  // block(1,0): p00 at out(2,0)
        check_output(17, 120);
        check_output(20, 130);
        check_output(21, 140);
        check_output(18, 150);  // block(1,1)
        check_output(19, 160);
        check_output(22, 170);
        check_output(23, 180);
        // filter 1 — addr 24..39 (간단히 spot check)
        check_output(24, 11);
        check_output(39, 188);

        $display("============================================================");
        if (mismatch == 0) $display("[upsample_tb] *** PASSED ***");
        else               $display("[upsample_tb] *** FAILED *** %0d mismatches", mismatch);
        $display("============================================================");
        #(10*CLK_PERIOD) $finish;
    end

    task check_output;
        input integer addr;
        input [7:0]   pix;
        reg [31:0] expect_word;
        begin
            expect_word = {pix, pix, pix, pix};
            if (mem[addr] !== expect_word) begin
                $display("[upsample_tb][MISMATCH] mem[%0d]: got %h, expected %h (pix=%0d)",
                         addr, mem[addr], expect_word, pix);
                mismatch = mismatch + 1;
            end
        end
    endtask

    initial begin
        #(100_000 * CLK_PERIOD);
        $display("[upsample_tb] *** TIMEOUT ***");
        $finish;
    end

endmodule
