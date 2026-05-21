`timescale 1ns / 1ns
//----------------------------------------------------------------------
// yolo_engine_l2_tb.v — Per-layer TB (Layer 2: Conv 128×128×16 → 128×128×32)
//
// 목적:
//   L1 → L2 데이터 전달 (DRAM → ifm_line_buf → conv_top) 경로의 결함을
//   추적한다. 본 TB 는 L1 의 골든 출력 (CONV02_input.hex) 을 L2 IFM 포맷으로
//   직접 DRAM 에 적재하므로, L1 출력의 진위와 무관하게 L2 자체의 동작을
//   격리 검증한다.
//
// L2 IFM 형식 (DRAM):
//   H=128, W=128, Ci=16  →  W_blocks=32, ci_groups=4, entries_per_row=128
//   1 entry = 16 byte = 4 col × 4 ch
//   row 내 순서: ci_group-major (g 0..3), col_block-minor (cb 0..31)
//     eir = g*32 + cb
//     entry byte[col_l*4 + ch_l] = pixel(c=g*4+ch_l, h=row, w=cb*4+col_l)
//   row 별 entries = 128 × 16 B = 2048 B = 512 word
//   total = 128 row × 512 word = 65,536 word
//
// L2 IFM DRAM 시작 주소:
//   addr_ifm = dram_ofm_base + lyr_ifm_offset_w(=262144) × 4 = 0x00C0_0000 + 0x10_0000
//
// L2 OFM 형식 (DRAM):
//   Co=32, H_half=64, W_half=64  →  per filter 4096 word, total 131,072 word
//   word(fi, h2, w2) = {pix11, pix10, pix01, pix00}
//   ※ L2 도 stream_mode (OFM 131072 > 65536), rb_stream mode (IFM > 8192 entries)
//
// 비교  : DRAM[OFM_BASE + 327680 .. + 327680+131071]
//          vs  CONV02_output.hex (NCHW byte order, 524,288 byte)
//----------------------------------------------------------------------
`include "user_define_h.v"

module yolo_engine_l2_tb;

`ifdef FPGA
    initial begin
        $display("[TB][FATAL] FPGA macro enabled. Comment out `define FPGA.");
        $finish;
    end
`else

    parameter WGT_MEM   = "../../../../../../testbench/inout_data_sw/gen_wgt_dram.mem";
    parameter BIAS_MEM  = "../../../../../../testbench/inout_data_sw/gen_bias_dram.mem";
    parameter L2_IN_HEX = "../../../../../../testbench/inout_data_sw/log_feamap/CONV02_input.hex";
    parameter L2_GOLD   = "../../../../../../testbench/inout_data_sw/log_feamap/CONV02_output.hex";

    parameter CLK_PERIOD = 10;
    reg clk, rstn;
    initial begin clk = 1'b0; forever #(CLK_PERIOD/2) clk = ~clk; end

    // ── DRAM layout ───────────────────────────────────────────────────
    localparam integer DRAM_WORDS        = 4 * 1024 * 1024;
    localparam integer WGT_TOTAL_WORDS   = 2_577_152;
    localparam integer BIAS_WORD_BASE    = 32'h00A00000 >> 2;
    localparam integer BIAS_TOTAL_WORDS  = 2_294;
    localparam integer OFM_WORD_BASE     = 32'h00C00000 >> 2;
    localparam integer L2_IFM_OFF        = 262_144;     // L2 IFM 시작 word
    localparam integer L2_IFM_WORDS      = 65_536;
    localparam integer L2_OFM_OFF        = 327_680;     // L2 OFM 시작 word
    localparam integer L2_OFM_WORDS      = 131_072;

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

    // ── 골든 버퍼 ──────────────────────────────────────────────────────
    reg [7:0] golden_l1 [0:262143];   // 16 × 128 × 128 (L1 OFM = L2 IFM)
    reg [7:0] golden_l2 [0:524287];   // 32 × 128 × 128 (L2 OFM)

    // ── 시퀀스 변수 ────────────────────────────────────────────────────
    integer    di, row, g, cb, col_l, ch_l, ch, col, byte_off, word_off, bidx;
    integer    fi, hb, wb, sub_h, sub_w, pix_idx;
    integer    mismatch, mismatch_print;
    reg [31:0] dword;
    reg [7:0]  b0, b1, b2, b3, got_b, exp_b;

    initial begin
        rstn = 1'b0;

        // 1) DRAM 초기화
        for (di = 0; di < DRAM_WORDS; di = di + 1) dram[di] = 32'd0;

        // 2) WGT/BIAS 로드 (전체 .mem 사용)
        $display("[L2-TB] Loading WGT  : %s", WGT_MEM);
        $readmemh(WGT_MEM,  dram, 0,              WGT_TOTAL_WORDS - 1);
        $display("[L2-TB] Loading BIAS : %s", BIAS_MEM);
        $readmemh(BIAS_MEM, dram, BIAS_WORD_BASE, BIAS_WORD_BASE + BIAS_TOTAL_WORDS - 1);
        $display("[L2-TB] Loading L2 IN  golden : %s", L2_IN_HEX);
        $readmemh(L2_IN_HEX, golden_l1);
        $display("[L2-TB] Loading L2 OUT golden : %s", L2_GOLD);
        $readmemh(L2_GOLD,   golden_l2);

        // 3) L2 IFM 을 DRAM[OFM_BASE + L2_IFM_OFF ..] 에 packed format 으로 적재
        //    row r 에서 eir = g*32 + cb (g: 0..3, cb: 0..31, entries_per_row=128)
        //    entry byte[col_l*4 + ch_l] = pixel(c=g*4+ch_l, h=r, w=cb*4+col_l)
        //    1 entry = 16 B = 4 word, total per row = 128 × 4 = 512 word
        $display("[L2-TB] Packing L1 OFM (NCHW) → L2 IFM (4col×4ch packed)...");
        for (row = 0; row < 128; row = row + 1) begin
            for (g = 0; g < 4; g = g + 1) begin
                for (cb = 0; cb < 32; cb = cb + 1) begin
                    // entry 의 4 word 를 만든다
                    for (bidx = 0; bidx < 4; bidx = bidx + 1) begin
                        col_l = bidx;          // bidx == col_l, byte 4 개 (ch_l 0..3)
                        ch    = g * 4 + 0;    // baseline (used below per ch_l)
                        col   = cb * 4 + col_l;
                        b0 = golden_l1[(g*4+0)*16384 + row*128 + col];
                        b1 = golden_l1[(g*4+1)*16384 + row*128 + col];
                        b2 = golden_l1[(g*4+2)*16384 + row*128 + col];
                        b3 = golden_l1[(g*4+3)*16384 + row*128 + col];
                        // word offset within row (32-bit word units)
                        //   eir = g*32 + cb, byte off in row = eir*16 + col_l*4
                        //   word off in row = (eir*16 + col_l*4) / 4 = eir*4 + col_l
                        word_off = (g*32 + cb) * 4 + col_l;
                        dram[OFM_WORD_BASE + L2_IFM_OFF + row * 512 + word_off] =
                            {b3, b2, b1, b0};
                    end
                end
            end
        end
        $display("[L2-TB] DRAM[L2_IFM+0]=%08x  [+1]=%08x  [+512(row1)]=%08x  [+65535(end)]=%08x",
                 dram[OFM_WORD_BASE+L2_IFM_OFF+0],
                 dram[OFM_WORD_BASE+L2_IFM_OFF+1],
                 dram[OFM_WORD_BASE+L2_IFM_OFF+512],
                 dram[OFM_WORD_BASE+L2_IFM_OFF+65535]);
        // 위 라인이 0 이 아니어야 한다 — DRAM packing 확인용 sample

        // 4) ctrl_reg 강제 설정
        force u_yolo_engine.u_axi.slv_reg1 = 32'h0000_0000;
        force u_yolo_engine.u_axi.slv_reg2 = 32'h00B0_0000;
        force u_yolo_engine.u_axi.slv_reg3 = 32'h00C0_0000;

        // 5) Reset 해제
        #(8*CLK_PERIOD) rstn = 1'b1;
        #(4*CLK_PERIOD);

        // 6) Layer 2 시작
        @(posedge clk);
        force u_yolo_engine.layer_idx = 5'd2;
        force u_yolo_engine.top_state = 4'd1;
        $display("[L2-TB][%0t] Layer 2 START (forced ST_INIT)", $time);
        @(posedge clk);
        release u_yolo_engine.layer_idx;
        release u_yolo_engine.top_state;

        // 7) 완료 대기
        wait (u_yolo_engine.layer_idx == 5'd3);
        $display("[L2-TB][%0t] Layer 2 COMPLETED (layer_idx → 3)", $time);
        #(40*CLK_PERIOD);

        // 8) DRAM OFM sample
        $display("[L2-TB] DRAM[L2_OFM+0]=%08x  [+4096(fi=1)]=%08x  [+131071(end)]=%08x",
                 dram[OFM_WORD_BASE+L2_OFM_OFF+0],
                 dram[OFM_WORD_BASE+L2_OFM_OFF+4096],
                 dram[OFM_WORD_BASE+L2_OFM_OFF+131071]);

        // 9) 비교: L2 OFM 32 filter × 128 × 128 (NCHW) vs DRAM word(fi, h2, w2)
        //    word offset = fi*4096 + h2*64 + w2 (H_half=64, W_half=64)
        //    4 sub-pixel: byte[k] = pixel(fi, 2*h2+sub_h, 2*w2+sub_w), pix_idx=sub_h*2+sub_w
        mismatch = 0; mismatch_print = 0;
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
                                mismatch = mismatch + 1;
                                if (mismatch_print < 20) begin
                                    $display("[L2-TB MISMATCH] fi=%0d h=%0d w=%0d got=%02x exp=%02x",
                                             fi, hb*2+sub_h, wb*2+sub_w, got_b, exp_b);
                                    mismatch_print = mismatch_print + 1;
                                end
                            end
                        end
                    end
                end
            end
        end
        $display("[L2-TB] -------------------- L2 OFM 비교 결과 --------------------");
        if (mismatch == 0) $display("[L2-TB] *** PASS: L2 OFM all 524,288 px match ***");
        else               $display("[L2-TB] *** FAIL: %0d mismatches / 524,288 ***", mismatch);

        #(20*CLK_PERIOD) $finish;
    end

    // ── Watchdog ──────────────────────────────────────────────────────
    initial begin
        repeat(2_000) #(1_000_000);
        $display("[L2-TB] *** TIMEOUT ***");
        $finish;
    end

    // ── FSM 추적 ──────────────────────────────────────────────────────
    reg [3:0] prev_ts;
    reg [4:0] prev_li;
    initial begin prev_ts = 4'hF; prev_li = 5'h1F; end
    always @(posedge clk) begin
        if (rstn) begin
            if (u_yolo_engine.top_state !== prev_ts) begin
                $display("[L2-TB][%0t] L%0d top_state %0d→%0d  rb=%0d rb_stream=%0d",
                         $time, u_yolo_engine.layer_idx, prev_ts, u_yolo_engine.top_state,
                         u_yolo_engine.rb_stream_rb_r, u_yolo_engine.rb_stream_mode_r);
                prev_ts <= u_yolo_engine.top_state;
            end
            if (u_yolo_engine.layer_idx !== prev_li) begin
                $display("[L2-TB][%0t] layer_idx %0d→%0d", $time, prev_li, u_yolo_engine.layer_idx);
                prev_li <= u_yolo_engine.layer_idx;
            end
        end
    end

    // ── IFM DMA progress (rb_stream 의 매 phase 첫 entry / 마지막 entry) ──
    //    entries_per_row=128, 매 row 의 (eir=0) 만 출력
    integer ifm_wr_total;
    initial ifm_wr_total = 0;
    always @(posedge clk) begin
        if (rstn && u_yolo_engine.dma_lb_wr_en) begin
            ifm_wr_total <= ifm_wr_total + 1;
            if (u_yolo_engine.dma_ifm_eir_r == 12'd0) begin
                $display("[L2-TB][%0t] IFM_LB WR row=%0d bank=%0d addr=%0d data[31:0]=%08x (row begin)",
                         $time, u_yolo_engine.dma_ifm_row_r,
                         u_yolo_engine.dma_lb_wr_line,
                         u_yolo_engine.dma_lb_wr_addr,
                         u_yolo_engine.dma_lb_wr_data[31:0]);
            end
            // entries_per_row=128 의 마지막 entry (eir=127)
            if (u_yolo_engine.dma_ifm_eir_r == 12'd127) begin
                $display("[L2-TB][%0t] IFM_LB WR row=%0d bank=%0d addr=%0d data[31:0]=%08x (row end)",
                         $time, u_yolo_engine.dma_ifm_row_r,
                         u_yolo_engine.dma_lb_wr_line,
                         u_yolo_engine.dma_lb_wr_addr,
                         u_yolo_engine.dma_lb_wr_data[31:0]);
            end
        end
    end

    // ── rb_stream 진행 ────────────────────────────────────────────────
    reg [11:0] prev_rb_r;
    initial prev_rb_r = 12'hFFF;
    always @(posedge clk) begin
        if (rstn) begin
            if (u_yolo_engine.rb_stream_rb_r !== prev_rb_r) begin
                $display("[L2-TB][%0t] rb_stream rb=%0d (mode=%0d, ifm_first=%0d, conv_h_half=%0d)",
                         $time, u_yolo_engine.rb_stream_rb_r,
                         u_yolo_engine.rb_stream_mode_r,
                         u_yolo_engine.rb_stream_ifm_first_r,
                         u_yolo_engine.conv_h_half_r);
                prev_rb_r <= u_yolo_engine.rb_stream_rb_r;
            end
        end
    end

    // ── line_buf read 추적 (각 acc_cyc=0 / 새 conv 좌표 진입) ─────────
    //    너무 많으므로 sample 만: rb=0 의 첫 64 cycle
    integer lb_rd_cnt;
    initial lb_rd_cnt = 0;
    always @(posedge clk) begin
        if (rstn && u_yolo_engine.conv_ifm_re && lb_rd_cnt < 32) begin
            $display("[L2-TB][%0t] LB RD row=%0d col=%0d acc=%0d  ifm00[31:0]=%08x ifm01[31:0]=%08x",
                     $time, u_yolo_engine.conv_ifm_row,
                     u_yolo_engine.conv_ifm_col,
                     u_yolo_engine.conv_ifm_acc,
                     u_yolo_engine.ifm_00[31:0],
                     u_yolo_engine.ifm_01[31:0]);
            lb_rd_cnt <= lb_rd_cnt + 1;
        end
    end

    // ── 첫 16 개 conv pixel 출력 ─────────────────────────────────────
    integer conv_pix_cnt;
    initial conv_pix_cnt = 0;
    always @(posedge clk) begin
        if (rstn && u_yolo_engine.conv_pixel_vld && conv_pix_cnt < 16) begin
            $display("[L2-TB][%0t] CONV PIX vld addr=%0d data=%08x",
                     $time, u_yolo_engine.conv_ofm_addr, u_yolo_engine.conv_pixel);
            conv_pix_cnt <= conv_pix_cnt + 1;
        end
    end

    // ── Filter 완료 추적 ─────────────────────────────────────────────
    reg prev_fil_done;
    initial prev_fil_done = 1'b0;
    always @(posedge clk) begin
        if (rstn) begin
            prev_fil_done <= u_yolo_engine.conv_fil_done;
            if (u_yolo_engine.conv_fil_done && !prev_fil_done)
                $display("[L2-TB][%0t] conv_fil_done stream_fil=%0d rb=%0d",
                         $time, u_yolo_engine.stream_fil_cnt,
                         u_yolo_engine.rb_stream_rb_r);
        end
    end

    // ── OFM DMA write 추적 ───────────────────────────────────────────
    reg prev_dma_wr_start;
    initial prev_dma_wr_start = 1'b0;
    integer dma_wr_cnt;
    initial dma_wr_cnt = 0;
    always @(posedge clk) begin
        if (rstn) begin
            prev_dma_wr_start <= u_yolo_engine.dma_wr_start;
            if (u_yolo_engine.dma_wr_start && !prev_dma_wr_start) begin
                dma_wr_cnt <= dma_wr_cnt + 1;
                if (dma_wr_cnt < 8 || dma_wr_cnt[3:0] == 4'd0)
                    $display("[L2-TB][%0t] OFM DMA #%0d  addr=%08x len=%0d  rb=%0d",
                             $time, dma_wr_cnt, u_yolo_engine.dma_wr_start_addr,
                             u_yolo_engine.dma_wr_num_trans,
                             u_yolo_engine.rb_stream_rb_r);
            end
        end
    end

`endif

endmodule
