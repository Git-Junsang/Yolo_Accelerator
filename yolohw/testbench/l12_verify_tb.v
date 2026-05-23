`timescale 1ns / 1ns
//----------------------------------------------------------------------
// l12_verify_tb.v — L12 (CONV1x1, Ci=512 Co=256, 8×8) standalone 검증 TB
//
//   [Phase A] Standalone L12 (1×1 mode)
//     - golden L12 IFM = CONV12_input.hex (NCHW byte stream, = L11 OFM)
//     - TB software REPACK: NCHW → NHWC entry (4 col × 4 ch) → DRAM L12 IFM 영역
//     - wgt/bias .mem 적재 (L12 영역 포함)
//     - layer_idx=12, conv_phase_r=12, state_r=S_LOAD_BIAS 강제 진입 → release
//     - L12 conv 단독 실행 → layer_idx=13
//     - DRAM L12 OFM ↔ CONV12_output.hex 비교
//
//   Phase B (chain L0→L11→L12) 는 RTL REPACK (L11 OFM → L12 IFM) 없이는 불가.
//   현 시점에서는 Phase A 만 실시하여 1×1 mode + L12 통합 검증.
//
// DRAM 메모리 맵 (L12 추가):
//   L11 OFM           : 0x002F0000  (32KB, 8192 word)
//   L12 IFM (sw RP)   : 0x002F8000  (32KB = 8 row × 256 entry × 16 byte)
//   L12 OFM           : 0x00300000  (16KB = 256 × 4×4 × 4 byte = 4096 word)
//----------------------------------------------------------------------
`include "user_define_h.v"

module l12_verify_tb;

`ifdef FPGA
    initial begin
        $display("[L12V-TB][FATAL] FPGA macro enabled.");
        $finish;
    end
`else

    parameter WGT_MEM      = "../../../../../../testbench/inout_data_sw/gen_wgt_dram.mem";
    parameter BIAS_MEM     = "../../../../../../testbench/inout_data_sw/gen_bias_dram.mem";
    parameter IFM_MEM      = "../../../../../../testbench/inout_data_sw/gen_ifm_dram.mem";
    parameter L12_IFM_HEX  = "../../../../../../testbench/inout_data_sw/log_feamap/CONV12_input.hex";
    parameter L12_OFM_HEX  = "../../../../../../testbench/inout_data_sw/log_feamap/CONV12_output.hex";

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
    localparam integer L12_IFM_OFF_W    = 32'h002F8000 >> 2;
    localparam integer L12_OFM_OFF_W    = 32'h00300000 >> 2;

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
    reg [7:0] golden_l12_ifm [0:32767];  // 512 × 8 × 8 (L12 input = L11 OFM, NCHW)
    reg [7:0] golden_l12_ofm [0:16383];  // 256 × 8 × 8 (L12 OFM, NCHW)

    integer mm_l12_A, mm_l12_B;   // phase 별 total mismatch
    integer tf_l12_A, tf_l12_B;   // phase 별 |delta| > TOLERANCE mismatch

    task dram_zero;
        integer t_i;
        begin
            for (t_i = 0; t_i < DRAM_WORDS; t_i = t_i + 1) dram[t_i] = 32'd0;
        end
    endtask

    task load_dram_inputs;
        begin
            $display("[L12V-TB] Loading WGT  : %s", WGT_MEM);
            $readmemh(WGT_MEM,  dram, 0,              WGT_TOTAL_WORDS - 1);
            $display("[L12V-TB] Loading BIAS : %s", BIAS_MEM);
            $readmemh(BIAS_MEM, dram, BIAS_WORD_BASE, BIAS_WORD_BASE + BIAS_TOTAL_WORDS - 1);
            $display("[L12V-TB] Loading IFM  : %s (L0 IFM)", IFM_MEM);
            $readmemh(IFM_MEM,  dram, IFM_WORD_BASE,  IFM_WORD_BASE  + IFM_TOTAL_WORDS  - 1);
        end
    endtask

    task load_goldens;
        begin
            $display("[L12V-TB] Loading L12 IFM golden : %s", L12_IFM_HEX);
            $readmemh(L12_IFM_HEX, golden_l12_ifm);
            $display("[L12V-TB] Loading L12 OFM golden : %s", L12_OFM_HEX);
            $readmemh(L12_OFM_HEX, golden_l12_ofm);
        end
    endtask

    // [Phase A] Software REPACK: golden_l12_ifm (NCHW byte) → DRAM L12 IFM (NHWC entry)
    //
    //   L12 IFM 한 entry (16 byte) = 4 col × 4 ch byte-interleaved
    //     byte (col_l*4 + ch_l) = golden_l12_ifm[(ci_g*4+ch_l)*64 + row*8 + (col_b*4+col_l)]
    //   DRAM word addr = OFM_WORD_BASE + L12_IFM_OFF_W +
    //                    (row*256 + ci_g*2 + col_b)*4 + word_in_entry
    //   word_in_entry 0..3 = 한 entry 의 4 word (16 byte / 4 = 4)
    //     word 0 = byte 0..3 (col 0), word 1 = byte 4..7 (col 1), ...
    task software_repack_l12_ifm;
        integer t_row, t_cig, t_cb, t_col_l, t_ch_l;
        integer t_addr_w, t_word_idx;
        reg [7:0] tb [0:15];
        reg [31:0] tword;
        begin
            $display("[L12V-TB] Software REPACK : L12 IFM (NHWC entry packing)...");
            for (t_row = 0; t_row < 8; t_row = t_row + 1) begin
                for (t_cig = 0; t_cig < 128; t_cig = t_cig + 1) begin
                    for (t_cb = 0; t_cb < 2; t_cb = t_cb + 1) begin
                        // 한 entry: 16 byte 채우기
                        for (t_col_l = 0; t_col_l < 4; t_col_l = t_col_l + 1) begin
                            for (t_ch_l = 0; t_ch_l < 4; t_ch_l = t_ch_l + 1) begin
                                tb[t_col_l*4 + t_ch_l] =
                                    golden_l12_ifm[(t_cig*4+t_ch_l)*64 + t_row*8 + (t_cb*4+t_col_l)];
                            end
                        end
                        // 4 word 로 적재 (한 word = 4 byte, little-endian)
                        for (t_word_idx = 0; t_word_idx < 4; t_word_idx = t_word_idx + 1) begin
                            tword = {tb[t_word_idx*4 + 3], tb[t_word_idx*4 + 2],
                                     tb[t_word_idx*4 + 1], tb[t_word_idx*4 + 0]};
                            t_addr_w = OFM_WORD_BASE + L12_IFM_OFF_W +
                                       (t_row*256 + t_cig*2 + t_cb)*4 + t_word_idx;
                            dram[t_addr_w] = tword;
                        end
                    end
                end
            end
            $display("[L12V-TB] Software REPACK complete (8192 word, 32 KB at 0x%08h)",
                     32'h00C00000 + 32'h002F8000);
        end
    endtask

    // L12 OFM 비교 + Δ magnitude 분포
    //   L12 OFM 형식 = conv 2×2 packed (L10 와 동일)
    //   word @ (fi, h_block, w_block) = (pix_11, pix_10, pix_01, pix_00)
    //   DRAM word addr = OFM_WORD_BASE + L12_OFM_OFF_W + fi*16 + h_block*4 + w_block
    task compare_l12_ofm;
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
            for (t_fi = 0; t_fi < 256; t_fi = t_fi + 1) begin
                for (t_hb = 0; t_hb < 4; t_hb = t_hb + 1) begin
                    for (t_wb = 0; t_wb < 4; t_wb = t_wb + 1) begin
                        tw = dram[OFM_WORD_BASE + L12_OFM_OFF_W + t_fi*16 + t_hb*4 + t_wb];
                        for (t_sh = 0; t_sh < 2; t_sh = t_sh + 1) begin
                            for (t_sw = 0; t_sw < 2; t_sw = t_sw + 1) begin
                                t_idx = t_sh*2 + t_sw;
                                tg = tw[t_idx*8 +: 8];
                                te = golden_l12_ofm[t_fi*64 + (t_hb*2+t_sh)*8 + (t_wb*2+t_sw)];
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
                                        $display("  [L12V-TB] MISMATCH fi=%0d h=%0d w=%0d got=%02x exp=%02x (d=%0d)",
                                                 t_fi, t_hb*2+t_sh, t_wb*2+t_sw, tg, te, diff_signed);
                                        t_print = t_print + 1;
                                    end
                                end
                            end
                        end
                    end
                end
            end
            $display("[L12V-TB] delta dist : total=%0d  +d=%0d  -d=%0d  max|d|=%0d",
                     mismatch_cnt, cnt_pos, cnt_neg, max_diff);
            $display("[L12V-TB]   |d|=1    : %0d  (%0d%%)",
                     cnt_d1, (cnt_d1*100)/((mismatch_cnt==0)?1:mismatch_cnt));
            $display("[L12V-TB]   |d|=2    : %0d", cnt_d2);
            $display("[L12V-TB]   |d|=3    : %0d", cnt_d3);
            $display("[L12V-TB]   |d|=4..8 : %0d", cnt_d4_8);
            $display("[L12V-TB]   |d|>8    : %0d", cnt_d_big);
            $display("[L12V-TB]   |d|>%0d (tol-exceed) : %0d", TOLERANCE, tol_fail_cnt);
        end
    endtask

    //----------------------------------------------------------------
    // Main
    //----------------------------------------------------------------
    initial begin
        rstn = 1'b0;
        dram_zero;
        load_goldens;

        $display("");
        $display("[L12V-TB] ============== Phase A : Standalone L12 ==============");

        load_dram_inputs;       // wgt/bias .mem (L12 영역 포함)
        software_repack_l12_ifm;  // golden L12 IFM → DRAM L12 IFM (NHWC entry)

        force u_yolo_engine.u_axi.slv_reg1 = 32'h0000_0000;
        force u_yolo_engine.u_axi.slv_reg2 = 32'h00B0_0000;
        force u_yolo_engine.u_axi.slv_reg3 = 32'h00C0_0000;

        #(8*CLK_PERIOD) rstn = 1'b1;
        #(4*CLK_PERIOD);

        @(posedge clk);
        force u_yolo_engine.layer_idx    = 5'd12;
        force u_yolo_engine.conv_phase_r = 5'd12;
        force u_yolo_engine.fi_r         = 12'd0;
        force u_yolo_engine.rb_r         = 12'd0;
        force u_yolo_engine.state_r      = 6'd1;        // S_LOAD_BIAS
        $display("[L12V-TB][%0t] Phase A : force layer_idx=12 conv_phase=12 state=S_LOAD_BIAS", $time);
        @(posedge clk);
        release u_yolo_engine.layer_idx;
        release u_yolo_engine.conv_phase_r;
        release u_yolo_engine.fi_r;
        release u_yolo_engine.rb_r;
        release u_yolo_engine.state_r;

        wait (u_yolo_engine.layer_idx == 5'd13);
        $display("[L12V-TB][%0t] Phase A : L12 COMPLETED (layer_idx -> 13)", $time);
        #(40*CLK_PERIOD);

        compare_l12_ofm(mm_l12_A, tf_l12_A);
        $display("[L12V-TB][Phase A] OFM mismatch: %0d / 16384   (tol-exceed: %0d)", mm_l12_A, tf_l12_A);
        if      (mm_l12_A == 0) $display("[L12V-TB][Phase A] *** PASS (exact, 0 mismatches) ***");
        else if (tf_l12_A == 0) $display("[L12V-TB][Phase A] *** PASS (within tolerance +-%0d, %0d noise) ***", TOLERANCE, mm_l12_A);
        else                    $display("[L12V-TB][Phase A] *** FAIL (%0d exceed +-%0d tolerance) ***", tf_l12_A, TOLERANCE);

        //==================================================================
        // [Phase B] Chain L0 → L1 → ... → L11 → L12 (RTL REPACK 통한 자연 진입)
        //==================================================================
        $display("");
        $display("[L12V-TB] ============== Phase B : Chain L0 -> ... -> L12 ==============");

        rstn = 1'b0;
        #(8*CLK_PERIOD);
        dram_zero;
        load_dram_inputs;       // wgt/bias/ifm (L0 IFM) 적재

        force u_yolo_engine.u_axi.slv_reg1 = 32'h0000_0000;
        force u_yolo_engine.u_axi.slv_reg2 = 32'h00B0_0000;
        force u_yolo_engine.u_axi.slv_reg3 = 32'h00C0_0000;

        #(4*CLK_PERIOD) rstn = 1'b1;
        #(4*CLK_PERIOD);

        @(posedge clk);
        force u_yolo_engine.u_axi.slv_reg0 = 32'd1;
        $display("[L12V-TB][%0t] Phase B : ap_start = 1", $time);
        @(posedge clk); @(posedge clk);
        force u_yolo_engine.u_axi.slv_reg0 = 32'd0;

        wait (u_yolo_engine.layer_idx == 5'd13);
        $display("[L12V-TB][%0t] Phase B : L0 -> ... -> L12 ALL COMPLETED", $time);
        #(40*CLK_PERIOD);

        compare_l12_ofm(mm_l12_B, tf_l12_B);
        $display("[L12V-TB][Phase B] OFM mismatch: %0d / 16384   (tol-exceed: %0d)", mm_l12_B, tf_l12_B);
        if      (mm_l12_B == 0) $display("[L12V-TB][Phase B] *** PASS (exact, 0 mismatches) ***");
        else if (tf_l12_B == 0) $display("[L12V-TB][Phase B] *** PASS (within tolerance +-%0d, %0d noise) ***", TOLERANCE, mm_l12_B);
        else                    $display("[L12V-TB][Phase B] *** FAIL (%0d exceed +-%0d tolerance) ***", tf_l12_B, TOLERANCE);

        $display("");
        $display("[L12V-TB] ============================================================");
        $display("[L12V-TB] Phase A : %s (mismatch=%0d, tol-exceed=%0d)",
                 (tf_l12_A == 0) ? "PASS" : "FAIL", mm_l12_A, tf_l12_A);
        $display("[L12V-TB] Phase B : %s (mismatch=%0d, tol-exceed=%0d)",
                 (tf_l12_B == 0) ? "PASS" : "FAIL", mm_l12_B, tf_l12_B);
        $display("[L12V-TB] ============================================================");

        #(20*CLK_PERIOD) $finish;
    end

    initial begin
        repeat(200_000) #(1_000_000);
        $display("[L12V-TB] *** TIMEOUT ***");
        $finish;
    end

    reg [4:0] prev_li;
    initial prev_li = 5'h1F;
    always @(posedge clk) begin
        if (rstn && u_yolo_engine.layer_idx !== prev_li) begin
            $display("[L12V-TB][%0t] >>> layer_idx %0d -> %0d <<<",
                     $time, prev_li, u_yolo_engine.layer_idx);
            prev_li <= u_yolo_engine.layer_idx;
        end
    end

`endif

endmodule
