`timescale 1ns / 1ns
//----------------------------------------------------------------------
// l18_verify_tb.v — L18 (UPSAMPLE 2×, 128 ch, 8×8 → 16×16) 2-단계 검증 TB
//
//   IFM = L17 OFM (conv 2×2 packed, 8×8×128 = 2048 word)
//   OFM = 2× nearest-neighbor upsample (conv 2×2 packed, 16×16×128 = 8192 word)
//
//   Golden source:
//     L17 OFM input → CONV17_output.hex (NCHW byte stream, 8192 byte)
//     L18 OFM       → CONV20_input.hex 의 chan 0..127 부분 (NCHW byte stream, 32768 byte)
//                     (L19 route concat 시 L18 OFM 이 L20 입력의 처음 128 ch)
//
//   [Phase A] Standalone L18
//     - L17 OFM golden (NCHW byte) 을 conv 2×2 packed 으로 DRAM L17 OFM 영역에 적재
//     - force layer_idx=18, state_r=S_L18_LOAD → release
//     - L18 단독 실행 → layer_idx=19
//     - DRAM L18 OFM ↔ golden_l18_ofm 비교
//
//   [Phase B] Chain L0 → ... → L18
//     - reset → wgt/bias/ifm .mem 적재 → ap_start
//     - 자연 진행 (L0~L17 + L18) → layer_idx=19
//     - DRAM L18 OFM ↔ golden_l18_ofm 비교
//
// DRAM 메모리 맵 (L18):
//   L17 OFM           : 0x00320000 ( 8KB = 2048 word, conv 2×2 packed)
//   L18 OFM           : 0x00328000 (32KB = 8192 word, conv 2×2 packed)
//----------------------------------------------------------------------
`include "user_define_h.v"

module l18_verify_tb;

`ifdef FPGA
    initial begin
        $display("[L18V-TB][FATAL] FPGA macro enabled.");
        $finish;
    end
`else

    parameter WGT_MEM      = "../../../../../../testbench/inout_data_sw/gen_wgt_dram.mem";
    parameter BIAS_MEM     = "../../../../../../testbench/inout_data_sw/gen_bias_dram.mem";
    parameter IFM_MEM      = "../../../../../../testbench/inout_data_sw/gen_ifm_dram.mem";
    parameter L17_OFM_HEX  = "../../../../../../testbench/inout_data_sw/log_feamap/CONV17_output.hex";
    parameter L20_IFM_HEX  = "../../../../../../testbench/inout_data_sw/log_feamap/CONV20_input.hex";

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
    localparam integer L17_OFM_OFF_W    = 32'h00320000 >> 2;
    localparam integer L18_OFM_OFF_W    = 32'h00328000 >> 2;

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
    reg [7:0] golden_l17_ofm [0: 8191];   // 128 × 8 × 8 NCHW byte
    reg [7:0] golden_l20_ifm [0:98303];   // 384 × 16 × 16 NCHW byte (chan 0..127 = L18 OFM)
    reg [7:0] golden_l18_ofm [0:32767];   // 128 × 16 × 16 NCHW byte (chan 0..127 of L20 IFM)

    integer mm_l18_A, mm_l18_B;

    task dram_zero;
        integer t_i;
        begin
            for (t_i = 0; t_i < DRAM_WORDS; t_i = t_i + 1) dram[t_i] = 32'd0;
        end
    endtask

    task load_dram_inputs;
        begin
            $display("[L18V-TB] Loading WGT  : %s", WGT_MEM);
            $readmemh(WGT_MEM,  dram, 0,              WGT_TOTAL_WORDS - 1);
            $display("[L18V-TB] Loading BIAS : %s", BIAS_MEM);
            $readmemh(BIAS_MEM, dram, BIAS_WORD_BASE, BIAS_WORD_BASE + BIAS_TOTAL_WORDS - 1);
            $display("[L18V-TB] Loading IFM  : %s (L0 IFM)", IFM_MEM);
            $readmemh(IFM_MEM,  dram, IFM_WORD_BASE,  IFM_WORD_BASE  + IFM_TOTAL_WORDS  - 1);
        end
    endtask

    task load_goldens;
        integer t_i;
        begin
            $display("[L18V-TB] Loading L17 OFM golden : %s", L17_OFM_HEX);
            $readmemh(L17_OFM_HEX, golden_l17_ofm);
            $display("[L18V-TB] Loading L20 IFM golden : %s", L20_IFM_HEX);
            $readmemh(L20_IFM_HEX, golden_l20_ifm);
            // L18 OFM = L20 IFM 의 chan 0..127 부분 (NCHW byte stream)
            for (t_i = 0; t_i < 32768; t_i = t_i + 1)
                golden_l18_ofm[t_i] = golden_l20_ifm[t_i];
            $display("[L18V-TB] Extracted L18 OFM golden (32768 byte = chan 0..127 of L20 IFM)");
        end
    endtask

    // [Phase A] Software pack: golden_l17_ofm (NCHW byte, 8192) → DRAM L17 OFM (conv 2×2 packed)
    //   chan f, block (hb, wb) : 4 byte = pix(2hb, 2wb), pix(2hb, 2wb+1), pix(2hb+1, 2wb), pix(2hb+1, 2wb+1)
    //   word @ OFM_WORD_BASE + L17_OFM_OFF_W + f*16 + hb*4 + wb
    task software_pack_l17_ofm;
        integer t_f, t_hb, t_wb;
        reg [7:0] p00, p01, p10, p11;
        reg [31:0] tword;
        integer t_addr_w;
        begin
            $display("[L18V-TB] Software pack : L17 OFM (NCHW → conv 2×2 packed, 2048 word)...");
            for (t_f = 0; t_f < 128; t_f = t_f + 1) begin
                for (t_hb = 0; t_hb < 4; t_hb = t_hb + 1) begin
                    for (t_wb = 0; t_wb < 4; t_wb = t_wb + 1) begin
                        p00 = golden_l17_ofm[t_f*64 + (2*t_hb  )*8 + (2*t_wb  )];
                        p01 = golden_l17_ofm[t_f*64 + (2*t_hb  )*8 + (2*t_wb+1)];
                        p10 = golden_l17_ofm[t_f*64 + (2*t_hb+1)*8 + (2*t_wb  )];
                        p11 = golden_l17_ofm[t_f*64 + (2*t_hb+1)*8 + (2*t_wb+1)];
                        tword    = {p11, p10, p01, p00};
                        t_addr_w = OFM_WORD_BASE + L17_OFM_OFF_W + t_f*16 + t_hb*4 + t_wb;
                        dram[t_addr_w] = tword;
                    end
                end
            end
            $display("[L18V-TB] Software pack complete (2048 word at L17 OFM region)");
        end
    endtask

    // L18 OFM 비교 + Δ magnitude 분포
    //   L18 OFM 형식 = conv 2×2 packed
    //   chan f, block (hb, wb)  hb=0..7, wb=0..7  → byte ordering: pix(2hb,2wb), pix(2hb,2wb+1), pix(2hb+1,2wb), pix(2hb+1,2wb+1)
    //   word @ OFM_WORD_BASE + L18_OFM_OFF_W + f*64 + hb*8 + wb
    task compare_l18_ofm;
        output integer mismatch_cnt;
        integer t_f, t_hb, t_wb, t_sh, t_sw, t_idx, t_print;
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
            for (t_f = 0; t_f < 128; t_f = t_f + 1) begin
                for (t_hb = 0; t_hb < 8; t_hb = t_hb + 1) begin
                    for (t_wb = 0; t_wb < 8; t_wb = t_wb + 1) begin
                        tw = dram[OFM_WORD_BASE + L18_OFM_OFF_W + t_f*64 + t_hb*8 + t_wb];
                        for (t_sh = 0; t_sh < 2; t_sh = t_sh + 1) begin
                            for (t_sw = 0; t_sw < 2; t_sw = t_sw + 1) begin
                                t_idx = t_sh*2 + t_sw;
                                tg = tw[t_idx*8 +: 8];
                                te = golden_l18_ofm[t_f*256 + (2*t_hb+t_sh)*16 + (2*t_wb+t_sw)];
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
                                        $display("  [L18 MISMATCH] f=%0d h=%0d w=%0d got=%02x exp=%02x (d=%0d)",
                                                 t_f, 2*t_hb+t_sh, 2*t_wb+t_sw, tg, te, diff_signed);
                                        t_print = t_print + 1;
                                    end
                                end
                            end
                        end
                    end
                end
            end
            $display("[L18V-TB] Δ 분포 — total=%0d, +Δ=%0d, -Δ=%0d, max|Δ|=%0d",
                     mismatch_cnt, cnt_pos, cnt_neg, max_diff);
            $display("[L18V-TB]   |Δ|=1 : %0d   (%0d%%)",
                     cnt_d1, (cnt_d1*100)/((mismatch_cnt==0)?1:mismatch_cnt));
            $display("[L18V-TB]   |Δ|=2 : %0d", cnt_d2);
            $display("[L18V-TB]   |Δ|=3 : %0d", cnt_d3);
            $display("[L18V-TB]   |Δ|=4..8 : %0d", cnt_d4_8);
            $display("[L18V-TB]   |Δ|>8 : %0d", cnt_d_big);
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
        // [Phase A] Standalone L18
        //==================================================================
        $display("");
        $display("[L18V-TB] ============== Phase A : Standalone L18 (UPSAMPLE) ==============");

        load_dram_inputs;
        software_pack_l17_ofm;

        force u_yolo_engine.u_axi.slv_reg1 = 32'h0000_0000;
        force u_yolo_engine.u_axi.slv_reg2 = 32'h00B0_0000;
        force u_yolo_engine.u_axi.slv_reg3 = 32'h00C0_0000;

        #(8*CLK_PERIOD) rstn = 1'b1;
        #(4*CLK_PERIOD);

        @(posedge clk);
        force u_yolo_engine.layer_idx    = 5'd18;
        force u_yolo_engine.fi_r         = 12'd0;
        force u_yolo_engine.rb_r         = 12'd0;
        force u_yolo_engine.state_r      = 6'd39;        // S_L18_LOAD
        $display("[L18V-TB][%0t] Phase A : force layer_idx=18 state=S_L18_LOAD", $time);
        @(posedge clk);
        release u_yolo_engine.layer_idx;
        release u_yolo_engine.fi_r;
        release u_yolo_engine.rb_r;
        release u_yolo_engine.state_r;

        wait (u_yolo_engine.layer_idx == 5'd19);
        $display("[L18V-TB][%0t] Phase A : L18 COMPLETED (layer_idx → 19)", $time);
        #(40*CLK_PERIOD);

        compare_l18_ofm(mm_l18_A);
        $display("[L18V-TB][Phase A] L18 OFM mismatch: %0d / 32,768", mm_l18_A);
        if (mm_l18_A == 0) $display("[L18V-TB][Phase A] *** PASS *** : L18 단독 OK");
        else               $display("[L18V-TB][Phase A] *** FAIL ***");

        //==================================================================
        // [Phase B] Chain L0 → ... → L18
        //==================================================================
        $display("");
        $display("[L18V-TB] ============== Phase B : Chain L0 → ... → L18 ==============");

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
        $display("[L18V-TB][%0t] Phase B : ap_start = 1", $time);
        @(posedge clk); @(posedge clk);
        force u_yolo_engine.u_axi.slv_reg0 = 32'd0;

        wait (u_yolo_engine.layer_idx == 5'd19);
        $display("[L18V-TB][%0t] Phase B : L0→...→L18 ALL COMPLETED", $time);
        #(40*CLK_PERIOD);

        compare_l18_ofm(mm_l18_B);
        $display("[L18V-TB][Phase B] L18 OFM mismatch: %0d / 32,768", mm_l18_B);
        if (mm_l18_B == 0) $display("[L18V-TB][Phase B] *** PASS ***");
        else               $display("[L18V-TB][Phase B] *** FAIL *** (또는 propagation 누적)");

        $display("");
        $display("[L18V-TB] ============================================================");
        $display("[L18V-TB] Phase A (standalone L18 UPSAMPLE) : %s (mismatch=%0d)",
                 (mm_l18_A == 0) ? "PASS" : "FAIL", mm_l18_A);
        $display("[L18V-TB] Phase B (L0→...→L18)              : %s (mismatch=%0d)",
                 (mm_l18_B == 0) ? "PASS" : "FAIL", mm_l18_B);
        $display("[L18V-TB] ============================================================");

        #(20*CLK_PERIOD) $finish;
    end

    initial begin
        repeat(500_000) #(1_000_000);
        $display("[L18V-TB] *** TIMEOUT ***");
        $finish;
    end

    reg [4:0] prev_li;
    initial prev_li = 5'h1F;
    always @(posedge clk) begin
        if (rstn && u_yolo_engine.layer_idx !== prev_li) begin
            $display("[L18V-TB][%0t] >>> layer_idx %0d → %0d <<<",
                     $time, prev_li, u_yolo_engine.layer_idx);
            prev_li <= u_yolo_engine.layer_idx;
        end
    end

`endif

endmodule
