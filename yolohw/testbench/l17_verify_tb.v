`timescale 1ns / 1ns
//----------------------------------------------------------------------
// l17_verify_tb.v — L17 (CONV1x1, Ci=256 Co=128, 8×8) 2-단계 검증 TB
//
//   L15 = [yolo] (RTL skip), L16 = [route layers=-4] (L12 OFM alias) →
//   L17 IFM 은 L12 OFM 을 NHWC entry 로 REPACK 한 결과.
//
//   [Phase A] Standalone L17
//     - L17 IFM golden (= L12 OFM = CONV17_input.hex, NCHW byte) 을
//       NHWC entry packed 으로 DRAM L17 IFM 영역에 사전 적재 (software REPACK)
//     - wgt/bias .mem 적재
//     - layer_idx=17, conv_phase_r=17, state_r=S_LOAD_BIAS 강제 진입 → release
//     - L17 conv 단독 실행 → layer_idx=18
//     - DRAM L17 OFM ↔ CONV17_output.hex 비교
//
//   [Phase B] Chain L0 → ... → L17 (RTL L12→L17 REPACK)
//     - 시뮬레이션 리셋 → wgt/bias/ifm .mem 적재 → ap_start=1
//     - 자연 진행 (L0~L14 + L15/L16 skip + L12→L17 RTL REPACK + L17 conv)
//     - DRAM L17 OFM ↔ CONV17_output.hex 비교
//
// DRAM 메모리 맵 (L17):
//   L12 OFM           : 0x00300000 (16KB = 4096 word, conv 2×2 packed)
//   L17 IFM (REPACK)  : 0x0031C000 (16KB = 4096 word, NHWC entry)
//   L17 OFM           : 0x00320000 ( 8KB = 2048 word, conv 2×2 packed)
//----------------------------------------------------------------------
`include "user_define_h.v"

module l17_verify_tb;

`ifdef FPGA
    initial begin
        $display("[L17V-TB][FATAL] FPGA macro enabled.");
        $finish;
    end
`else

    parameter WGT_MEM      = "../../../../../../testbench/inout_data_sw/gen_wgt_dram.mem";
    parameter BIAS_MEM     = "../../../../../../testbench/inout_data_sw/gen_bias_dram.mem";
    parameter IFM_MEM      = "../../../../../../testbench/inout_data_sw/gen_ifm_dram.mem";
    parameter L17_IFM_HEX  = "../../../../../../testbench/inout_data_sw/log_feamap/CONV17_input.hex";
    parameter L17_OFM_HEX  = "../../../../../../testbench/inout_data_sw/log_feamap/CONV17_output.hex";

    parameter CLK_PERIOD = 10;
    reg clk, rstn;
    initial begin clk = 1'b0; forever #(CLK_PERIOD/2) clk = ~clk; end

    localparam integer DRAM_WORDS       = 4 * 1024 * 1024;
    localparam integer WGT_TOTAL_WORDS  = 2_577_152;
    localparam integer BIAS_WORD_BASE   = 32'h00A00000 >> 2;
    localparam integer BIAS_TOTAL_WORDS = 2_294;
    localparam integer IFM_WORD_BASE    = 32'h00B00000 >> 2;
    localparam integer IFM_TOTAL_WORDS  = 65_536;
    localparam integer OFM_WORD_BASE    = 32'h00C00000 >> 2;
    localparam integer L17_IFM_OFF_W    = 32'h0031C000 >> 2;
    localparam integer L17_OFM_OFF_W    = 32'h00320000 >> 2;

    // |got-exp| <= TOLERANCE 인 mismatch 는 양자화 noise 로 간주 (PASS).
    localparam integer TOLERANCE        = 1;

    wire [3:0]  S_AWADDR  = 4'd0;  wire [2:0] S_AWPROT = 3'd0;
    wire        S_AWVALID = 1'b0;  wire       S_AWREADY;
    wire [31:0] S_WDATA   = 32'd0; wire [3:0] S_WSTRB  = 4'd0;
    wire        S_WVALID  = 1'b0;  wire       S_WREADY;
    wire [1:0]  S_BRESP;           wire       S_BVALID;
    wire        S_BREADY  = 1'b1;
    wire [3:0]  S_ARADDR  = 4'd0;  wire [2:0] S_ARPROT = 3'd0;
    wire        S_ARVALID = 1'b0;  wire       S_ARREADY;
    wire [31:0] S_RDATA;           wire [1:0] S_RRESP;
    wire        S_RVALID;          wire       S_RREADY = 1'b1;

    wire        M_ARVALID, M_ARREADY;
    wire [31:0] M_ARADDR;
    wire [3:0]  M_ARID;     wire [7:0] M_ARLEN;
    wire [2:0]  M_ARSIZE;   wire [1:0] M_ARBURST, M_ARLOCK;
    wire [3:0]  M_ARCACHE;  wire [2:0] M_ARPROT;
    wire [3:0]  M_ARQOS, M_ARREGION, M_ARUSER;
    wire        M_RVALID, M_RREADY, M_RLAST;
    wire [31:0] M_RDATA;
    wire [3:0]  M_RID, M_RUSER;   wire [1:0] M_RRESP;
    wire        M_AWVALID, M_AWREADY;
    wire [31:0] M_AWADDR;
    wire [3:0]  M_AWID;     wire [7:0] M_AWLEN;
    wire [2:0]  M_AWSIZE;   wire [1:0] M_AWBURST, M_AWLOCK;
    wire [3:0]  M_AWCACHE;  wire [2:0] M_AWPROT;
    wire [3:0]  M_AWQOS, M_AWREGION, M_AWUSER;
    wire        M_WVALID, M_WREADY, M_WLAST;
    wire [31:0] M_WDATA;
    wire [3:0]  M_WSTRB, M_WID, M_WUSER;
    wire        M_BVALID, M_BREADY;
    wire [1:0]  M_BRESP;     wire [3:0] M_BID;   wire M_BUSER;
    wire        network_done, network_done_led;

    yolo_engine #(
        .C_S_AXI_DATA_WIDTH(32), .C_S_AXI_ADDR_WIDTH(4),
        .AXI_M_WIDTH_AD(32),     .AXI_M_WIDTH_DA(32), .AXI_M_WIDTH_ID(4)
    ) u_yolo_engine (
        .clk(clk), .rstn(rstn),
        .S_AXI_AWADDR(S_AWADDR), .S_AXI_AWPROT(S_AWPROT),
        .S_AXI_AWVALID(S_AWVALID), .S_AXI_AWREADY(S_AWREADY),
        .S_AXI_WDATA(S_WDATA), .S_AXI_WSTRB(S_WSTRB),
        .S_AXI_WVALID(S_WVALID), .S_AXI_WREADY(S_WREADY),
        .S_AXI_BRESP(S_BRESP), .S_AXI_BVALID(S_BVALID),
        .S_AXI_BREADY(S_BREADY),
        .S_AXI_ARADDR(S_ARADDR), .S_AXI_ARPROT(S_ARPROT),
        .S_AXI_ARVALID(S_ARVALID), .S_AXI_ARREADY(S_ARREADY),
        .S_AXI_RDATA(S_RDATA), .S_AXI_RRESP(S_RRESP),
        .S_AXI_RVALID(S_RVALID), .S_AXI_RREADY(S_RREADY),
        .M_ARVALID(M_ARVALID), .M_ARREADY(M_ARREADY), .M_ARADDR(M_ARADDR),
        .M_ARID(M_ARID), .M_ARLEN(M_ARLEN), .M_ARSIZE(M_ARSIZE),
        .M_ARBURST(M_ARBURST), .M_ARLOCK(M_ARLOCK), .M_ARCACHE(M_ARCACHE),
        .M_ARPROT(M_ARPROT), .M_ARQOS(M_ARQOS), .M_ARREGION(M_ARREGION),
        .M_ARUSER(M_ARUSER),
        .M_RVALID(M_RVALID), .M_RREADY(M_RREADY), .M_RDATA(M_RDATA),
        .M_RLAST(M_RLAST), .M_RID(M_RID), .M_RUSER(M_RUSER), .M_RRESP(M_RRESP),
        .M_AWVALID(M_AWVALID), .M_AWREADY(M_AWREADY), .M_AWADDR(M_AWADDR),
        .M_AWID(M_AWID), .M_AWLEN(M_AWLEN), .M_AWSIZE(M_AWSIZE),
        .M_AWBURST(M_AWBURST), .M_AWLOCK(M_AWLOCK), .M_AWCACHE(M_AWCACHE),
        .M_AWPROT(M_AWPROT), .M_AWQOS(M_AWQOS), .M_AWREGION(M_AWREGION),
        .M_AWUSER(M_AWUSER),
        .M_WVALID(M_WVALID), .M_WREADY(M_WREADY), .M_WDATA(M_WDATA),
        .M_WSTRB(M_WSTRB), .M_WLAST(M_WLAST), .M_WID(M_WID), .M_WUSER(M_WUSER),
        .M_BVALID(M_BVALID), .M_BREADY(M_BREADY), .M_BRESP(M_BRESP),
        .M_BID(M_BID), .M_BUSER(M_BUSER),
        .o_network_done(network_done),
        .network_done_led(network_done_led)
    );
    /* verilator lint_off UNUSED */
    wire _unused = network_done | network_done_led;
    /* verilator lint_on UNUSED */

    reg [31:0] dram [0:DRAM_WORDS-1];

    reg        rd_busy_r;
    reg [31:0] rd_addr_r;
    reg [7:0]  rd_beat_r, rd_len_r;
    reg [3:0]  rd_id_r;
    assign M_ARREADY = !rd_busy_r;
    assign M_RVALID  = rd_busy_r;
    assign M_RDATA   = rd_busy_r ? dram[rd_addr_r[23:2]] : 32'd0;
    assign M_RLAST   = rd_busy_r && (rd_beat_r == rd_len_r);
    assign M_RID = rd_id_r; assign M_RUSER = 4'd0; assign M_RRESP = 2'b00;
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin rd_busy_r<=0; rd_addr_r<=0; rd_beat_r<=0; rd_len_r<=0; rd_id_r<=0; end
        else if (!rd_busy_r) begin
            if (M_ARVALID) begin
                rd_busy_r<=1; rd_addr_r<=M_ARADDR; rd_len_r<=M_ARLEN; rd_beat_r<=0; rd_id_r<=M_ARID;
            end
        end else if (M_RREADY) begin
            if (rd_beat_r==rd_len_r) rd_busy_r<=0;
            else begin rd_addr_r<=rd_addr_r+32'd4; rd_beat_r<=rd_beat_r+8'd1; end
        end
    end

    reg        wr_addr_busy_r, wr_data_busy_r, wr_resp_pending_r;
    reg [31:0] wr_addr_r;
    reg [7:0]  wr_beat_r, wr_len_r;
    reg [3:0]  wr_id_r;
    assign M_AWREADY = !wr_addr_busy_r;
    assign M_WREADY  = wr_data_busy_r;
    assign M_BVALID  = wr_resp_pending_r;
    assign M_BRESP=2'b00; assign M_BID=wr_id_r; assign M_BUSER=1'b0;
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            wr_addr_busy_r<=0; wr_data_busy_r<=0; wr_resp_pending_r<=0;
            wr_addr_r<=0; wr_beat_r<=0; wr_len_r<=0; wr_id_r<=0;
        end else begin
            if (!wr_addr_busy_r && M_AWVALID) begin
                wr_addr_busy_r<=1; wr_data_busy_r<=1;
                wr_addr_r<=M_AWADDR; wr_len_r<=M_AWLEN; wr_beat_r<=0; wr_id_r<=M_AWID;
            end
            if (wr_data_busy_r && M_WVALID) begin
                dram[wr_addr_r[23:2]] <= M_WDATA;
                if (M_WLAST) begin
                    wr_data_busy_r<=0; wr_addr_busy_r<=0; wr_resp_pending_r<=1;
                end else begin
                    wr_addr_r<=wr_addr_r+32'd4; wr_beat_r<=wr_beat_r+8'd1;
                end
            end
            if (wr_resp_pending_r && M_BREADY) wr_resp_pending_r<=0;
        end
    end

    // Golden buffers
    reg [7:0] golden_l17_ifm [0:16383];  // 256 × 8 × 8 (L17 input = L12 OFM, NCHW)
    reg [7:0] golden_l17_ofm [0: 8191];  // 128 × 8 × 8 (L17 OFM, NCHW)

    integer mm_l17_A, mm_l17_B;   // phase 별 total mismatch
    integer tf_l17_A, tf_l17_B;   // phase 별 |delta| > TOLERANCE mismatch

    task dram_zero;
        integer t_i;
        begin
            for (t_i = 0; t_i < DRAM_WORDS; t_i = t_i + 1) dram[t_i] = 32'd0;
        end
    endtask

    task load_dram_inputs;
        begin
            $display("[L17V-TB] Loading WGT  : %s", WGT_MEM);
            $readmemh(WGT_MEM,  dram, 0,              WGT_TOTAL_WORDS - 1);
            $display("[L17V-TB] Loading BIAS : %s", BIAS_MEM);
            $readmemh(BIAS_MEM, dram, BIAS_WORD_BASE, BIAS_WORD_BASE + BIAS_TOTAL_WORDS - 1);
            $display("[L17V-TB] Loading IFM  : %s (L0 IFM)", IFM_MEM);
            $readmemh(IFM_MEM,  dram, IFM_WORD_BASE,  IFM_WORD_BASE  + IFM_TOTAL_WORDS  - 1);
        end
    endtask

    task load_goldens;
        begin
            $display("[L17V-TB] Loading L17 IFM golden : %s", L17_IFM_HEX);
            $readmemh(L17_IFM_HEX, golden_l17_ifm);
            $display("[L17V-TB] Loading L17 OFM golden : %s", L17_OFM_HEX);
            $readmemh(L17_OFM_HEX, golden_l17_ofm);
        end
    endtask

    // [Phase A] Software REPACK: golden_l17_ifm (NCHW byte, 16384) → DRAM L17 IFM (NHWC entry)
    //   L13 REPACK 와 동일 식 (Ci=256, ci_g 0..63, col_b 0..1, row 0..7)
    //   entry @ (row, ci_g, col_b) byte (col_l*4 + ch_l) =
    //       golden_l17_ifm[(ci_g*4 + ch_l)*64 + row*8 + (col_b*4 + col_l)]
    //   DRAM word addr = OFM_WORD_BASE + L17_IFM_OFF_W +
    //                    (row*128 + ci_g*2 + col_b)*4 + word_in_entry
    task software_repack_l17_ifm;
        integer t_row, t_cig, t_cb, t_col_l, t_ch_l;
        integer t_addr_w, t_word_idx;
        reg [7:0] tb [0:15];
        reg [31:0] tword;
        begin
            $display("[L17V-TB] Software REPACK : L17 IFM (NHWC entry packing, 4096 word)...");
            for (t_row = 0; t_row < 8; t_row = t_row + 1) begin
                for (t_cig = 0; t_cig < 64; t_cig = t_cig + 1) begin
                    for (t_cb = 0; t_cb < 2; t_cb = t_cb + 1) begin
                        for (t_col_l = 0; t_col_l < 4; t_col_l = t_col_l + 1) begin
                            for (t_ch_l = 0; t_ch_l < 4; t_ch_l = t_ch_l + 1) begin
                                tb[t_col_l*4 + t_ch_l] =
                                    golden_l17_ifm[(t_cig*4+t_ch_l)*64 + t_row*8 + (t_cb*4+t_col_l)];
                            end
                        end
                        for (t_word_idx = 0; t_word_idx < 4; t_word_idx = t_word_idx + 1) begin
                            tword = {tb[t_word_idx*4 + 3], tb[t_word_idx*4 + 2],
                                     tb[t_word_idx*4 + 1], tb[t_word_idx*4 + 0]};
                            t_addr_w = OFM_WORD_BASE + L17_IFM_OFF_W +
                                       (t_row*128 + t_cig*2 + t_cb)*4 + t_word_idx;
                            dram[t_addr_w] = tword;
                        end
                    end
                end
            end
            $display("[L17V-TB] Software REPACK complete (4096 word at L17 IFM region)");
        end
    endtask

    // L17 OFM 비교 + Δ magnitude 분포
    //   L17 OFM 형식 = conv 2×2 packed
    //   word @ (fi, h_block, w_block) = pix_11 pix_10 pix_01 pix_00 (4 byte)
    //   DRAM word addr = OFM_WORD_BASE + L17_OFM_OFF_W + fi*16 + h_block*4 + w_block
    task compare_l17_ofm;
        output integer mismatch_cnt;   // total byte mismatch (got !== exp)
        output integer tol_fail_cnt;   // |delta| > TOLERANCE mismatch
        integer t_fi, t_hb, t_wb, t_sh, t_sw, t_idx, t_print;
        integer diff_signed, abs_diff;
        integer cnt_d1, cnt_d2, cnt_d3, cnt_d4_8, cnt_d_big;
        integer cnt_pos, cnt_neg;
        integer max_diff;
        reg [31:0] tw;
        reg [7:0]  tg, te;
        begin
            mismatch_cnt = 0;
            tol_fail_cnt = 0;
            t_print      = 0;
            cnt_d1 = 0; cnt_d2 = 0; cnt_d3 = 0;
            cnt_d4_8 = 0; cnt_d_big = 0;
            cnt_pos = 0; cnt_neg = 0;
            max_diff = 0;
            for (t_fi = 0; t_fi < 128; t_fi = t_fi + 1) begin
                for (t_hb = 0; t_hb < 4; t_hb = t_hb + 1) begin
                    for (t_wb = 0; t_wb < 4; t_wb = t_wb + 1) begin
                        tw = dram[OFM_WORD_BASE + L17_OFM_OFF_W + t_fi*16 + t_hb*4 + t_wb];
                        for (t_sh = 0; t_sh < 2; t_sh = t_sh + 1) begin
                            for (t_sw = 0; t_sw < 2; t_sw = t_sw + 1) begin
                                t_idx = t_sh*2 + t_sw;
                                tg = tw[t_idx*8 +: 8];
                                te = golden_l17_ofm[t_fi*64 + (t_hb*2+t_sh)*8 + (t_wb*2+t_sw)];
                                if (tg !== te) begin
                                    mismatch_cnt = mismatch_cnt + 1;
                                    diff_signed = $signed({1'b0, tg}) - $signed({1'b0, te});
                                    abs_diff    = (diff_signed < 0) ? -diff_signed : diff_signed;
                                    if (diff_signed > 0) cnt_pos = cnt_pos + 1;
                                    else                 cnt_neg = cnt_neg + 1;
                                    if (abs_diff > max_diff) max_diff = abs_diff;
                                    if      (abs_diff == 1) cnt_d1   = cnt_d1   + 1;
                                    else if (abs_diff == 2) cnt_d2   = cnt_d2   + 1;
                                    else if (abs_diff == 3) cnt_d3   = cnt_d3   + 1;
                                    else if (abs_diff <= 8) cnt_d4_8 = cnt_d4_8 + 1;
                                    else                    cnt_d_big= cnt_d_big+ 1;
                                    if (abs_diff > TOLERANCE) tol_fail_cnt = tol_fail_cnt + 1;
                                    if (t_print < 8) begin
                                        $display("  [L17V-TB] MISMATCH fi=%0d h=%0d w=%0d got=%02x exp=%02x (d=%0d)",
                                                 t_fi, t_hb*2+t_sh, t_wb*2+t_sw, tg, te, diff_signed);
                                        t_print = t_print + 1;
                                    end
                                end
                            end
                        end
                    end
                end
            end
            $display("[L17V-TB] delta dist : total=%0d  +d=%0d  -d=%0d  max|d|=%0d",
                     mismatch_cnt, cnt_pos, cnt_neg, max_diff);
            $display("[L17V-TB]   |d|=1    : %0d  (%0d%%)",
                     cnt_d1, (cnt_d1*100)/((mismatch_cnt==0)?1:mismatch_cnt));
            $display("[L17V-TB]   |d|=2    : %0d", cnt_d2);
            $display("[L17V-TB]   |d|=3    : %0d", cnt_d3);
            $display("[L17V-TB]   |d|=4..8 : %0d", cnt_d4_8);
            $display("[L17V-TB]   |d|>8    : %0d", cnt_d_big);
            $display("[L17V-TB]   |d|>%0d (tol-exceed) : %0d", TOLERANCE, tol_fail_cnt);
        end
    endtask

    //----------------------------------------------------------------
    // Main
    //----------------------------------------------------------------
    initial begin
        rstn = 1'b0;
        dram_zero;
        load_goldens;

        //==================================================================
        // [Phase A] Standalone L17
        //==================================================================
        $display("");
        $display("[L17V-TB] ============== Phase A : Standalone L17 ==============");

        load_dram_inputs;
        software_repack_l17_ifm;

        force u_yolo_engine.u_axi.slv_reg1 = 32'h0000_0000;
        force u_yolo_engine.u_axi.slv_reg2 = 32'h00B0_0000;
        force u_yolo_engine.u_axi.slv_reg3 = 32'h00C0_0000;

        #(8*CLK_PERIOD) rstn = 1'b1;
        #(4*CLK_PERIOD);

        @(posedge clk);
        force u_yolo_engine.layer_idx    = 5'd17;
        force u_yolo_engine.conv_phase_r = 5'd17;
        force u_yolo_engine.fi_r         = 12'd0;
        force u_yolo_engine.rb_r         = 12'd0;
        force u_yolo_engine.state_r      = 6'd1;        // S_LOAD_BIAS
        $display("[L17V-TB][%0t] Phase A : force layer_idx=17 conv_phase=17 state=S_LOAD_BIAS", $time);
        @(posedge clk);
        release u_yolo_engine.layer_idx;
        release u_yolo_engine.conv_phase_r;
        release u_yolo_engine.fi_r;
        release u_yolo_engine.rb_r;
        release u_yolo_engine.state_r;

        wait (u_yolo_engine.layer_idx == 5'd18);
        $display("[L17V-TB][%0t] Phase A : L17 COMPLETED (layer_idx -> 18)", $time);
        #(40*CLK_PERIOD);

        compare_l17_ofm(mm_l17_A, tf_l17_A);
        $display("[L17V-TB][Phase A] OFM mismatch: %0d / 8192   (tol-exceed: %0d)", mm_l17_A, tf_l17_A);
        if      (mm_l17_A == 0) $display("[L17V-TB][Phase A] *** PASS (exact, 0 mismatches) ***");
        else if (tf_l17_A == 0) $display("[L17V-TB][Phase A] *** PASS (within tolerance +-%0d, %0d noise) ***", TOLERANCE, mm_l17_A);
        else                    $display("[L17V-TB][Phase A] *** FAIL (%0d exceed +-%0d tolerance) ***", tf_l17_A, TOLERANCE);

        //==================================================================
        // [Phase B] Chain L0 → ... → L17 (L15 yolo + L16 route -4 skip)
        //==================================================================
        $display("");
        $display("[L17V-TB] ============== Phase B : Chain L0 -> ... -> L17 ==============");

        rstn = 1'b0;
        #(8*CLK_PERIOD);
        dram_zero;
        load_dram_inputs;

        force u_yolo_engine.u_axi.slv_reg1 = 32'h0000_0000;
        force u_yolo_engine.u_axi.slv_reg2 = 32'h00B0_0000;
        force u_yolo_engine.u_axi.slv_reg3 = 32'h00C0_0000;

        #(4*CLK_PERIOD) rstn = 1'b1;
        #(4*CLK_PERIOD);

        @(posedge clk);
        force u_yolo_engine.u_axi.slv_reg0 = 32'd1;
        $display("[L17V-TB][%0t] Phase B : ap_start = 1", $time);
        @(posedge clk); @(posedge clk);
        force u_yolo_engine.u_axi.slv_reg0 = 32'd0;

        wait (u_yolo_engine.layer_idx == 5'd18);
        $display("[L17V-TB][%0t] Phase B : L0 -> ... -> L17 ALL COMPLETED", $time);
        #(40*CLK_PERIOD);

        compare_l17_ofm(mm_l17_B, tf_l17_B);
        $display("[L17V-TB][Phase B] OFM mismatch: %0d / 8192   (tol-exceed: %0d)", mm_l17_B, tf_l17_B);
        if      (mm_l17_B == 0) $display("[L17V-TB][Phase B] *** PASS (exact, 0 mismatches) ***");
        else if (tf_l17_B == 0) $display("[L17V-TB][Phase B] *** PASS (within tolerance +-%0d, %0d noise) ***", TOLERANCE, mm_l17_B);
        else                    $display("[L17V-TB][Phase B] *** FAIL (%0d exceed +-%0d tolerance) ***", tf_l17_B, TOLERANCE);

        $display("");
        $display("[L17V-TB] ============================================================");
        $display("[L17V-TB] Phase A : %s (mismatch=%0d, tol-exceed=%0d)",
                 (tf_l17_A == 0) ? "PASS" : "FAIL", mm_l17_A, tf_l17_A);
        $display("[L17V-TB] Phase B : %s (mismatch=%0d, tol-exceed=%0d)",
                 (tf_l17_B == 0) ? "PASS" : "FAIL", mm_l17_B, tf_l17_B);
        $display("[L17V-TB] ============================================================");

        #(20*CLK_PERIOD) $finish;
    end

    initial begin
        repeat(500_000) #(1_000_000);
        $display("[L17V-TB] *** TIMEOUT ***");
        $finish;
    end

    reg [4:0] prev_li;
    initial prev_li = 5'h1F;
    always @(posedge clk) begin
        if (rstn && u_yolo_engine.layer_idx !== prev_li) begin
            $display("[L17V-TB][%0t] >>> layer_idx %0d -> %0d <<<",
                     $time, prev_li, u_yolo_engine.layer_idx);
            prev_li <= u_yolo_engine.layer_idx;
        end
    end

`endif

endmodule
