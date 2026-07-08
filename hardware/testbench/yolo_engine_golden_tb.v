`timescale 1ns / 1ns
//----------------------------------------------------------------------
// yolo_engine_golden_tb.v — 22-layer 골든 비교 TB
//
// 기존 yolo_engine_tb.v 와 별개로 작성 (기존 파일 유지).
// gen_sim_dram.py 로 미리 생성된 .mem 파일을 $readmemh 로 로드.
// double-inference (L19 concat) 후 L14, L20 OFM 을 골든과 비교.
//
// 사전 준비:
//   python3 yolohw/sim/gen_sim_dram.py
//----------------------------------------------------------------------
`include "user_define_h.v"

module yolo_engine_golden_tb;

`ifdef FPGA
    initial begin
        $display("[TB][FATAL] FPGA macro enabled. Comment out `define FPGA.");
        $finish;
    end
`else

    // ── 파일 경로 (Vivado sim 작업 디렉토리 기준 상대 경로) ──────────────
    parameter WGT_MEM   = "../../../../../../sim/inout_data_sw/gen_wgt_dram.mem";
    parameter BIAS_MEM  = "../../../../../../sim/inout_data_sw/gen_bias_dram.mem";
    parameter IFM_MEM   = "../../../../../../sim/inout_data_sw/gen_ifm_dram.mem";
    parameter L14_GOLD  = "../../../../../../sim/inout_data_sw/log_feamap/CONV14_output.hex";
    parameter L20_GOLD  = "../../../../../../sim/inout_data_sw/log_feamap/CONV20_output.hex";

    parameter CLK_PERIOD = 10;
    reg clk, rstn;
    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    // ── DRAM 레이아웃 (32-bit word 단위) ────────────────────────────────
    // dram_wgt_base = 0x00000000  → WGT  from word 0
    // addr_bias     = 0x00A00000  → BIAS from word 2_621_440
    // dram_ifm_base = 0x00B00000  → IFM  from word 2_883_584
    // dram_ofm_base = 0x00C00000  → OFM  from word 3_145_728
    localparam integer DRAM_WORDS       = 4 * 1024 * 1024;  // 16 MB
    localparam integer WGT_WORD_BASE    = 0;
    localparam integer WGT_TOTAL_WORDS  = 2_577_152;
    localparam integer BIAS_WORD_BASE   = 32'h00A00000 >> 2;  // 2_621_440
    localparam integer BIAS_TOTAL_WORDS = 2_294;
    localparam integer IFM_WORD_BASE    = 32'h00B00000 >> 2;  // 2_883_584
    localparam integer IFM_TOTAL_WORDS  = 65_536;
    localparam integer OFM_WORD_BASE    = 32'h00C00000 >> 2;  // 3_145_728

    // OFM per-layer word offset (yolo_engine.v 테이블 기준)
    localparam integer L8_OFM_OFF       = 614_400;
    localparam integer L8_OFM_SIZE      = 16_384;
    localparam integer L14_OFM_OFF      = 663_552;
    localparam integer L18_OFM_OFF      = 668_720;
    localparam integer L18_OFM_SIZE     = 8_192;
    localparam integer L19_COPY_DST     = 676_912;  // = L18_OFM_OFF + L18_OFM_SIZE
    localparam integer L20_OFM_OFF      = 693_296;

    // ── AXI4-Lite slave (tied) ─────────────────────────────────────────
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

    // ── AXI4 master 신호 ───────────────────────────────────────────────
    wire        M_ARVALID, M_ARREADY;
    wire [31:0] M_ARADDR;
    wire [3:0]  M_ARID;
    wire [7:0]  M_ARLEN;
    wire [2:0]  M_ARSIZE;
    wire [1:0]  M_ARBURST, M_ARLOCK;
    wire [3:0]  M_ARCACHE;
    wire [2:0]  M_ARPROT;
    wire [3:0]  M_ARQOS, M_ARREGION, M_ARUSER;
    wire        M_RVALID, M_RREADY, M_RLAST;
    wire [31:0] M_RDATA;
    wire [3:0]  M_RID, M_RUSER;
    wire [1:0]  M_RRESP;
    wire        M_AWVALID, M_AWREADY;
    wire [31:0] M_AWADDR;
    wire [3:0]  M_AWID;
    wire [7:0]  M_AWLEN;
    wire [2:0]  M_AWSIZE;
    wire [1:0]  M_AWBURST, M_AWLOCK;
    wire [3:0]  M_AWCACHE;
    wire [2:0]  M_AWPROT;
    wire [3:0]  M_AWQOS, M_AWREGION, M_AWUSER;
    wire        M_WVALID, M_WREADY, M_WLAST;
    wire [31:0] M_WDATA;
    wire [3:0]  M_WSTRB, M_WID, M_WUSER;
    wire        M_BVALID, M_BREADY;
    wire [1:0]  M_BRESP;
    wire [3:0]  M_BID;
    wire        M_BUSER;
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
    wire _unused = network_done_led;
    /* verilator lint_on UNUSED */

    // ── Behavioral DRAM 모델 (4M × 32-bit = 16 MB) ────────────────────
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
    assign M_RID     = rd_id_r;
    assign M_RUSER   = 4'd0;
    assign M_RRESP   = 2'b00;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            rd_busy_r <= 1'b0; rd_addr_r <= 32'd0;
            rd_beat_r <= 8'd0; rd_len_r  <= 8'd0; rd_id_r <= 4'd0;
        end else begin
            if (!rd_busy_r) begin
                if (M_ARVALID) begin
                    rd_busy_r <= 1'b1; rd_addr_r <= M_ARADDR;
                    rd_len_r  <= M_ARLEN; rd_beat_r <= 8'd0; rd_id_r <= M_ARID;
                end
            end else begin
                if (M_RREADY) begin
                    if (rd_beat_r == rd_len_r) rd_busy_r <= 1'b0;
                    else begin rd_addr_r <= rd_addr_r + 32'd4; rd_beat_r <= rd_beat_r + 8'd1; end
                end
            end
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
    assign M_BRESP   = 2'b00;
    assign M_BID     = wr_id_r;
    assign M_BUSER   = 1'b0;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            wr_addr_busy_r <= 1'b0; wr_data_busy_r <= 1'b0;
            wr_resp_pending_r <= 1'b0; wr_addr_r <= 32'd0;
            wr_beat_r <= 8'd0; wr_len_r <= 8'd0; wr_id_r <= 4'd0;
        end else begin
            if (!wr_addr_busy_r && M_AWVALID) begin
                wr_addr_busy_r <= 1'b1; wr_data_busy_r <= 1'b1;
                wr_addr_r <= M_AWADDR; wr_len_r <= M_AWLEN;
                wr_beat_r <= 8'd0; wr_id_r <= M_AWID;
            end
            if (wr_data_busy_r && M_WVALID) begin
                dram[wr_addr_r[23:2]] <= M_WDATA;
                if (M_WLAST) begin
                    wr_data_busy_r <= 1'b0; wr_addr_busy_r <= 1'b0;
                    wr_resp_pending_r <= 1'b1;
                end else begin
                    wr_addr_r <= wr_addr_r + 32'd4; wr_beat_r <= wr_beat_r + 8'd1;
                end
            end
            if (wr_resp_pending_r && M_BREADY) wr_resp_pending_r <= 1'b0;
        end
    end

    // ── 골든 비교 버퍼 ────────────────────────────────────────────────
    reg [7:0] golden_l14 [0:12479];   // 195 × 8 × 8
    reg [7:0] golden_l20 [0:49919];   // 195 × 16 × 16

    // ── 메인 시퀀스 ───────────────────────────────────────────────────
    integer dram_idx, concat_i, fi, h2, w2;
    integer mismatch_l14, mismatch_l20;
    reg [31:0] dword;
    reg [7:0]  got_b, exp_b;

    // OFM word address (absolute) helpers via integer arithmetic
    integer ofm_word_base;

    initial begin
        rstn = 1'b0;
        ofm_word_base = OFM_WORD_BASE;  // 3_145_728

        // 1) DRAM 초기화
        for (dram_idx = 0; dram_idx < DRAM_WORDS; dram_idx = dram_idx + 1)
            dram[dram_idx] = 32'd0;

        // 2) .mem 로드
        $display("[TB] Loading WGT  mem: %s", WGT_MEM);
        $readmemh(WGT_MEM,  dram, 0,              WGT_TOTAL_WORDS - 1);
        $display("[TB] Loading BIAS mem: %s", BIAS_MEM);
        $readmemh(BIAS_MEM, dram, BIAS_WORD_BASE, BIAS_WORD_BASE + BIAS_TOTAL_WORDS - 1);
        $display("[TB] Loading IFM  mem: %s", IFM_MEM);
        $readmemh(IFM_MEM,  dram, IFM_WORD_BASE,  IFM_WORD_BASE  + IFM_TOTAL_WORDS  - 1);
        $display("[TB] Loading golden L14: %s", L14_GOLD);
        $readmemh(L14_GOLD, golden_l14);
        $display("[TB] Loading golden L20: %s", L20_GOLD);
        $readmemh(L20_GOLD, golden_l20);
        $display("[TB] DRAM loaded. WGT[0]=0x%08x BIAS[%0d]=0x%08x IFM[%0d]=0x%08x",
                 dram[0], BIAS_WORD_BASE, dram[BIAS_WORD_BASE],
                 IFM_WORD_BASE, dram[IFM_WORD_BASE]);

        // 3) ctrl_reg 주소 설정 (force AXI slave registers)
        force u_yolo_engine.u_axi.slv_reg1 = 32'h0000_0000;  // dram_wgt_base
        force u_yolo_engine.u_axi.slv_reg2 = 32'h00B0_0000;  // dram_ifm_base
        force u_yolo_engine.u_axi.slv_reg3 = 32'h00C0_0000;  // dram_ofm_base

        // 4) Reset 해제
        #(8*CLK_PERIOD) rstn = 1'b1;
        #(4*CLK_PERIOD);

        // ── 1차 추론 ─────────────────────────────────────────────────
        @(posedge clk);
        force u_yolo_engine.u_axi.slv_reg0 = 32'd1;
        $display("[TB] ap_start (run1) @ t=%0t", $time);
        @(posedge clk); @(posedge clk);
        force u_yolo_engine.u_axi.slv_reg0 = 32'd0;

        $display("[TB] Waiting network_done (run1)...");
        wait (network_done == 1'b1);
        $display("[TB] Run1 done @ t=%0t", $time);

        // 5) L19 Concat: L8 OFM → L18 OFM 직후 복사 (DRAM 직접 copy)
        //    src: OFM_WORD_BASE + L8_OFM_OFF   (16384 words)
        //    dst: OFM_WORD_BASE + L19_COPY_DST (= L18_OFM_OFF + L18_OFM_SIZE)
        $display("[TB] L19 concat: copying L8 OFM (%0d words) → L19_ext", L8_OFM_SIZE);
        for (concat_i = 0; concat_i < L8_OFM_SIZE; concat_i = concat_i + 1)
            dram[ofm_word_base + L19_COPY_DST + concat_i] =
                dram[ofm_word_base + L8_OFM_OFF + concat_i];
        $display("[TB] L19 concat done");

        // ── 2차 추론 ─────────────────────────────────────────────────
        #(4*CLK_PERIOD);
        @(posedge clk);
        force u_yolo_engine.u_axi.slv_reg0 = 32'd1;
        $display("[TB] ap_start (run2) @ t=%0t", $time);
        @(posedge clk); @(posedge clk);
        force u_yolo_engine.u_axi.slv_reg0 = 32'd0;

        $display("[TB] Waiting network_done (run2)...");
        wait (network_done == 1'b1);
        $display("[TB] Run2 done @ t=%0t", $time);

        // ── L14 OFM 비교 (195 × 8 × 8) ──────────────────────────────
        // DRAM 포맷: word = fi*H_half*W_half + h2*W_half + w2 (H_half=4, W_half=4)
        // 각 word 의 4 byte = 2×2 블록의 4픽셀 (sub=0..3)
        mismatch_l14 = 0;
        for (fi = 0; fi < 195; fi = fi + 1) begin
            for (h2 = 0; h2 < 4; h2 = h2 + 1) begin
                for (w2 = 0; w2 < 4; w2 = w2 + 1) begin
                    dword = dram[ofm_word_base + L14_OFM_OFF + fi*16 + h2*4 + w2];
                    // sub 0: pixel (h2*2,   w2*2)
                    got_b = dword[7:0];
                    exp_b = golden_l14[fi*64 + (h2*2)*8   + (w2*2)];
                    if (got_b !== exp_b) begin
                        if (mismatch_l14 < 8)
                            $display("[L14 MISMATCH] fi=%0d h=%0d w=%0d got=%02x exp=%02x",
                                     fi, h2*2, w2*2, got_b, exp_b);
                        mismatch_l14 = mismatch_l14 + 1;
                    end
                    // sub 1: pixel (h2*2,   w2*2+1)
                    got_b = dword[15:8];
                    exp_b = golden_l14[fi*64 + (h2*2)*8   + (w2*2+1)];
                    if (got_b !== exp_b) begin
                        if (mismatch_l14 < 8)
                            $display("[L14 MISMATCH] fi=%0d h=%0d w=%0d got=%02x exp=%02x",
                                     fi, h2*2, w2*2+1, got_b, exp_b);
                        mismatch_l14 = mismatch_l14 + 1;
                    end
                    // sub 2: pixel (h2*2+1, w2*2)
                    got_b = dword[23:16];
                    exp_b = golden_l14[fi*64 + (h2*2+1)*8 + (w2*2)];
                    if (got_b !== exp_b) begin
                        if (mismatch_l14 < 8)
                            $display("[L14 MISMATCH] fi=%0d h=%0d w=%0d got=%02x exp=%02x",
                                     fi, h2*2+1, w2*2, got_b, exp_b);
                        mismatch_l14 = mismatch_l14 + 1;
                    end
                    // sub 3: pixel (h2*2+1, w2*2+1)
                    got_b = dword[31:24];
                    exp_b = golden_l14[fi*64 + (h2*2+1)*8 + (w2*2+1)];
                    if (got_b !== exp_b) begin
                        if (mismatch_l14 < 8)
                            $display("[L14 MISMATCH] fi=%0d h=%0d w=%0d got=%02x exp=%02x",
                                     fi, h2*2+1, w2*2+1, got_b, exp_b);
                        mismatch_l14 = mismatch_l14 + 1;
                    end
                end
            end
        end
        if (mismatch_l14 == 0)
            $display("[TB] L14 OFM: ALL MATCH (12480 pixels)");
        else
            $display("[TB] L14 OFM: %0d MISMATCHES / 12480", mismatch_l14);

        // ── L20 OFM 비교 (195 × 16 × 16) ────────────────────────────
        // H_half=8, W_half=8 → word = fi*64 + h2*8 + w2
        mismatch_l20 = 0;
        for (fi = 0; fi < 195; fi = fi + 1) begin
            for (h2 = 0; h2 < 8; h2 = h2 + 1) begin
                for (w2 = 0; w2 < 8; w2 = w2 + 1) begin
                    dword = dram[ofm_word_base + L20_OFM_OFF + fi*64 + h2*8 + w2];
                    // sub 0
                    got_b = dword[7:0];
                    exp_b = golden_l20[fi*256 + (h2*2)*16   + (w2*2)];
                    if (got_b !== exp_b) begin
                        if (mismatch_l20 < 8)
                            $display("[L20 MISMATCH] fi=%0d h=%0d w=%0d got=%02x exp=%02x",
                                     fi, h2*2, w2*2, got_b, exp_b);
                        mismatch_l20 = mismatch_l20 + 1;
                    end
                    // sub 1
                    got_b = dword[15:8];
                    exp_b = golden_l20[fi*256 + (h2*2)*16   + (w2*2+1)];
                    if (got_b !== exp_b) begin
                        if (mismatch_l20 < 8)
                            $display("[L20 MISMATCH] fi=%0d h=%0d w=%0d got=%02x exp=%02x",
                                     fi, h2*2, w2*2+1, got_b, exp_b);
                        mismatch_l20 = mismatch_l20 + 1;
                    end
                    // sub 2
                    got_b = dword[23:16];
                    exp_b = golden_l20[fi*256 + (h2*2+1)*16 + (w2*2)];
                    if (got_b !== exp_b) begin
                        if (mismatch_l20 < 8)
                            $display("[L20 MISMATCH] fi=%0d h=%0d w=%0d got=%02x exp=%02x",
                                     fi, h2*2+1, w2*2, got_b, exp_b);
                        mismatch_l20 = mismatch_l20 + 1;
                    end
                    // sub 3
                    got_b = dword[31:24];
                    exp_b = golden_l20[fi*256 + (h2*2+1)*16 + (w2*2+1)];
                    if (got_b !== exp_b) begin
                        if (mismatch_l20 < 8)
                            $display("[L20 MISMATCH] fi=%0d h=%0d w=%0d got=%02x exp=%02x",
                                     fi, h2*2+1, w2*2+1, got_b, exp_b);
                        mismatch_l20 = mismatch_l20 + 1;
                    end
                end
            end
        end
        if (mismatch_l20 == 0)
            $display("[TB] L20 OFM: ALL MATCH (49920 pixels)");
        else
            $display("[TB] L20 OFM: %0d MISMATCHES / 49920", mismatch_l20);

        // ── 최종 결과 ─────────────────────────────────────────────────
        if (mismatch_l14 == 0 && mismatch_l20 == 0)
            $display("[TB] *** PASS: L14 + L20 모두 골든 일치 ***");
        else
            $display("[TB] *** FAIL: L14=%0d  L20=%0d mismatches ***",
                     mismatch_l14, mismatch_l20);

        #(10*CLK_PERIOD) $finish;
    end

    // ── Watchdog (overflow 방지: repeat × 단계 방식) ──────────────────
    // 1단계 = 1_000_000 ns = 100_000 cycles (10ns clk)
    // 10_000 단계 = 1_000_000_000 cycles 총 타임아웃
    initial begin
        repeat(10_000) #(1_000_000);
        $display("[TB] *** TIMEOUT (1G cycles) ***");
        $finish;
    end

    // ── Progress: top_state / layer_idx 변화 출력 ──────────────────────
    reg [3:0] prev_ts;
    always @(posedge clk) begin
        if (rstn) begin
            if (u_yolo_engine.top_state !== prev_ts) begin
                $display("[TB][%0t] layer=%0d top_state %0d→%0d",
                         $time,
                         u_yolo_engine.layer_idx,
                         prev_ts,
                         u_yolo_engine.top_state);
                prev_ts <= u_yolo_engine.top_state;
            end
        end else begin
            prev_ts <= 4'd15;
        end
    end

    // ── Filter-done heartbeat (stream_mode/stream_wgt_mode 진행 확인) ───
    // stream_mode(L0,L2): stream_fil_cnt 출력
    // stream_wgt_mode(L6+): wgt_fil_cnt 출력
    reg prev_fil_done;
    always @(posedge clk) begin
        if (!rstn) begin
            prev_fil_done <= 1'b0;
        end else begin
            prev_fil_done <= u_yolo_engine.conv_fil_done;
            if (u_yolo_engine.conv_fil_done && !prev_fil_done)
                $display("[TB][%0t] layer=%0d fil_done stream_fil=%0d wgt_fil=%0d",
                         $time,
                         u_yolo_engine.layer_idx,
                         u_yolo_engine.stream_fil_cnt,
                         u_yolo_engine.wgt_fil_cnt);
        end
    end

`endif  // !FPGA

endmodule
