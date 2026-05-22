`timescale 1ns / 1ns
//----------------------------------------------------------------------
// conv1x1_micro_tb.v — 1×1 conv path standalone 미니 검증
//
// 목적: conv_top + ifm_line_buf 의 1×1 mode (i_mode=1) 가 의도대로 동작하는지,
//   col_idx 와 row_idx 진행 매핑이 어떻게 되는지 직접 측정.
//
// 시나리오 (가장 단순):
//   Ci = 4 (1 ci_group, acc_len = 1)
//   Co = 1
//   H = W = 4
//   kernel = 1×1, stride = 1
//   bias = 0, shift = 0
//   IFM pattern  : 모든 4 channel 동일 값 = (row*W + col + 1)
//   Weight       : 4 channel 모두 1 (sum = 4 × IFM 값)
//   기대 OFM[r,c] = 4 × (row*W + col + 1)  (uint8 clip → 64 이하 모두 그대로)
//
// 측정:
//   - W_HALF = 2, H_HALF = 2 가정 (3×3 mode 와 동일한 OFM block 좌표)
//   - 4 mac_kern 호출 → 4 OFM 2×2 blocks = 16 pixels
//   - conv_top.o_pixel 캡쳐 + col_idx/row_idx 값 같이 dump
//----------------------------------------------------------------------
`include "user_define_h.v"

module conv1x1_micro_tb;

`ifdef FPGA
    initial begin
        $display("[1x1micro][FATAL] FPGA macro enabled.");
        $finish;
    end
`else

    parameter CLK_PERIOD = 10;
    reg clk, rstn;
    initial begin clk = 1'b0; forever #(CLK_PERIOD/2) clk = ~clk; end

    //--------------------------------------------------------------
    // Layer 파라미터
    //--------------------------------------------------------------
    localparam integer CI         = 4;
    localparam integer CO         = 1;
    localparam integer H          = 4;
    localparam integer W          = 4;
    localparam integer W_HALF     = W / 2;     // 2
    localparam integer H_HALF     = H / 2;     // 2
    localparam integer W_BLOCKS   = (W + 3) / 4;  // 1
    localparam integer CI_GROUPS  = (CI + 3) / 4; // 1
    localparam integer ACC_LEN    = CI_GROUPS;    // 1×1 mode: acc_len = ci_groups
    localparam integer SHIFT      = 0;

    //--------------------------------------------------------------
    // IFM data — 4 row × 4 col, 모든 ch 동일 값 = row*W + col + 1
    //
    //   ifm_line_buf entry packing: [127:0] = 4 col × 4 ch (col-outer + ch-inner)
    //     LSB byte = col0_ch0, byte 1 = col0_ch1, ..., byte 15 = col3_ch3
    //   한 row 의 entry 수 = W_BLOCKS = 1
    //   line buffer 의 row 인덱스 = IFM row mod 4
    //--------------------------------------------------------------

    //--------------------------------------------------------------
    // Weight — Co=1 filter, Ci=4 ch 모두 1.
    //   1×1 mode 의 mac_stack 입력 [287:0]: ch 0..3 만 valid, ch 4..35 = 0.
    //   wgt 의 byte 0..3 = 1 1 1 1, byte 4..35 = 0
    //   gbuff_param 의 weight entry = 288 bit. acc_cyc=0 의 한 entry.
    //--------------------------------------------------------------

    //--------------------------------------------------------------
    // DUT 연결 wires
    //--------------------------------------------------------------
    reg          start_r;
    wire         done;
    wire         fil_done;

    reg          dma_wgt_we;
    reg  [11:0]  dma_wgt_addr;
    reg  [71:0]  dma_wgt_data;
    reg          dma_bias_we;
    reg  [11:0]  dma_bias_addr;
    reg  [31:0]  dma_bias_data;

    wire         ifm_re;
    wire [11:0]  ifm_row, ifm_col;
    wire [7:0]   ifm_acc;
    wire [287:0] ifm_00, ifm_01, ifm_10, ifm_11;
    wire         ifm_vld;
    wire [31:0]  conv_pixel;
    wire         conv_pixel_vld;
    wire [25:0]  conv_ofm_addr;

    //--------------------------------------------------------------
    // ifm_line_buf instance
    //--------------------------------------------------------------
    reg          lb_wr_en;
    reg  [1:0]   lb_wr_line;
    reg  [10:0]  lb_wr_addr;
    reg  [127:0] lb_wr_data;

    ifm_line_buf u_line_buf (
        .clk(clk), .rstn(rstn),
        .i_mode      (1'b1),                  // 1×1 mode
        .i_w_blocks  (W_BLOCKS[11:0]),
        .i_ci_groups (CI_GROUPS[7:0]),
        .i_w         (W[11:0]),
        .i_h         (H[11:0]),
        .i_line_valid(4'b1111),
        .i_dma_wr_en (lb_wr_en),
        .i_dma_wr_line(lb_wr_line),
        .i_dma_wr_addr(lb_wr_addr),
        .i_dma_wr_data(lb_wr_data),
        .i_rd_en (ifm_re),
        .i_rb    (ifm_row),
        .i_cb    (ifm_col),
        .i_acc_cyc(ifm_acc),
        .o_ifm_00(ifm_00), .o_ifm_01(ifm_01),
        .o_ifm_10(ifm_10), .o_ifm_11(ifm_11),
        .o_vld   (ifm_vld)
    );
    /* verilator lint_off UNUSED */
    wire _unused_vld = ifm_vld;
    /* verilator lint_on UNUSED */

    //--------------------------------------------------------------
    // conv_top instance
    //--------------------------------------------------------------
    conv_top u_conv (
        .clk(clk), .rstn(rstn),
        .i_start(start_r),
        .o_done(done),
        .o_fil_done(fil_done),
        .i_conv_pause(1'b0),
        .i_stream_wgt_mode(1'b0),  // BRAM[0..acc_len-1] 한 번만 적재
        .i_mode(1'b1),             // 1×1 mode
        .i_ofm_w_half(W_HALF[11:0]),
        .i_ofm_h_half(H_HALF[11:0]),
        .i_row_start (12'd0),
        .i_co_total  (CO[11:0]),
        .i_acc_len   (ACC_LEN[7:0]),
        .i_wgt_base  (10'd0),
        .i_bias_base (12'd0),
        .i_shift     (SHIFT[4:0]),
        .dma_wgt_we(dma_wgt_we), .dma_wgt_addr(dma_wgt_addr), .dma_wgt_data(dma_wgt_data),
        .dma_bias_we(dma_bias_we), .dma_bias_addr(dma_bias_addr), .dma_bias_data(dma_bias_data),
        .o_ifm_re(ifm_re), .o_ifm_row(ifm_row), .o_ifm_col(ifm_col), .o_ifm_acc(ifm_acc),
        .i_ifm_00(ifm_00), .i_ifm_01(ifm_01), .i_ifm_10(ifm_10), .i_ifm_11(ifm_11),
        .o_pixel(conv_pixel),
        .o_pixel_vld(conv_pixel_vld),
        .o_ofm_addr(conv_ofm_addr)
    );
    /* verilator lint_off UNUSED */
    wire _unused_fd = fil_done;
    /* verilator lint_on UNUSED */

    //--------------------------------------------------------------
    // OFM 캡쳐
    //--------------------------------------------------------------
    reg [31:0] ofm_capture [0:H_HALF*W_HALF-1];  // 4 word
    integer    ofm_cnt;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) ofm_cnt <= 0;
        else if (conv_pixel_vld) begin
            ofm_capture[ofm_cnt] <= conv_pixel;
            $display("[1x1micro][%0t] OFM[%0d] = %08h  (addr=%0d)",
                     $time, ofm_cnt, conv_pixel, conv_ofm_addr);
            ofm_cnt <= ofm_cnt + 1;
        end
    end

    //--------------------------------------------------------------
    // Read addr / window trace — col_idx, row_idx, acc_cyc 추적
    //--------------------------------------------------------------
    reg [11:0] prev_col, prev_row;
    reg [7:0]  prev_acc;
    initial begin prev_col=12'hFFF; prev_row=12'hFFF; prev_acc=8'hFF; end
    always @(posedge clk) begin
        if (rstn && ifm_re && (ifm_col!==prev_col || ifm_row!==prev_row || ifm_acc!==prev_acc)) begin
            $display("[1x1micro][%0t] conv→buf  row=%0d col=%0d acc=%0d  (ifm_re=%b)",
                     $time, ifm_row, ifm_col, ifm_acc, ifm_re);
            prev_col <= ifm_col; prev_row <= ifm_row; prev_acc <= ifm_acc;
        end
    end

    // window 추출 직후 ifm_00/01/10/11 의 LSB 4 byte 만 (1×1 mode 의 valid 영역)
    always @(posedge clk) begin
        if (rstn && ifm_vld) begin
            $display("[1x1micro][%0t]   ifm_00[31:0]=%08h ifm_01[31:0]=%08h ifm_10[31:0]=%08h ifm_11[31:0]=%08h",
                     $time, ifm_00[31:0], ifm_01[31:0], ifm_10[31:0], ifm_11[31:0]);
        end
    end

    //--------------------------------------------------------------
    // 적재 task — line buffer + weight + bias
    //--------------------------------------------------------------
    task load_ifm;
        integer r, b;
        reg [127:0] entry;
        reg [7:0]   px;
        begin
            // 각 row r 의 entry (W_BLOCKS=1): col 0..3 × ch 0..3.
            //   pixel value = r*W + col + 1, ch 4개 모두 동일.
            // line buffer 의 line index = r mod 4 = r (r=0..3 이라 직접 일치)
            for (r = 0; r < H; r = r + 1) begin
                entry = 128'd0;
                for (b = 0; b < 16; b = b + 1) begin
                    // byte b: col = b/4, ch = b%4
                    px = (r*W + (b/4) + 1) & 8'hFF;
                    entry[b*8 +: 8] = px;
                end
                @(posedge clk);
                lb_wr_en   <= 1'b1;
                lb_wr_line <= r[1:0];
                lb_wr_addr <= 11'd0;     // 한 row 의 entry 0
                lb_wr_data <= entry;
                $display("[1x1micro] LB write row=%0d line=%0d data=%032h", r, r[1:0], entry);
            end
            @(posedge clk);
            lb_wr_en <= 1'b0;
        end
    endtask

    task load_wgt;
        integer wi;
        reg [71:0] w_entry;
        begin
            // System slot packing (gen_sim_dram.py 와 일치):
            //   wgt_mem entry wi = ch wi 의 weight (LSB 1 byte) + 8 byte 0
            //   288-bit read = {entry3, entry2, entry1, entry0}
            //   → wgt[byte 0] = c0_w, wgt[byte 9] = c1_w, wgt[byte 18] = c2_w, wgt[byte 27] = c3_w
            //   ifm_line_buf 의 1×1 packing 도 ch 0..3 ifm 을 동일 byte 위치에 배치 (수정 후)
            //   → mul[0]=c0_w*c0, mul[9]=c1_w*c1, mul[18]=c2_w*c2, mul[27]=c3_w*c3
            for (wi = 0; wi < 4; wi = wi + 1) begin
                w_entry = 72'd0;
                w_entry[7:0] = 8'd1;     // ch wi 의 weight = 1
                @(posedge clk);
                dma_wgt_we   <= 1'b1;
                dma_wgt_addr <= wi[11:0];
                dma_wgt_data <= w_entry;
                $display("[1x1micro] WGT write addr=%0d data=%018h (ch%0d = 1)", wi, w_entry, wi);
            end
            @(posedge clk);
            dma_wgt_we <= 1'b0;
        end
    endtask

    task load_bias;
        begin
            @(posedge clk);
            dma_bias_we   <= 1'b1;
            dma_bias_addr <= 12'd0;
            dma_bias_data <= 32'd0;     // bias = 0
            @(posedge clk);
            dma_bias_we <= 1'b0;
        end
    endtask

    //--------------------------------------------------------------
    // Main
    //--------------------------------------------------------------
    integer i;
    integer expected, got;
    integer mismatch;
    initial begin
        rstn = 0; start_r = 0;
        lb_wr_en = 0; lb_wr_line = 0; lb_wr_addr = 0; lb_wr_data = 0;
        dma_wgt_we = 0; dma_wgt_addr = 0; dma_wgt_data = 0;
        dma_bias_we = 0; dma_bias_addr = 0; dma_bias_data = 0;

        #(8*CLK_PERIOD) rstn = 1;
        #(4*CLK_PERIOD);

        $display("");
        $display("[1x1micro] ==== Load data ====");
        load_ifm;
        load_wgt;
        load_bias;

        $display("");
        $display("[1x1micro] ==== Trigger conv ====");
        @(posedge clk);
        start_r <= 1;
        @(posedge clk);
        start_r <= 0;

        wait (done == 1'b1);
        $display("[1x1micro][%0t] conv DONE", $time);
        #(20*CLK_PERIOD);

        $display("");
        $display("[1x1micro] ==== OFM capture summary ====");
        mismatch = 0;
        for (i = 0; i < H_HALF*W_HALF; i = i + 1) begin
            got = ofm_capture[i];
            // 기대값: OFM 좌표 = (i/W_HALF, i%W_HALF) 가 OFM block coord
            //   block 의 4 픽셀 (2*r..2*r+1, 2*c..2*c+1) 값
            //   각 픽셀 = 4 * (row*W + col + 1) — 4 ch sum
            //   block 좌표 (br, bc) = (i/W_HALF, i%W_HALF)
            //   pix_00 at (2*br, 2*bc)         = 4*(2*br*W + 2*bc + 1)
            //   pix_01 at (2*br, 2*bc+1)       = 4*(2*br*W + 2*bc + 2)
            //   pix_10 at (2*br+1, 2*bc)       = 4*((2*br+1)*W + 2*bc + 1)
            //   pix_11 at (2*br+1, 2*bc+1)     = 4*((2*br+1)*W + 2*bc + 2)
            begin
                integer br, bc, p00, p01, p10, p11;
                br = i / W_HALF;
                bc = i % W_HALF;
                p00 = 4 * (2*br*W     + 2*bc + 1) & 32'hFF;
                p01 = 4 * (2*br*W     + 2*bc + 2) & 32'hFF;
                p10 = 4 * ((2*br+1)*W + 2*bc + 1) & 32'hFF;
                p11 = 4 * ((2*br+1)*W + 2*bc + 2) & 32'hFF;
                expected = (p11 << 24) | (p10 << 16) | (p01 << 8) | p00;
                $display("[1x1micro] OFM[%0d] (br=%0d bc=%0d): got=%08h exp=%08h %s",
                         i, br, bc, got, expected,
                         (got === expected) ? "OK" : "MISMATCH");
                if (got !== expected) mismatch = mismatch + 1;
            end
        end

        $display("");
        $display("[1x1micro] ==== RESULT ====");
        if (mismatch == 0)
            $display("[1x1micro] *** PASS *** (%0d/%0d OFM blocks match)", H_HALF*W_HALF, H_HALF*W_HALF);
        else
            $display("[1x1micro] *** FAIL *** %0d/%0d mismatches", mismatch, H_HALF*W_HALF);

        #(20*CLK_PERIOD) $finish;
    end

    initial begin
        #(10000 * CLK_PERIOD);
        $display("[1x1micro] *** TIMEOUT ***");
        $finish;
    end

`endif

endmodule
