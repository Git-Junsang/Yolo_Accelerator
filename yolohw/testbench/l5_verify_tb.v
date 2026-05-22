`timescale 1ns / 1ns
//----------------------------------------------------------------------
// l5_verify_tb.v — L5 (POOL_S2 64ch, 64→32) 2-단계 통합 검증 TB
//
//   [Phase A] Standalone L5
//     - L4 OFM (CONV04_output.hex) 을 DRAM L4 OFM 영역에 2×2 packed 포맷으로 사전 적재
//     - layer_idx=5, pool_phase_r=5, fi_r=0, state_r=S_L1_FI_LOAD 강제 진입 → release
//     - L5 만 단독 실행 → layer_idx=6 도달
//     - DRAM L5 OFM ↔ CONV06_input.hex 비교
//
//   [Phase B] Chain L0 → ... → L5
//     - 시뮬레이션 리셋 → wgt/bias/ifm .mem 적재 → ap_start=1
//     - 자연 진행: L0 → L1 → REPACK → L2 → L3 → REPACK → L4 → L5
//     - DRAM L5 OFM ↔ CONV06_input.hex 비교
//
// DRAM 메모리 맵 (yolo_engine.v 기준):
//   WGT     : 0x0000_0000 (L0..L4 weights, byte 0..41984)
//   BIAS    : 0x00A0_0000 (L0..L4 biases)
//   IFM     : 0x00B0_0000 (L0 input)
//   OFM 영역 (ofm_base + offset):
//     L0 OFM         : 0x000000..0x0FFFFF (1MB)
//     L1 OFM         : 0x100000..0x13FFFF (256KB)
//     L2 IFM (rp)    : 0x140000..0x17FFFF (256KB)
//     L2 OFM         : 0x180000..0x1FFFFF (512KB)
//     L3 OFM         : 0x200000..0x21FFFF (128KB)
//     L4 IFM (rp)    : 0x220000..0x23FFFF (128KB)
//     L4 OFM         : 0x240000..0x27FFFF (256KB)
//     L5 OFM         : 0x280000..0x28FFFF (64KB)
//----------------------------------------------------------------------
`include "user_define_h.v"

module l5_verify_tb;

`ifdef FPGA
    initial begin
        $display("[L5V-TB][FATAL] FPGA macro enabled.");
        $finish;
    end
`else

    parameter WGT_MEM     = "../../../../../../testbench/inout_data_sw/gen_wgt_dram.mem";
    parameter BIAS_MEM    = "../../../../../../testbench/inout_data_sw/gen_bias_dram.mem";
    parameter IFM_MEM     = "../../../../../../testbench/inout_data_sw/gen_ifm_dram.mem";
    parameter L4_GOLD_HEX = "../../../../../../testbench/inout_data_sw/log_feamap/CONV04_output.hex";
    parameter L5_GOLD_HEX = "../../../../../../testbench/inout_data_sw/log_feamap/CONV06_input.hex";

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
    localparam integer L4_OFM_OFF_W     = 32'h00240000 >> 2;
    localparam integer L5_OFM_OFF_W     = 32'h00280000 >> 2;

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

    // ── Behavioral DRAM ────────────────────────────────────────────────
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

    // ── Golden 버퍼 ────────────────────────────────────────────────────
    reg [7:0] golden_l4 [0:262143];   // 64 × 64 × 64 (L4 OFM, NCHW)
    reg [7:0] golden_l5 [0:65535];    // 64 × 32 × 32 (L5 OFM, NCHW)

    integer mm_l5_A, mm_l5_B;

    //----------------------------------------------------------------
    // Tasks
    //----------------------------------------------------------------
    task dram_zero;
        integer t_i;
        begin
            for (t_i = 0; t_i < DRAM_WORDS; t_i = t_i + 1) dram[t_i] = 32'd0;
        end
    endtask

    task load_dram_inputs;
        begin
            $display("[L5V-TB] Loading WGT  : %s", WGT_MEM);
            $readmemh(WGT_MEM,  dram, 0,              WGT_TOTAL_WORDS - 1);
            $display("[L5V-TB] Loading BIAS : %s", BIAS_MEM);
            $readmemh(BIAS_MEM, dram, BIAS_WORD_BASE, BIAS_WORD_BASE + BIAS_TOTAL_WORDS - 1);
            $display("[L5V-TB] Loading IFM  : %s", IFM_MEM);
            $readmemh(IFM_MEM,  dram, IFM_WORD_BASE,  IFM_WORD_BASE  + IFM_TOTAL_WORDS  - 1);
        end
    endtask

    task load_goldens;
        begin
            $display("[L5V-TB] Loading L4 OFM golden : %s", L4_GOLD_HEX);
            $readmemh(L4_GOLD_HEX, golden_l4);
            $display("[L5V-TB] Loading L5 OFM golden : %s", L5_GOLD_HEX);
            $readmemh(L5_GOLD_HEX, golden_l5);
        end
    endtask

    // Phase A: golden_l4 (NCHW byte) → DRAM L4 OFM 영역 (2×2 conv packed)
    //   per (fi, h_block, w_block) word: 4 bytes = (h0w0, h0w1, h1w0, h1w1)
    //   DRAM word addr = OFM_WORD_BASE + L4_OFM_OFF_W + fi*1024 + hb*32 + wb
    //   (per fi = 32 hb × 32 wb = 1024 word)
    task preload_l4_ofm;
        integer t_fi, t_hb, t_wb;
        reg [7:0] tp0, tp1, tp2, tp3;
        integer t_addr;
        begin
            $display("[L5V-TB] Pre-loading DRAM L4 OFM region (64 × 1024 word)...");
            for (t_fi = 0; t_fi < 64; t_fi = t_fi + 1) begin
                for (t_hb = 0; t_hb < 32; t_hb = t_hb + 1) begin
                    for (t_wb = 0; t_wb < 32; t_wb = t_wb + 1) begin
                        tp0 = golden_l4[t_fi*4096 + (t_hb*2  )*64 + (t_wb*2  )];
                        tp1 = golden_l4[t_fi*4096 + (t_hb*2  )*64 + (t_wb*2+1)];
                        tp2 = golden_l4[t_fi*4096 + (t_hb*2+1)*64 + (t_wb*2  )];
                        tp3 = golden_l4[t_fi*4096 + (t_hb*2+1)*64 + (t_wb*2+1)];
                        t_addr = OFM_WORD_BASE + L4_OFM_OFF_W + t_fi*1024 + t_hb*32 + t_wb;
                        dram[t_addr] = {tp3, tp2, tp1, tp0};
                    end
                end
            end
        end
    endtask

    // L5 OFM 비교 (= L1 과 같은 max_pool packed 형식)
    //   per (fi, r, cb_pool) word: 4 byte = pool(fi, r, cb_pool*4 + 0..3)
    //   DRAM word addr = OFM_WORD_BASE + L5_OFM_OFF_W + fi*256 + r*8 + cb_pool
    task compare_l5_ofm;
        output integer mismatch_cnt;
        integer t_fi, t_r, t_cb, t_c4, t_print;
        reg [31:0] tw;
        reg [7:0]  tg, te;
        begin
            mismatch_cnt = 0;
            t_print      = 0;
            for (t_fi = 0; t_fi < 64; t_fi = t_fi + 1) begin
                for (t_r = 0; t_r < 32; t_r = t_r + 1) begin
                    for (t_cb = 0; t_cb < 8; t_cb = t_cb + 1) begin
                        tw = dram[OFM_WORD_BASE + L5_OFM_OFF_W + t_fi*256 + t_r*8 + t_cb];
                        for (t_c4 = 0; t_c4 < 4; t_c4 = t_c4 + 1) begin
                            tg = tw[t_c4*8 +: 8];
                            te = golden_l5[t_fi*1024 + t_r*32 + t_cb*4 + t_c4];
                            if (tg !== te) begin
                                mismatch_cnt = mismatch_cnt + 1;
                                if (t_print < 8) begin
                                    $display("  [L5 MISMATCH] fi=%0d r=%0d c=%0d got=%02x exp=%02x",
                                             t_fi, t_r, t_cb*4+t_c4, tg, te);
                                    t_print = t_print + 1;
                                end
                            end
                        end
                    end
                end
            end
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
        // [Phase A] Standalone L5
        //==================================================================
        $display("");
        $display("[L5V-TB] ============== Phase A : Standalone L5 ==============");

        preload_l4_ofm;

        force u_yolo_engine.u_axi.slv_reg1 = 32'h0000_0000;
        force u_yolo_engine.u_axi.slv_reg2 = 32'h00B0_0000;
        force u_yolo_engine.u_axi.slv_reg3 = 32'h00C0_0000;

        #(8*CLK_PERIOD) rstn = 1'b1;
        #(4*CLK_PERIOD);

        @(posedge clk);
        force u_yolo_engine.layer_idx    = 5'd5;
        force u_yolo_engine.pool_phase_r = 5'd5;
        force u_yolo_engine.fi_r         = 12'd0;
        force u_yolo_engine.state_r      = 5'd13;       // S_L1_FI_LOAD (generic pool)
        $display("[L5V-TB][%0t] Phase A : force layer_idx=5 pool_phase=5 state=S_L1_FI_LOAD", $time);
        @(posedge clk);
        release u_yolo_engine.layer_idx;
        release u_yolo_engine.pool_phase_r;
        release u_yolo_engine.fi_r;
        release u_yolo_engine.state_r;

        wait (u_yolo_engine.layer_idx == 5'd6);
        $display("[L5V-TB][%0t] Phase A : L5 COMPLETED (layer_idx → 6)", $time);
        #(40*CLK_PERIOD);

        compare_l5_ofm(mm_l5_A);
        $display("[L5V-TB][Phase A] L5 OFM mismatch: %0d / 65,536", mm_l5_A);
        if (mm_l5_A == 0)
            $display("[L5V-TB][Phase A] *** PASS *** : L5 pool 단독 OK");
        else
            $display("[L5V-TB][Phase A] *** FAIL *** : L5 단독에 BUG");

        //==================================================================
        // [Phase B] Chain L0 → L5
        //==================================================================
        $display("");
        $display("[L5V-TB] ============== Phase B : Chain L0 → L5 ==============");

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
        $display("[L5V-TB][%0t] Phase B : ap_start = 1", $time);
        @(posedge clk); @(posedge clk);
        force u_yolo_engine.u_axi.slv_reg0 = 32'd0;

        wait (u_yolo_engine.layer_idx == 5'd6);
        $display("[L5V-TB][%0t] Phase B : L0→...→L5 ALL COMPLETED", $time);
        #(40*CLK_PERIOD);

        compare_l5_ofm(mm_l5_B);
        $display("[L5V-TB][Phase B] L5 OFM mismatch: %0d / 65,536", mm_l5_B);
        if (mm_l5_B == 0)
            $display("[L5V-TB][Phase B] *** PASS *** : 전체 chain OK");
        else
            $display("[L5V-TB][Phase B] *** FAIL *** : chain 에 BUG (또는 L0 양자화 propagation)");

        //==================================================================
        $display("");
        $display("[L5V-TB] ============================================================");
        $display("[L5V-TB] Phase A (standalone L5)  : %s (mismatch=%0d)",
                 (mm_l5_A == 0) ? "PASS" : "FAIL", mm_l5_A);
        $display("[L5V-TB] Phase B (L0→...→L5 chain): %s (mismatch=%0d)",
                 (mm_l5_B == 0) ? "PASS" : "FAIL", mm_l5_B);
        $display("[L5V-TB] ============================================================");

        #(20*CLK_PERIOD) $finish;
    end

    // ── Watchdog ──────────────────────────────────────────────────────
    initial begin
        repeat(60_000) #(1_000_000);   // 60s sim time
        $display("[L5V-TB] *** TIMEOUT ***");
        $finish;
    end

    // ── 간단 layer 추적 ───────────────────────────────────────────────
    reg [4:0] prev_li;
    initial prev_li = 5'h1F;
    always @(posedge clk) begin
        if (rstn && u_yolo_engine.layer_idx !== prev_li) begin
            $display("[L5V-TB][%0t] >>> layer_idx %0d → %0d <<<",
                     $time, prev_li, u_yolo_engine.layer_idx);
            prev_li <= u_yolo_engine.layer_idx;
        end
    end

`endif

endmodule
