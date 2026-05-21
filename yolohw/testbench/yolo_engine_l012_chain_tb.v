`timescale 1ns / 1ns
//----------------------------------------------------------------------
// yolo_engine_l012_chain_tb.v — L0 → L1 → L2 연속 실행 + 중간 검증
//
// 목적:
//   격리 TB (yolo_engine_l{0,1,2}_tb.v) 와 달리, 실제로 L0 가 만든 OFM 이
//   L1 의 입력으로, L1 의 OFM 이 L2 의 IFM 으로 어떻게 전달되는지를
//   "골든값 우회 없이" 추적한다. 중간 검사 지점:
//
//     [Check A] DRAM[L0 OFM] vs CONV00_output.hex (1,048,576 px)
//     [Check B] DRAM[L1 OFM] vs CONV02_input.hex  (  262,144 px)  ★ 핵심
//     [Check C] DRAM[L2 OFM] vs CONV02_output.hex (  524,288 px)
//
//   Check B 의 filter 0..3 / 4..15 분리 집계 → OFM dpram 용량 부족
//   (결함 A) 가설을 직접 검증.
//
// 진행 방식:
//   ap_start = 1 → 자연스럽게 layer 0 부터 진행 → layer_idx 가 3 으로 증가하면
//   (= L2 완료, L3 진입 시점) 즉시 $finish.
//
// 데이터 파일 경로: yolo_engine_l0_tb.v 와 동일 (gen_*.mem + log_feamap).
//----------------------------------------------------------------------
`include "user_define_h.v"

module yolo_engine_l012_chain_tb;

`ifdef FPGA
    initial begin
        $display("[TB][FATAL] FPGA macro enabled. Comment out `define FPGA.");
        $finish;
    end
`else

    parameter WGT_MEM     = "../../../../../../testbench/inout_data_sw/gen_wgt_dram.mem";
    parameter BIAS_MEM    = "../../../../../../testbench/inout_data_sw/gen_bias_dram.mem";
    parameter IFM_MEM     = "../../../../../../testbench/inout_data_sw/gen_ifm_dram.mem";
    parameter L0_GOLD_HEX = "../../../../../../testbench/inout_data_sw/log_feamap/CONV00_output.hex";
    parameter L1_GOLD_HEX = "../../../../../../testbench/inout_data_sw/log_feamap/CONV02_input.hex";
    parameter L2_GOLD_HEX = "../../../../../../testbench/inout_data_sw/log_feamap/CONV02_output.hex";

    parameter CLK_PERIOD = 10;
    reg clk, rstn;
    initial begin clk = 1'b0; forever #(CLK_PERIOD/2) clk = ~clk; end

    // ── DRAM layout (golden_tb 동일) ────────────────────────────────────
    localparam integer DRAM_WORDS       = 4 * 1024 * 1024;
    localparam integer WGT_TOTAL_WORDS  = 2_577_152;
    localparam integer BIAS_WORD_BASE   = 32'h00A00000 >> 2;
    localparam integer BIAS_TOTAL_WORDS = 2_294;
    localparam integer IFM_WORD_BASE    = 32'h00B00000 >> 2;
    localparam integer IFM_TOTAL_WORDS  = 65_536;
    localparam integer OFM_WORD_BASE    = 32'h00C00000 >> 2;

    localparam integer L0_OFM_OFF       = 0;
    localparam integer L1_OFM_OFF       = 262_144;
    localparam integer L2_OFM_OFF       = 327_680;

    // ── AXI4-Lite (tied) ──────────────────────────────────────────────
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

    // ── AXI4 master ────────────────────────────────────────────────────
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

    // ── DUT ────────────────────────────────────────────────────────────
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

    // ── Behavioral DRAM ────────────────────────────────────────────────
    reg [31:0] dram [0:DRAM_WORDS-1];

    // Read FSM
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

    // Write FSM
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

    // ── Golden 버퍼 ────────────────────────────────────────────────────
    reg [7:0] golden_l0 [0:1048575];   // 16 × 256 × 256 (L0 OFM)
    reg [7:0] golden_l1 [0:262143];    // 16 × 128 × 128 (L1 OFM = L2 IFM)
    reg [7:0] golden_l2 [0:524287];    // 32 × 128 × 128 (L2 OFM)

    // ── 시퀀스 변수 ────────────────────────────────────────────────────
    integer di, fi, hb, wb, sub_h, sub_w, pix_idx;
    integer cb_pool, c4;
    integer mm_l0, mm_l1_f03, mm_l1_f415, mm_l2;
    integer mm_print;
    reg [31:0] dword;
    reg [7:0]  got_b, exp_b;

    // ── 메인 ───────────────────────────────────────────────────────────
    initial begin
        rstn = 1'b0;

        for (di = 0; di < DRAM_WORDS; di = di + 1) dram[di] = 32'd0;

        $display("[CHAIN-TB] Loading WGT  : %s", WGT_MEM);
        $readmemh(WGT_MEM,  dram, 0,              WGT_TOTAL_WORDS - 1);
        $display("[CHAIN-TB] Loading BIAS : %s", BIAS_MEM);
        $readmemh(BIAS_MEM, dram, BIAS_WORD_BASE, BIAS_WORD_BASE + BIAS_TOTAL_WORDS - 1);
        $display("[CHAIN-TB] Loading IFM  : %s", IFM_MEM);
        $readmemh(IFM_MEM,  dram, IFM_WORD_BASE,  IFM_WORD_BASE  + IFM_TOTAL_WORDS  - 1);

        $display("[CHAIN-TB] Loading L0/L1/L2 golden hex...");
        $readmemh(L0_GOLD_HEX, golden_l0);
        $readmemh(L1_GOLD_HEX, golden_l1);
        $readmemh(L2_GOLD_HEX, golden_l2);

        force u_yolo_engine.u_axi.slv_reg1 = 32'h0000_0000;
        force u_yolo_engine.u_axi.slv_reg2 = 32'h00B0_0000;
        force u_yolo_engine.u_axi.slv_reg3 = 32'h00C0_0000;

        #(8*CLK_PERIOD) rstn = 1'b1;
        #(4*CLK_PERIOD);

        // ap_start 자연 시작 → L0 부터 진행
        @(posedge clk);
        force u_yolo_engine.u_axi.slv_reg0 = 32'd1;
        $display("[CHAIN-TB][%0t] ap_start = 1", $time);
        @(posedge clk); @(posedge clk);
        force u_yolo_engine.u_axi.slv_reg0 = 32'd0;

        // ── L2 완료까지 대기 ─────────────────────────────────────────────
        wait (u_yolo_engine.layer_idx == 5'd3);
        $display("[CHAIN-TB][%0t] L0~L2 ALL COMPLETED (layer_idx → 3)", $time);
        #(40*CLK_PERIOD);

        // ─────────────────────────────────────────────────────────────────
        // [Check A] L0 OFM (DRAM offset 0)  vs  CONV00_output.hex
        //   word(fi, hb, wb) at OFM_BASE + fi*16384 + hb*128 + wb
        //   4 sub-pixel = pixel(fi, 2hb+sub_h, 2wb+sub_w)
        // ─────────────────────────────────────────────────────────────────
        mm_l0 = 0; mm_print = 0;
        for (fi = 0; fi < 16; fi = fi + 1) begin
            for (hb = 0; hb < 128; hb = hb + 1) begin
                for (wb = 0; wb < 128; wb = wb + 1) begin
                    dword = dram[OFM_WORD_BASE + L0_OFM_OFF + fi*16384 + hb*128 + wb];
                    for (sub_h = 0; sub_h < 2; sub_h = sub_h + 1) begin
                        for (sub_w = 0; sub_w < 2; sub_w = sub_w + 1) begin
                            pix_idx = sub_h*2 + sub_w;
                            got_b   = dword[pix_idx*8 +: 8];
                            exp_b   = golden_l0[fi*65536 + (hb*2+sub_h)*256 + (wb*2+sub_w)];
                            if (got_b !== exp_b) begin
                                mm_l0 = mm_l0 + 1;
                                if (mm_print < 8) begin
                                    $display("  [L0 MISMATCH] fi=%0d h=%0d w=%0d got=%02x exp=%02x",
                                             fi, hb*2+sub_h, wb*2+sub_w, got_b, exp_b);
                                    mm_print = mm_print + 1;
                                end
                            end
                        end
                    end
                end
            end
        end
        $display("[CHAIN-TB][CheckA] L0 OFM mismatch: %0d / 1,048,576", mm_l0);

        // ─────────────────────────────────────────────────────────────────
        // [Check B] L1 OFM (DRAM offset 262144)  vs  CONV02_input.hex
        //   word(fi, r, cb_pool) at OFM_BASE + L1_OFM_OFF + fi*4096 + r*32 + cb_pool
        //   4 byte = pool(fi, r, cb_pool*4 + 0..3)
        //   ★ filter 0..3 vs 4..15 분리 집계 (dpram wrap 증거)
        // ─────────────────────────────────────────────────────────────────
        mm_l1_f03 = 0; mm_l1_f415 = 0; mm_print = 0;
        for (fi = 0; fi < 16; fi = fi + 1) begin
            for (hb = 0; hb < 128; hb = hb + 1) begin
                for (cb_pool = 0; cb_pool < 32; cb_pool = cb_pool + 1) begin
                    dword = dram[OFM_WORD_BASE + L1_OFM_OFF + fi*4096 + hb*32 + cb_pool];
                    for (c4 = 0; c4 < 4; c4 = c4 + 1) begin
                        got_b = dword[c4*8 +: 8];
                        exp_b = golden_l1[fi*16384 + hb*128 + cb_pool*4 + c4];
                        if (got_b !== exp_b) begin
                            if (fi < 4) begin
                                mm_l1_f03 = mm_l1_f03 + 1;
                                if (mm_print < 8) begin
                                    $display("  [L1 MISMATCH fi<4] fi=%0d r=%0d c=%0d got=%02x exp=%02x",
                                             fi, hb, cb_pool*4+c4, got_b, exp_b);
                                    mm_print = mm_print + 1;
                                end
                            end else begin
                                mm_l1_f415 = mm_l1_f415 + 1;
                            end
                        end
                    end
                end
            end
        end
        $display("[CHAIN-TB][CheckB] L1 OFM mismatch f0..3 : %0d /  65,536", mm_l1_f03);
        $display("[CHAIN-TB][CheckB] L1 OFM mismatch f4..15: %0d / 196,608", mm_l1_f415);

        // ─────────────────────────────────────────────────────────────────
        // [Check C] L2 OFM (DRAM offset 327680)  vs  CONV02_output.hex
        //   word(fi, h2, w2) at OFM_BASE + L2_OFM_OFF + fi*4096 + h2*64 + w2
        // ─────────────────────────────────────────────────────────────────
        mm_l2 = 0; mm_print = 0;
        for (fi = 0; fi < 32; fi = fi + 1) begin
            for (hb = 0; hb < 64; hb = hb + 1) begin
                for (wb = 0; wb < 64; wb = wb + 1) begin
                    dword = dram[OFM_WORD_BASE + L2_OFM_OFF + fi*4096 + hb*64 + wb];
                    for (sub_h = 0; sub_h < 2; sub_h = sub_h + 1) begin
                        for (sub_w = 0; sub_w < 2; sub_w = sub_w + 1) begin
                            pix_idx = sub_h*2 + sub_w;
                            got_b   = dword[pix_idx*8 +: 8];
                            exp_b   = golden_l2[fi*16384 + (hb*2+sub_h)*128 + (wb*2+sub_w)];
                            if (got_b !== exp_b) begin
                                mm_l2 = mm_l2 + 1;
                                if (mm_print < 8) begin
                                    $display("  [L2 MISMATCH] fi=%0d h=%0d w=%0d got=%02x exp=%02x",
                                             fi, hb*2+sub_h, wb*2+sub_w, got_b, exp_b);
                                    mm_print = mm_print + 1;
                                end
                            end
                        end
                    end
                end
            end
        end
        $display("[CHAIN-TB][CheckC] L2 OFM mismatch: %0d / 524,288", mm_l2);

        // ── 종합 판정 ────────────────────────────────────────────────────
        $display("[CHAIN-TB] ============================================================");
        $display("[CHAIN-TB] L0 OFM        : %s (%0d mismatches)",
                 (mm_l0 == 0) ? "PASS" : "FAIL", mm_l0);
        $display("[CHAIN-TB] L1 OFM f0..3  : %s (%0d mismatches) ← max_pool 자체",
                 (mm_l1_f03 == 0) ? "PASS" : "FAIL", mm_l1_f03);
        $display("[CHAIN-TB] L1 OFM f4..15 : %s (%0d mismatches) ← dpram 용량/wrap",
                 (mm_l1_f415 == 0) ? "PASS" : "FAIL", mm_l1_f415);
        $display("[CHAIN-TB] L2 OFM        : %s (%0d mismatches)",
                 (mm_l2 == 0) ? "PASS" : "FAIL", mm_l2);
        $display("[CHAIN-TB] ============================================================");
        if (mm_l1_f415 > mm_l1_f03 * 10)
            $display("[CHAIN-TB] >> 진단: L1 의 filter 4..15 이 압도적으로 깨짐 →");
            $display("[CHAIN-TB]    OFM dpram(65,536) < L0 OFM(262,144) 의 wrap 결함 (SOLUTION.md 결함 A)");

        #(20*CLK_PERIOD) $finish;
    end

    // ── Watchdog ──────────────────────────────────────────────────────
    initial begin
        repeat(5_000) #(1_000_000);
        $display("[CHAIN-TB] *** TIMEOUT (500M cycles) ***");
        $finish;
    end

    // ── FSM 추적 ──────────────────────────────────────────────────────
    reg [3:0] prev_ts;
    reg [4:0] prev_li;
    initial begin prev_ts = 4'hF; prev_li = 5'h1F; end
    always @(posedge clk) begin
        if (rstn) begin
            if (u_yolo_engine.top_state !== prev_ts) begin
                $display("[CHAIN-TB][%0t] L%0d top_state %0d→%0d  rb=%0d rb_str=%0d str_mode=%0d",
                         $time, u_yolo_engine.layer_idx, prev_ts, u_yolo_engine.top_state,
                         u_yolo_engine.rb_stream_rb_r,
                         u_yolo_engine.rb_stream_mode_r,
                         u_yolo_engine.stream_mode);
                prev_ts <= u_yolo_engine.top_state;
            end
            if (u_yolo_engine.layer_idx !== prev_li) begin
                $display("[CHAIN-TB][%0t] >>> layer_idx %0d→%0d <<<",
                         $time, prev_li, u_yolo_engine.layer_idx);
                prev_li <= u_yolo_engine.layer_idx;
            end
        end
    end

    // ── L1 직전 dpram (OFM) 상태 sample ────────────────────────────────
    //   L0 ST_NEXT → L1 ST_INIT 전이 직전에 dpram 의 4 word sample 출력.
    //   L0 streaming 종료 직후 dpram 에 어떤 필터가 남아 있는지 확인.
    reg pre_l1_logged;
    initial pre_l1_logged = 1'b0;
    always @(posedge clk) begin
        if (rstn && !pre_l1_logged &&
            u_yolo_engine.layer_idx == 5'd1 &&
            u_yolo_engine.top_state == 4'd1) begin
            // L1 ST_INIT 진입 시점 sample
            $display("[CHAIN-TB][%0t] dpram pre-L1 sample: [0]=%08x [16384]=%08x [49152]=%08x [65535]=%08x",
                     $time,
                     u_yolo_engine.u_ofm.ram[0],
                     u_yolo_engine.u_ofm.ram[16384],
                     u_yolo_engine.u_ofm.ram[49152],
                     u_yolo_engine.u_ofm.ram[65535]);
            pre_l1_logged <= 1'b1;
        end
    end

    // ── 각 layer 별 OFM DMA write 개시 추적 (burst 수 카운트) ──────────
    reg prev_dma_wr_start;
    initial prev_dma_wr_start = 1'b0;
    integer dma_wr_cnt_l0, dma_wr_cnt_l1, dma_wr_cnt_l2;
    initial begin dma_wr_cnt_l0 = 0; dma_wr_cnt_l1 = 0; dma_wr_cnt_l2 = 0; end
    always @(posedge clk) begin
        if (rstn) begin
            prev_dma_wr_start <= u_yolo_engine.dma_wr_start;
            if (u_yolo_engine.dma_wr_start && !prev_dma_wr_start) begin
                case (u_yolo_engine.layer_idx)
                    5'd0: dma_wr_cnt_l0 <= dma_wr_cnt_l0 + 1;
                    5'd1: dma_wr_cnt_l1 <= dma_wr_cnt_l1 + 1;
                    5'd2: dma_wr_cnt_l2 <= dma_wr_cnt_l2 + 1;
                    default: ;
                endcase
            end
        end
    end

    // ── L1 OFM DMA write 데이터 sample (첫 burst 의 첫 32 word) ────────
    //   L1 출력이 어떻게 DRAM 에 dump 되는지 직접 관찰 → L2 가 받을 데이터.
    integer l1_dma_data_cnt;
    initial l1_dma_data_cnt = 0;
    always @(posedge clk) begin
        if (rstn && u_yolo_engine.layer_idx == 5'd1 &&
            M_WVALID && M_WREADY && l1_dma_data_cnt < 32) begin
            $display("[CHAIN-TB][%0t] L1 DMA WR addr=%08x data=%08x (cnt=%0d)",
                     $time, wr_addr_r, M_WDATA, l1_dma_data_cnt);
            l1_dma_data_cnt <= l1_dma_data_cnt + 1;
        end
    end

    // ── L2 IFM DMA read 데이터 sample (첫 32 word) ─────────────────────
    //   L2 가 line_buf 에 적재하는 IFM raw word — 결함 A 가설 시 corrupted.
    integer l2_dma_rd_cnt;
    initial l2_dma_rd_cnt = 0;
    always @(posedge clk) begin
        if (rstn && u_yolo_engine.layer_idx == 5'd2 &&
            u_yolo_engine.dma_target_r == 2'd0 &&
            M_RVALID && M_RREADY && l2_dma_rd_cnt < 32) begin
            $display("[CHAIN-TB][%0t] L2 IFM DMA RD addr=%08x data=%08x (cnt=%0d)",
                     $time, rd_addr_r, M_RDATA, l2_dma_rd_cnt);
            l2_dma_rd_cnt <= l2_dma_rd_cnt + 1;
        end
    end

    // ── 각 layer 종료 시 누적 카운터 출력 ─────────────────────────────
    always @(posedge clk) begin
        if (rstn && prev_li !== u_yolo_engine.layer_idx) begin
            case (prev_li)
                5'd0: $display("[CHAIN-TB] >>> L0 finished. dma_wr_burst_cnt = %0d", dma_wr_cnt_l0);
                5'd1: $display("[CHAIN-TB] >>> L1 finished. dma_wr_burst_cnt = %0d", dma_wr_cnt_l1);
                5'd2: $display("[CHAIN-TB] >>> L2 finished. dma_wr_burst_cnt = %0d", dma_wr_cnt_l2);
                default: ;
            endcase
        end
    end

`endif

endmodule
