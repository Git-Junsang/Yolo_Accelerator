`timescale 1ns / 1ns
//----------------------------------------------------------------------
// l10_verify_tb.v — L10 (CONV3x3 Ci=256 Co=512 8×8) 2-단계 통합 검증 TB
//
//   [Phase A] Standalone L10
//     - L10 IFM (CONV10_input.hex) 을 NHWC packed 으로 DRAM L10 IFM 영역 사전 적재
//     - wgt/bias .mem 적재
//     - layer_idx=10, conv_phase_r=10, state_r=S_LOAD_BIAS (=1) 강제 진입 → release
//     - L10 conv 만 단독 실행 → layer_idx=11
//     - DRAM L10 OFM ↔ CONV10_output.hex 비교
//
//   [Phase B] Chain L0 → ... → L10
//     - 시뮬레이션 리셋 → wgt/bias/ifm .mem 적재 → ap_start=1
//     - 자연 진행 (각 layer 검증 다 통과한 streaming 엔진)
//     - DRAM L10 OFM ↔ CONV10_output.hex 비교
//
// DRAM 메모리 맵 (요점):
//   L9  OFM           : 0x002E0000  (16KB = 256 × 8 × 8 byte-stream)
//   L10 IFM (REPACK)  : 0x002E4000  (16KB = 256 × 8 × 8 NHWC packed)
//   L10 OFM           : 0x002E8000  (32KB = 512 × 8 × 8 conv 2×2 packed)
//----------------------------------------------------------------------
`include "user_define_h.v"

module l10_verify_tb;

`ifdef FPGA
    initial begin
        $display("[L10V-TB][FATAL] FPGA macro enabled.");
        $finish;
    end
`else

    parameter WGT_MEM      = "../../../../../../testbench/inout_data_sw/gen_wgt_dram.mem";
    parameter BIAS_MEM     = "../../../../../../testbench/inout_data_sw/gen_bias_dram.mem";
    parameter IFM_MEM      = "../../../../../../testbench/inout_data_sw/gen_ifm_dram.mem";
    parameter L9_GOLD_HEX  = "../../../../../../testbench/inout_data_sw/log_feamap/CONV10_input.hex";
    parameter L10_GOLD_HEX = "../../../../../../testbench/inout_data_sw/log_feamap/CONV10_output.hex";

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
    localparam integer L10_IFM_OFF_W    = 32'h002E4000 >> 2;
    localparam integer L10_OFM_OFF_W    = 32'h002E8000 >> 2;

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

    // Golden 버퍼
    reg [7:0] golden_l9  [0:16383];   // 256 × 8 × 8 (L9 OFM = L10 IFM)
    reg [7:0] golden_l10 [0:32767];   // 512 × 8 × 8 (L10 OFM)

    integer mm_l10_A, mm_l10_B;

    task dram_zero;
        integer t_i;
        begin
            for (t_i = 0; t_i < DRAM_WORDS; t_i = t_i + 1) dram[t_i] = 32'd0;
        end
    endtask

    task load_dram_inputs;
        begin
            $display("[L10V-TB] Loading WGT  : %s", WGT_MEM);
            $readmemh(WGT_MEM,  dram, 0,              WGT_TOTAL_WORDS - 1);
            $display("[L10V-TB] Loading BIAS : %s", BIAS_MEM);
            $readmemh(BIAS_MEM, dram, BIAS_WORD_BASE, BIAS_WORD_BASE + BIAS_TOTAL_WORDS - 1);
            $display("[L10V-TB] Loading IFM  : %s", IFM_MEM);
            $readmemh(IFM_MEM,  dram, IFM_WORD_BASE,  IFM_WORD_BASE  + IFM_TOTAL_WORDS  - 1);
        end
    endtask

    task load_goldens;
        begin
            $display("[L10V-TB] Loading L9 OFM golden  : %s", L9_GOLD_HEX);
            $readmemh(L9_GOLD_HEX,  golden_l9);
            $display("[L10V-TB] Loading L10 OFM golden : %s", L10_GOLD_HEX);
            $readmemh(L10_GOLD_HEX, golden_l10);
        end
    endtask

    // Phase A: golden_l9 (NCHW byte) → DRAM L10 IFM 영역 (NHWC packed)
    //   per (row, ci_g, col_b) entry = 16 byte = 4 col × 4 ch
    //   L10: 256 ch (= 64 ci_g), 8 rows, W_BLK=2 (col_b 0..1)
    //   byte[col_l*4 + ch_l] = golden_l9[(ci_g*4+ch_l)*64 + row*8 + (col_b*4 + col_l)]
    //   DRAM word addr = OFM_WORD_BASE + L10_IFM_OFF_W + row*512 + ci_g*8 + col_b*4 + col_l
    task preload_l10_ifm;
        integer t_row, t_cig, t_cb, t_cl, t_chl;
        integer t_chfull, t_col, t_addr_w;
        reg [7:0] tb [0:15];
        reg [31:0] tword;
        begin
            $display("[L10V-TB] Pre-loading DRAM L10 IFM region (NHWC packed, 4,096 word)...");
            for (t_row = 0; t_row < 8; t_row = t_row + 1) begin
                for (t_cig = 0; t_cig < 64; t_cig = t_cig + 1) begin
                    for (t_cb = 0; t_cb < 2; t_cb = t_cb + 1) begin
                        for (t_cl = 0; t_cl < 4; t_cl = t_cl + 1) begin
                            for (t_chl = 0; t_chl < 4; t_chl = t_chl + 1) begin
                                t_chfull = t_cig*4 + t_chl;
                                t_col    = t_cb*4 + t_cl;
                                tb[t_cl*4 + t_chl] = golden_l9[t_chfull*64 + t_row*8 + t_col];
                            end
                        end
                        for (t_cl = 0; t_cl < 4; t_cl = t_cl + 1) begin
                            tword = {tb[t_cl*4 + 3], tb[t_cl*4 + 2],
                                     tb[t_cl*4 + 1], tb[t_cl*4 + 0]};
                            t_addr_w = OFM_WORD_BASE + L10_IFM_OFF_W + t_row*512 + t_cig*8 + t_cb*4 + t_cl;
                            dram[t_addr_w] = tword;
                        end
                    end
                end
            end
        end
    endtask

    // L10 OFM 비교 + Δ magnitude 분포 통계
    task compare_l10_ofm;
        output integer mismatch_cnt;
        integer t_fi, t_hb, t_wb, t_sh, t_sw, t_idx, t_print;
        integer diff_signed, abs_diff;
        integer cnt_d1, cnt_d2, cnt_d3, cnt_d4_8, cnt_d_big;
        integer cnt_pos, cnt_neg;
        integer max_diff;
        reg [31:0] tw;
        reg [7:0]  tg, te;
        begin
            mismatch_cnt = 0;
            t_print      = 0;
            cnt_d1 = 0; cnt_d2 = 0; cnt_d3 = 0;
            cnt_d4_8 = 0; cnt_d_big = 0;
            cnt_pos = 0; cnt_neg = 0;
            max_diff = 0;
            for (t_fi = 0; t_fi < 512; t_fi = t_fi + 1) begin
                for (t_hb = 0; t_hb < 4; t_hb = t_hb + 1) begin
                    for (t_wb = 0; t_wb < 4; t_wb = t_wb + 1) begin
                        tw = dram[OFM_WORD_BASE + L10_OFM_OFF_W + t_fi*16 + t_hb*4 + t_wb];
                        for (t_sh = 0; t_sh < 2; t_sh = t_sh + 1) begin
                            for (t_sw = 0; t_sw < 2; t_sw = t_sw + 1) begin
                                t_idx = t_sh*2 + t_sw;
                                tg = tw[t_idx*8 +: 8];
                                te = golden_l10[t_fi*64 + (t_hb*2+t_sh)*8 + (t_wb*2+t_sw)];
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
                                    if (t_print < 8) begin
                                        $display("  [L10 MISMATCH] fi=%0d h=%0d w=%0d got=%02x exp=%02x (d=%0d)",
                                                 t_fi, t_hb*2+t_sh, t_wb*2+t_sw, tg, te, diff_signed);
                                        t_print = t_print + 1;
                                    end
                                    // |Δ| > 3 인 첫 16개는 별도 print (실제 RTL 버그 진단용)
                                    if (abs_diff > 3 && cnt_d4_8 + cnt_d_big <= 16) begin
                                        $display("  [L10 MISMATCH BIG-Δ] fi=%0d h=%0d w=%0d got=%02x exp=%02x (d=%0d)",
                                                 t_fi, t_hb*2+t_sh, t_wb*2+t_sw, tg, te, diff_signed);
                                    end
                                end
                            end
                        end
                    end
                end
            end
            // Δ magnitude 분포
            $display("[L10V-TB] Δ 분포 — total=%0d, +Δ=%0d, -Δ=%0d, max|Δ|=%0d",
                     mismatch_cnt, cnt_pos, cnt_neg, max_diff);
            $display("[L10V-TB]   |Δ|=1 : %0d   (%0d%%)",
                     cnt_d1, (cnt_d1*100)/((mismatch_cnt==0)?1:mismatch_cnt));
            $display("[L10V-TB]   |Δ|=2 : %0d", cnt_d2);
            $display("[L10V-TB]   |Δ|=3 : %0d", cnt_d3);
            $display("[L10V-TB]   |Δ|=4..8 : %0d", cnt_d4_8);
            $display("[L10V-TB]   |Δ|>8 : %0d", cnt_d_big);
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
        // [Phase A] Standalone L10
        //==================================================================
        $display("");
        $display("[L10V-TB] ============== Phase A : Standalone L10 ==============");

        load_dram_inputs;       // wgt/bias .mem
        preload_l10_ifm;        // L10 IFM = NHWC packed CONV10_input.hex

        force u_yolo_engine.u_axi.slv_reg1 = 32'h0000_0000;
        force u_yolo_engine.u_axi.slv_reg2 = 32'h00B0_0000;
        force u_yolo_engine.u_axi.slv_reg3 = 32'h00C0_0000;

        #(8*CLK_PERIOD) rstn = 1'b1;
        #(4*CLK_PERIOD);

        @(posedge clk);
        force u_yolo_engine.layer_idx    = 5'd10;
        force u_yolo_engine.conv_phase_r = 5'd10;
        force u_yolo_engine.fi_r         = 12'd0;
        force u_yolo_engine.rb_r         = 12'd0;
        force u_yolo_engine.state_r      = 5'd1;        // S_LOAD_BIAS
        $display("[L10V-TB][%0t] Phase A : force layer_idx=10 conv_phase=10 state=S_LOAD_BIAS", $time);
        @(posedge clk);
        release u_yolo_engine.layer_idx;
        release u_yolo_engine.conv_phase_r;
        release u_yolo_engine.fi_r;
        release u_yolo_engine.rb_r;
        release u_yolo_engine.state_r;

        wait (u_yolo_engine.layer_idx == 5'd11);
        $display("[L10V-TB][%0t] Phase A : L10 COMPLETED (layer_idx → 11)", $time);
        #(40*CLK_PERIOD);

        compare_l10_ofm(mm_l10_A);
        $display("[L10V-TB][Phase A] L10 OFM mismatch: %0d / 32,768", mm_l10_A);
        if (mm_l10_A == 0) $display("[L10V-TB][Phase A] *** PASS *** : L10 conv 단독 OK");
        else               $display("[L10V-TB][Phase A] *** FAIL ***");

        //==================================================================
        // [Phase B] Chain L0 → ... → L10
        //==================================================================
        $display("");
        $display("[L10V-TB] ============== Phase B : Chain L0 → ... → L10 ==============");

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
        $display("[L10V-TB][%0t] Phase B : ap_start = 1", $time);
        @(posedge clk); @(posedge clk);
        force u_yolo_engine.u_axi.slv_reg0 = 32'd0;

        wait (u_yolo_engine.layer_idx == 5'd11);
        $display("[L10V-TB][%0t] Phase B : L0→...→L10 ALL COMPLETED", $time);
        #(40*CLK_PERIOD);

        compare_l10_ofm(mm_l10_B);
        $display("[L10V-TB][Phase B] L10 OFM mismatch: %0d / 32,768", mm_l10_B);
        if (mm_l10_B == 0) $display("[L10V-TB][Phase B] *** PASS ***");
        else               $display("[L10V-TB][Phase B] *** FAIL *** (또는 propagation 누적)");

        //==================================================================
        $display("");
        $display("[L10V-TB] ============================================================");
        $display("[L10V-TB] Phase A (standalone L10) : %s (mismatch=%0d)",
                 (mm_l10_A == 0) ? "PASS" : "FAIL", mm_l10_A);
        $display("[L10V-TB] Phase B (L0→...→L10)     : %s (mismatch=%0d)",
                 (mm_l10_B == 0) ? "PASS" : "FAIL", mm_l10_B);
        $display("[L10V-TB] ============================================================");

        #(20*CLK_PERIOD) $finish;
    end

    initial begin
        repeat(200_000) #(1_000_000);
        $display("[L10V-TB] *** TIMEOUT ***");
        $finish;
    end

    reg [4:0] prev_li;
    initial prev_li = 5'h1F;
    always @(posedge clk) begin
        if (rstn && u_yolo_engine.layer_idx !== prev_li) begin
            $display("[L10V-TB][%0t] >>> layer_idx %0d → %0d <<<",
                     $time, prev_li, u_yolo_engine.layer_idx);
            prev_li <= u_yolo_engine.layer_idx;
        end
    end

`endif

endmodule
