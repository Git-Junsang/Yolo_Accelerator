`timescale 1ns / 1ns
//----------------------------------------------------------------------
// yolo_engine_l1_tb.v — Per-layer TB (Layer 1: MaxPool stride-2)
//
// 입력  : L0 OFM  (256 × 256 × 16 = 1,048,576 byte = 262,144 OFM dpram word)
//          ※ OFM dpram 용량은 65,536 word — L0 OFM 의 4 filter 분량만 수용.
//          ※ 실제 yolo_engine 동작에서는 L0 가 stream_mode 로 매 filter 마다
//            DRAM 으로 dump 하므로, L0 완료 시점 dpram 에는 마지막 4 filter
//            (#12..#15) 만 남는다 → L1 pool 이 wrap 으로 잘못 읽는 BUG 존재.
//
//          본 TB 는 dpram 에 L0 OFM 의 FIRST 4 FILTER (#0..#3) 을 pre-load
//          하여, max_pool_unit 자체의 동작을 4 filter 기준으로 격리 검증한다.
//
// 출력  : OFM dpram 의 동일 영역에 in-place 저장 후, DMA 로 DRAM[L1_OFM_OFF]
//          에 65,536 word 전체 dump.
//
// 비교  : DRAM[OFM_BASE + 262144 .. + 262144+65535]
//          vs  CONV02_input.hex (= L1 OFM in NCHW byte order)
//          ※ filter 0..3 만 비교 (그 이상은 dpram wrap 으로 garbage)
//          ※ filter 4..15 의 garbage 분포도 출력
//
// 시작 방식:
//   force layer_idx=1, top_state=ST_INIT  →  release
//   FSM 이 ST_DMA_WGT → ST_DMA_IFM → ST_RUN_POOL → ST_DMA_OFM 순서로 진행.
//----------------------------------------------------------------------
`include "user_define_h.v"

module yolo_engine_l1_tb;

`ifdef FPGA
    initial begin
        $display("[TB][FATAL] FPGA macro enabled. Comment out `define FPGA.");
        $finish;
    end
`else

    parameter L0_OUT_HEX = "../../../../../../testbench/inout_data_sw/log_feamap/CONV00_output.hex";
    parameter L1_GOLD    = "../../../../../../testbench/inout_data_sw/log_feamap/CONV02_input.hex";

    parameter CLK_PERIOD = 10;
    reg clk, rstn;
    initial begin clk = 1'b0; forever #(CLK_PERIOD/2) clk = ~clk; end

    // ── DRAM layout ───────────────────────────────────────────────────
    localparam integer DRAM_WORDS    = 4 * 1024 * 1024;
    localparam integer OFM_WORD_BASE = 32'h00C00000 >> 2;
    localparam integer L1_OFM_OFF    = 262_144;
    localparam integer L1_OFM_WORDS  = 65_536;

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
    reg [7:0] golden_l0  [0:1048575];   // 16 × 256 × 256 (L0 OFM, NCHW)
    reg [7:0] golden_l1  [0:262143];    // 16 × 128 × 128 (L1 OFM, NCHW)

    // ── 시퀀스 변수 ────────────────────────────────────────────────────
    integer i, di, fi, hb, wb, sub_h, sub_w;
    integer rb_pool, cb_pool, c4, mismatch_f0to3, mismatch_f4to15, mismatch_print;
    integer addr_dp;
    reg [31:0] dword_pack;
    reg [7:0]  got_b, exp_b;
    reg [7:0]  p0, p1, p2, p3;

    initial begin
        rstn = 1'b0;

        // 1) DRAM 초기화
        for (di = 0; di < DRAM_WORDS; di = di + 1) dram[di] = 32'd0;

        // 2) 골든 hex 로드
        $display("[L1-TB] Loading L0 OFM golden : %s", L0_OUT_HEX);
        $readmemh(L0_OUT_HEX, golden_l0);
        $display("[L1-TB] Loading L1 OFM golden : %s", L1_GOLD);
        $readmemh(L1_GOLD, golden_l1);

        // 3) ctrl_reg 설정 (L1 은 WGT/BIAS DMA 가 skip, IFM DMA 도 skip)
        force u_yolo_engine.u_axi.slv_reg1 = 32'h0000_0000;
        force u_yolo_engine.u_axi.slv_reg2 = 32'h00B0_0000;
        force u_yolo_engine.u_axi.slv_reg3 = 32'h00C0_0000;

        // 4) Reset 해제
        #(8*CLK_PERIOD) rstn = 1'b1;
        #(4*CLK_PERIOD);

        // 5) OFM dpram 에 L0 OFM 의 first 4 filter pre-load
        //    OFM dpram 포맷: word(fi, hb, wb) at addr = fi*16384 + hb*128 + wb
        //      word = {p11, p10, p01, p00} 로 packed (4 sub-pixel)
        //      p_sh_sw = OFM[fi, 2*hb+sub_h, 2*wb+sub_w]
        //    범위: fi=0..3 (dpram 65536 word = 4 filter × 16384)
        $display("[L1-TB] Pre-loading OFM dpram with L0 OFM filters 0..3 (65,536 words)...");
        for (fi = 0; fi < 4; fi = fi + 1) begin
            for (hb = 0; hb < 128; hb = hb + 1) begin
                for (wb = 0; wb < 128; wb = wb + 1) begin
                    p0 = golden_l0[fi*65536 + (hb*2  )*256 + (wb*2  )];
                    p1 = golden_l0[fi*65536 + (hb*2  )*256 + (wb*2+1)];
                    p2 = golden_l0[fi*65536 + (hb*2+1)*256 + (wb*2  )];
                    p3 = golden_l0[fi*65536 + (hb*2+1)*256 + (wb*2+1)];
                    dword_pack = {p3, p2, p1, p0};
                    addr_dp = fi*16384 + hb*128 + wb;
                    u_yolo_engine.u_ofm.ram[addr_dp] = dword_pack;
                end
            end
        end
        $display("[L1-TB] dpram[0]=%08x  dpram[16383(end of fi=0)]=%08x  dpram[65535(end of fi=3)]=%08x",
                 u_yolo_engine.u_ofm.ram[0],
                 u_yolo_engine.u_ofm.ram[16383],
                 u_yolo_engine.u_ofm.ram[65535]);

        // 6) Layer 1 시작
        @(posedge clk);
        force u_yolo_engine.layer_idx = 5'd1;
        force u_yolo_engine.top_state = 4'd1;     // ST_INIT
        $display("[L1-TB][%0t] Layer 1 START (forced ST_INIT)", $time);
        @(posedge clk);
        release u_yolo_engine.layer_idx;
        release u_yolo_engine.top_state;

        // 7) 완료 대기
        wait (u_yolo_engine.layer_idx == 5'd2);
        $display("[L1-TB][%0t] Layer 1 COMPLETED (layer_idx → 2)", $time);
        #(40*CLK_PERIOD);

        // 8) DRAM[L1 OFM] sample 출력 (raw)
        $display("[L1-TB] DRAM[L1+0]=%08x  [L1+4096(fi=1 begin)]=%08x  [L1+16384(fi=4)]=%08x",
                 dram[OFM_WORD_BASE+L1_OFM_OFF+0],
                 dram[OFM_WORD_BASE+L1_OFM_OFF+4096],
                 dram[OFM_WORD_BASE+L1_OFM_OFF+16384]);

        // 9) 비교
        //    DRAM 포맷 (L1 OFM): word(fi, r, cb_block) at L1_OFM_OFF + fi*4096 + r*32 + cb_block
        //      word = {p3, p2, p1, p0}, p_k = pool(fi, r, cb_block*4 + k)
        //    Golden NCHW: golden_l1[fi*16384 + r*128 + c]
        mismatch_f0to3 = 0; mismatch_f4to15 = 0; mismatch_print = 0;
        for (fi = 0; fi < 16; fi = fi + 1) begin
            for (rb_pool = 0; rb_pool < 128; rb_pool = rb_pool + 1) begin
                for (cb_pool = 0; cb_pool < 32; cb_pool = cb_pool + 1) begin
                    dword_pack = dram[OFM_WORD_BASE + L1_OFM_OFF + fi*4096 + rb_pool*32 + cb_pool];
                    for (c4 = 0; c4 < 4; c4 = c4 + 1) begin
                        got_b = dword_pack[c4*8 +: 8];
                        exp_b = golden_l1[fi*16384 + rb_pool*128 + cb_pool*4 + c4];
                        if (got_b !== exp_b) begin
                            if (fi < 4) begin
                                mismatch_f0to3 = mismatch_f0to3 + 1;
                                if (mismatch_print < 16) begin
                                    $display("[L1-TB MISMATCH fi<4] fi=%0d r=%0d c=%0d got=%02x exp=%02x",
                                             fi, rb_pool, cb_pool*4+c4, got_b, exp_b);
                                    mismatch_print = mismatch_print + 1;
                                end
                            end else begin
                                mismatch_f4to15 = mismatch_f4to15 + 1;
                            end
                        end
                    end
                end
            end
        end

        $display("[L1-TB] -------------------- L1 OFM 비교 결과 --------------------");
        $display("[L1-TB] Filter 0..3   mismatches: %0d / 65,536 byte",  mismatch_f0to3);
        $display("[L1-TB] Filter 4..15  mismatches: %0d / 196,608 byte", mismatch_f4to15);
        if (mismatch_f0to3 == 0) $display("[L1-TB] *** PASS (filters 0..3): max_pool 자체 동작 OK ***");
        else                     $display("[L1-TB] *** FAIL (filters 0..3): max_pool 자체에 BUG ***");
        if (mismatch_f4to15 > 0)
            $display("[L1-TB] (예상) Filter 4..15 mismatch: dpram 용량 부족 (65,536 word < L0 OFM 262,144 word)");

        #(20*CLK_PERIOD) $finish;
    end

    // ── Watchdog ──────────────────────────────────────────────────────
    initial begin
        repeat(500) #(1_000_000);
        $display("[L1-TB] *** TIMEOUT ***");
        $finish;
    end

    // ── FSM 추적 ──────────────────────────────────────────────────────
    reg [3:0] prev_ts;
    reg [4:0] prev_li;
    initial begin prev_ts = 4'hF; prev_li = 5'h1F; end
    always @(posedge clk) begin
        if (rstn) begin
            if (u_yolo_engine.top_state !== prev_ts) begin
                $display("[L1-TB][%0t] L%0d top_state %0d→%0d",
                         $time, u_yolo_engine.layer_idx, prev_ts, u_yolo_engine.top_state);
                prev_ts <= u_yolo_engine.top_state;
            end
            if (u_yolo_engine.layer_idx !== prev_li) begin
                $display("[L1-TB][%0t] layer_idx %0d→%0d",
                         $time, prev_li, u_yolo_engine.layer_idx);
                prev_li <= u_yolo_engine.layer_idx;
            end
        end
    end

    // ── max_pool_unit 활동 모니터 ───────────────────────────────────
    //    pool 시작/종료, 처음 read addr 8 개, 처음 write 8 개
    reg prev_pool_start;
    initial prev_pool_start = 1'b0;
    integer pool_rd_cnt, pool_wr_cnt;
    initial begin pool_rd_cnt = 0; pool_wr_cnt = 0; end
    always @(posedge clk) begin
        if (rstn) begin
            prev_pool_start <= u_yolo_engine.pool_start;
            if (u_yolo_engine.pool_start && !prev_pool_start)
                $display("[L1-TB][%0t] pool_start  total_in_words=%0d",
                         $time, u_yolo_engine.pool_total_in_r);
            if (u_yolo_engine.u_pool.o_done)
                $display("[L1-TB][%0t] pool_done", $time);

            if (u_yolo_engine.u_pool.o_rd_en && pool_rd_cnt < 8) begin
                $display("[L1-TB][%0t] pool RD addr=%0d (cnt=%0d)",
                         $time, u_yolo_engine.u_pool.o_rd_addr, pool_rd_cnt);
                pool_rd_cnt <= pool_rd_cnt + 1;
            end
            if (u_yolo_engine.u_pool.o_wr_en && pool_wr_cnt < 8) begin
                $display("[L1-TB][%0t] pool WR addr=%0d data=%08x (cnt=%0d)",
                         $time, u_yolo_engine.u_pool.o_wr_addr,
                         u_yolo_engine.u_pool.o_wr_data, pool_wr_cnt);
                pool_wr_cnt <= pool_wr_cnt + 1;
            end
        end
    end

    // ── OFM DMA write 추적 ───────────────────────────────────────────
    reg prev_dma_wr_start;
    initial prev_dma_wr_start = 1'b0;
    always @(posedge clk) begin
        if (rstn) begin
            prev_dma_wr_start <= u_yolo_engine.dma_wr_start;
            if (u_yolo_engine.dma_wr_start && !prev_dma_wr_start)
                $display("[L1-TB][%0t] OFM DMA start addr=%08x len=%0d",
                         $time, u_yolo_engine.dma_wr_start_addr,
                         u_yolo_engine.dma_wr_num_trans);
            if (u_yolo_engine.dma_wr_done)
                $display("[L1-TB][%0t] OFM DMA done", $time);
        end
    end

`endif

endmodule
