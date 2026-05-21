`timescale 1ns / 1ns
//----------------------------------------------------------------------
// yolo_engine_l0_io_tb.v — L0 입력/출력 검증 TB (신규 작성)
//
// 목적:
//   ┌──────────────────────────────────────────────────────────────┐
//   │ (A) 입력 검증 : DRAM[IFM] → ifm_line_buf 로의 IFM DMA 가      │
//   │                올바르게 동작하는지 (transaction 수 / 적재 sample)│
//   │ (B) 출력 검증 : conv 결과 → DRAM[OFM] 가 골든과 일치하는지     │
//   └──────────────────────────────────────────────────────────────┘
//
// L0 사양 (yolo_engine.v case 5'd0):
//   conv 3×3, Ci=3, Co=16, 256×256×3 → 256×256×16, shift=8
//   weight = 16 × 1 × 16 word = 256 word
//   bias   = 16 word
//   acc_len = 1, ci_groups = 1
//
// 실행 시나리오:
//   1) DRAM 모델 초기화 → gen_*_dram.mem 로 weight/bias/IFM 적재
//   2) ctrl_reg force : wgt_base=0x0, ifm_base=0x00B0_0000, ofm_base=0x00C0_0000
//   3) force layer_idx=0, top_state=ST_INIT → release
//   4) FSM 이 자동으로 LOAD_WGT → LOAD_BIAS → RB_DMA_IFM → CONV → RB_DMA_OFM
//      × 128 rb 진행. layer_idx 가 1 로 전이되면 L0 완료.
//   5) DRAM[OFM @ L0 offset] 를 CONV00_output.hex (NCHW, byte) 와 비교
//
// 비교 포맷:
//   DRAM word @ ofm_base + fi*16384 + hb*128 + wb (32-bit)
//     byte[0] = OFM[fi, hb*2  , wb*2  ]
//     byte[1] = OFM[fi, hb*2  , wb*2+1]
//     byte[2] = OFM[fi, hb*2+1, wb*2  ]
//     byte[3] = OFM[fi, hb*2+1, wb*2+1]
//   Golden NCHW (byte): golden_l0[fi*65536 + h*256 + w]
//----------------------------------------------------------------------
`include "user_define_h.v"

module yolo_engine_l0_io_tb;

`ifdef FPGA
    initial begin
        $display("[L0-IO-TB][FATAL] FPGA macro enabled. Comment out `define FPGA.");
        $finish;
    end
`else

    // ── 파일 경로 (Vivado xsim 작업 디렉토리 기준) ────────────────────────
    parameter WGT_MEM  = "../../../../../../testbench/inout_data_sw/gen_wgt_dram.mem";
    parameter BIAS_MEM = "../../../../../../testbench/inout_data_sw/gen_bias_dram.mem";
    parameter IFM_MEM  = "../../../../../../testbench/inout_data_sw/gen_ifm_dram.mem";
    parameter L0_GOLD  = "../../../../../../testbench/inout_data_sw/log_feamap/CONV00_output.hex";

    parameter CLK_PERIOD = 10;
    reg clk, rstn;
    initial begin clk = 1'b0; forever #(CLK_PERIOD/2) clk = ~clk; end

    // ── DRAM 레이아웃 (32-bit word 단위) ──────────────────────────────────
    localparam integer DRAM_WORDS       = 4 * 1024 * 1024;     // 16 MB
    localparam integer WGT_TOTAL_WORDS  = 2_577_152;
    localparam integer BIAS_WORD_BASE   = 32'h00A00000 >> 2;   // 2_621_440
    localparam integer BIAS_TOTAL_WORDS = 2_294;
    localparam integer IFM_WORD_BASE    = 32'h00B00000 >> 2;   // 2_883_584
    localparam integer IFM_TOTAL_WORDS  = 65_536;
    localparam integer OFM_WORD_BASE    = 32'h00C00000 >> 2;   // 3_145_728
    localparam integer L0_OFM_OFF       = 0;                   // L0 OFM @ ofm_base + 0
    localparam integer L0_OFM_WORDS     = 16 * 128 * 128;      // 262_144

    // ── AXI4-Lite slave (tied off, 내부 force 로 ctrl_reg 주입) ───────────
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

    // ── AXI4 master 신호 ──────────────────────────────────────────────────
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

    // ── DUT ───────────────────────────────────────────────────────────────
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

    // ── Behavioral DRAM (4M × 32-bit) ─────────────────────────────────────
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
        if (!rstn) begin
            rd_busy_r<=0; rd_addr_r<=0; rd_beat_r<=0; rd_len_r<=0; rd_id_r<=0;
        end else if (!rd_busy_r) begin
            if (M_ARVALID) begin
                rd_busy_r<=1; rd_addr_r<=M_ARADDR;
                rd_len_r<=M_ARLEN; rd_beat_r<=0; rd_id_r<=M_ARID;
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

    // ── 골든 버퍼 ─────────────────────────────────────────────────────────
    reg [7:0] golden_l0 [0:1048575];   // 16 × 256 × 256

    // ── 시퀀스 변수 ───────────────────────────────────────────────────────
    integer di, fi, hb, wb, sub;
    integer mismatch_total, mismatch_print;
    integer mismatch_by_fil [0:15];
    reg [31:0] dword;
    reg [7:0]  got_b, exp_b;
    integer    exp_h, exp_w;

    // ── 메인 시퀀스 ───────────────────────────────────────────────────────
    initial begin
        rstn = 1'b0;

        // 1) DRAM 초기화
        for (di = 0; di < DRAM_WORDS; di = di + 1) dram[di] = 32'd0;
        for (fi = 0; fi < 16; fi = fi + 1) mismatch_by_fil[fi] = 0;

        // 2) .mem 적재
        $display("[L0-IO-TB] Loading WGT  mem: %s", WGT_MEM);
        $readmemh(WGT_MEM,  dram, 0,              WGT_TOTAL_WORDS - 1);
        $display("[L0-IO-TB] Loading BIAS mem: %s", BIAS_MEM);
        $readmemh(BIAS_MEM, dram, BIAS_WORD_BASE, BIAS_WORD_BASE + BIAS_TOTAL_WORDS - 1);
        $display("[L0-IO-TB] Loading IFM  mem: %s", IFM_MEM);
        $readmemh(IFM_MEM,  dram, IFM_WORD_BASE,  IFM_WORD_BASE  + IFM_TOTAL_WORDS  - 1);
        $display("[L0-IO-TB] Loading L0 golden : %s", L0_GOLD);
        $readmemh(L0_GOLD, golden_l0);
        $display("[L0-IO-TB] DRAM ready. WGT[0]=%08x BIAS[%0d]=%08x IFM[%0d]=%08x",
                 dram[0], BIAS_WORD_BASE, dram[BIAS_WORD_BASE],
                 IFM_WORD_BASE, dram[IFM_WORD_BASE]);

        // 3) ctrl_reg force
        force u_yolo_engine.u_axi.slv_reg1 = 32'h0000_0000;   // dram_wgt_base
        force u_yolo_engine.u_axi.slv_reg2 = 32'h00B0_0000;   // dram_ifm_base
        force u_yolo_engine.u_axi.slv_reg3 = 32'h00C0_0000;   // dram_ofm_base

        // 4) Reset 해제
        #(8*CLK_PERIOD) rstn = 1'b1;
        #(4*CLK_PERIOD);

        // 5) Layer 0 시작 — ST_INIT 로 force-jump
        @(posedge clk);
        force u_yolo_engine.layer_idx = 5'd0;
        force u_yolo_engine.top_state = 5'd1;     // ST_INIT
        $display("[L0-IO-TB][%0t] Layer 0 START (forced ST_INIT)", $time);
        @(posedge clk);
        release u_yolo_engine.layer_idx;
        release u_yolo_engine.top_state;

        // 6) L0 완료 대기 (layer_idx 0→1 전이)
        wait (u_yolo_engine.layer_idx == 5'd1);
        $display("[L0-IO-TB][%0t] Layer 0 COMPLETED (layer_idx → 1)", $time);
        #(20*CLK_PERIOD);

        // 7) DRAM[L0 OFM] sample 출력
        $display("[L0-IO-TB] DRAM[L0+0]=%08x  [L0+16384(fi=1)]=%08x  [L0+245760(fi=15)]=%08x",
                 dram[OFM_WORD_BASE+L0_OFM_OFF+0],
                 dram[OFM_WORD_BASE+L0_OFM_OFF+16384],
                 dram[OFM_WORD_BASE+L0_OFM_OFF+245760]);

        // ============================================================
        // (B) 출력 비교
        //     - DRAM word 에서 4 sub-pixel 을 꺼내 NCHW 골든과 비교
        // ============================================================
        mismatch_total = 0; mismatch_print = 0;
        for (fi = 0; fi < 16; fi = fi + 1) begin
            for (hb = 0; hb < 128; hb = hb + 1) begin
                for (wb = 0; wb < 128; wb = wb + 1) begin
                    dword = dram[OFM_WORD_BASE + L0_OFM_OFF + fi*16384 + hb*128 + wb];
                    for (sub = 0; sub < 4; sub = sub + 1) begin
                        // sub : 0=(h,w)=(hb*2  , wb*2  )
                        //       1=(hb*2  , wb*2+1)
                        //       2=(hb*2+1, wb*2  )
                        //       3=(hb*2+1, wb*2+1)
                        exp_h = hb*2 + (sub >> 1);
                        exp_w = wb*2 + (sub & 1);
                        got_b = dword[sub*8 +: 8];
                        exp_b = golden_l0[fi*65536 + exp_h*256 + exp_w];
                        if (got_b !== exp_b) begin
                            mismatch_total = mismatch_total + 1;
                            mismatch_by_fil[fi] = mismatch_by_fil[fi] + 1;
                            if (mismatch_print < 16) begin
                                $display("[L0 MISMATCH] fi=%0d h=%0d w=%0d got=%02x exp=%02x",
                                         fi, exp_h, exp_w, got_b, exp_b);
                                mismatch_print = mismatch_print + 1;
                            end
                        end
                    end
                end
            end
        end

        $display("[L0-IO-TB] -------------------- L0 OFM 비교 결과 --------------------");
        for (fi = 0; fi < 16; fi = fi + 1)
            $display("[L0-IO-TB]   fi=%2d  mismatch=%0d / 65536", fi, mismatch_by_fil[fi]);
        $display("[L0-IO-TB] TOTAL mismatch = %0d / %0d byte", mismatch_total, 16*256*256);
        if (mismatch_total == 0)
            $display("[L0-IO-TB] *** PASS : L0 입출력 모두 정상 ***");
        else
            $display("[L0-IO-TB] *** FAIL : L0 OFM 골든 불일치 ***");

        #(20*CLK_PERIOD) $finish;
    end

    // ── Watchdog ──────────────────────────────────────────────────────────
    initial begin
        repeat(2000) #(1_000_000);
        $display("[L0-IO-TB] *** TIMEOUT ***");
        $finish;
    end

    // ── FSM 추적 (top_state / layer_idx) ──────────────────────────────────
    reg [4:0] prev_ts;
    reg [4:0] prev_li;
    initial begin prev_ts = 5'h1F; prev_li = 5'h1F; end
    always @(posedge clk) begin
        if (rstn) begin
            if (u_yolo_engine.top_state !== prev_ts) begin
                $display("[L0-IO-TB][%0t] L%0d top_state %0d→%0d",
                         $time, u_yolo_engine.layer_idx,
                         prev_ts, u_yolo_engine.top_state);
                prev_ts <= u_yolo_engine.top_state;
            end
            if (u_yolo_engine.layer_idx !== prev_li) begin
                $display("[L0-IO-TB][%0t] layer_idx %0d→%0d",
                         $time, prev_li, u_yolo_engine.layer_idx);
                prev_li <= u_yolo_engine.layer_idx;
            end
        end
    end

    // ============================================================
    // (A) 입력 모니터링
    //   - IFM DMA RD start 마다 addr / len 출력
    //   - asm_full && DMA_TGT_IFM 인 entry (= ifm_line_buf write) 총 개수,
    //     첫 8개 sample 출력
    // ============================================================
    reg prev_dma_rd_start;
    integer ifm_dma_call_cnt;
    integer ifm_entries_total;
    integer ifm_entry_print_cnt;
    initial begin
        prev_dma_rd_start  = 1'b0;
        ifm_dma_call_cnt   = 0;
        ifm_entries_total  = 0;
        ifm_entry_print_cnt= 0;
    end

    always @(posedge clk) begin
        if (rstn) begin
            prev_dma_rd_start <= u_yolo_engine.dma_rd_start;

            // DMA RD 시작 시점에 target = IFM 인 것만 출력
            if (u_yolo_engine.dma_rd_start && !prev_dma_rd_start &&
                u_yolo_engine.dma_target_r == 2'd3 /* DMA_TGT_IFM */) begin
                $display("[L0-IO-TB][%0t] IFM DMA RD start  rb=%0d  addr=%08x  num_trans=%0d  row_start=%0d",
                         $time,
                         u_yolo_engine.rb_r,
                         u_yolo_engine.dma_rd_start_addr,
                         u_yolo_engine.dma_rd_num_trans,
                         u_yolo_engine.dma_ifm_row_start_r);
                ifm_dma_call_cnt <= ifm_dma_call_cnt + 1;
            end

            // ifm_line_buf write 카운트 + 처음 8개 entry 출력
            if (u_yolo_engine.dma_lb_wr_en) begin
                ifm_entries_total <= ifm_entries_total + 1;
                if (ifm_entry_print_cnt < 8) begin
                    $display("[L0-IO-TB][%0t] IFM-LB WR  line(bank)=%0d  addr=%0d  data=%032x",
                             $time,
                             u_yolo_engine.dma_lb_wr_line,
                             u_yolo_engine.dma_lb_wr_addr,
                             u_yolo_engine.dma_lb_wr_data);
                    ifm_entry_print_cnt <= ifm_entry_print_cnt + 1;
                end
            end
        end
    end

    // ============================================================
    // (B-aux) 출력 모니터링
    //   - OFM DMA WR start 횟수 / 첫 / 마지막 transaction 출력
    //   - conv_pixel_vld 총 카운트 (= dpram 에 기록된 word 수)
    // ============================================================
    reg prev_dma_wr_start;
    integer ofm_dma_call_cnt;
    integer conv_pixel_cnt;
    initial begin
        prev_dma_wr_start = 1'b0;
        ofm_dma_call_cnt  = 0;
        conv_pixel_cnt    = 0;
    end

    always @(posedge clk) begin
        if (rstn) begin
            prev_dma_wr_start <= u_yolo_engine.dma_wr_start;

            if (u_yolo_engine.dma_wr_start && !prev_dma_wr_start) begin
                // 첫 3개 + 마지막 근처만 출력하면 충분
                if (ofm_dma_call_cnt < 3 || ofm_dma_call_cnt >= 2045) begin
                    $display("[L0-IO-TB][%0t] OFM DMA WR start  rb=%0d  fil=%0d  addr=%08x  num_trans=%0d  (#%0d)",
                             $time,
                             u_yolo_engine.rb_r,
                             u_yolo_engine.ofm_fil_r,
                             u_yolo_engine.dma_wr_start_addr,
                             u_yolo_engine.dma_wr_num_trans,
                             ofm_dma_call_cnt);
                end
                ofm_dma_call_cnt <= ofm_dma_call_cnt + 1;
            end

            if (u_yolo_engine.conv_pixel_vld)
                conv_pixel_cnt <= conv_pixel_cnt + 1;
        end
    end

    // ── L0 완료 시점 요약 출력 ────────────────────────────────────────────
    reg done_summary_printed;
    initial done_summary_printed = 1'b0;
    always @(posedge clk) begin
        if (rstn && (u_yolo_engine.layer_idx == 5'd1) && !done_summary_printed) begin
            done_summary_printed <= 1'b1;
            $display("[L0-IO-TB] -------------------- L0 진행 요약 --------------------");
            $display("[L0-IO-TB]   IFM DMA RD 호출 수      : %0d  (예상 128 = 1×init + 127×next)",
                     ifm_dma_call_cnt);
            $display("[L0-IO-TB]   ifm_line_buf write 총수 : %0d  (예상 16448 = 257 row × 64 entry)",
                     ifm_entries_total);
            $display("[L0-IO-TB]   conv_pixel_vld 총수    : %0d  (예상 262144 = 16 fil × 16384)",
                     conv_pixel_cnt);
            $display("[L0-IO-TB]   OFM DMA WR 호출 수      : %0d  (예상 2048 = 128 rb × 16 fil)",
                     ofm_dma_call_cnt);
        end
    end

`endif // !FPGA

endmodule
