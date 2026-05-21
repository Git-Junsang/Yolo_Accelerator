`timescale 1ns / 1ns
//----------------------------------------------------------------------
// yolo_engine_l0_tb.v — Per-layer TB (Layer 0: Conv 256×256×3 → 256×256×16)
//
// 목적:
//   yolo_engine 전체 FSM 을 L0 하나만 실행시켜, 데이터가 다음 구간으로
//   올바르게 흐르는지 확인한다. L1/L2 TB 가 의존하는 "L0 OFM in DRAM"
//   이 정상 생성되는지 검증.
//
// 시작 방식:
//   ap_start 가 layer_idx 를 강제로 0 으로 만들기 때문에 (FSM 코드 참조)
//   본 TB 는 reset 해제 후 layer_idx=0, top_state=ST_INIT(1) 으로 1 cycle force,
//   이후 release 하여 자연스럽게 ST_DMA_WGT 부터 진행.
//
// 종료:
//   layer_idx == 1 (ST_NEXT 에서 layer 0 완료, layer 1 로 진입한 시점)
//   를 감지하면 비교 후 $finish.
//
// 데이터 파일 (Vivado xsim cwd 기준 상대 경로):
//   ../../../../../../testbench/inout_data_sw/gen_wgt_dram.mem
//   ../../../../../../testbench/inout_data_sw/gen_bias_dram.mem
//   ../../../../../../testbench/inout_data_sw/gen_ifm_dram.mem
//   ../../../../../../testbench/inout_data_sw/log_feamap/CONV00_output.hex
//
// 비교 대상:
//   DRAM[OFM_BASE + 0 .. + 262143]  vs  CONV00_output.hex (NCHW byte order)
//   DRAM word(fi, h2, w2) = pixel(fi, 2h2..2h2+1, 2w2..2w2+1) 4 byte
//----------------------------------------------------------------------
`include "user_define_h.v"

module yolo_engine_l0_tb;

`ifdef FPGA
    initial begin
        $display("[TB][FATAL] FPGA macro enabled. Comment out `define FPGA.");
        $finish;
    end
`else

    parameter WGT_MEM   = "../../../../../../testbench/inout_data_sw/gen_wgt_dram.mem";
    parameter BIAS_MEM  = "../../../../../../testbench/inout_data_sw/gen_bias_dram.mem";
    parameter IFM_MEM   = "../../../../../../testbench/inout_data_sw/gen_ifm_dram.mem";
    parameter GOLD_HEX  = "../../../../../../testbench/inout_data_sw/log_feamap/CONV00_output.hex";

    parameter CLK_PERIOD = 10;
    reg clk, rstn;
    initial begin clk = 1'b0; forever #(CLK_PERIOD/2) clk = ~clk; end

    // ── DRAM layout (golden_tb 와 동일) ─────────────────────────────────
    localparam integer DRAM_WORDS       = 4 * 1024 * 1024;
    localparam integer WGT_TOTAL_WORDS  = 2_577_152;
    localparam integer BIAS_WORD_BASE   = 32'h00A00000 >> 2;   // 2_621_440
    localparam integer BIAS_TOTAL_WORDS = 2_294;
    localparam integer IFM_WORD_BASE    = 32'h00B00000 >> 2;   // 2_883_584
    localparam integer IFM_TOTAL_WORDS  = 65_536;
    localparam integer OFM_WORD_BASE    = 32'h00C00000 >> 2;   // 3_145_728

    // L0 OFM: Co=16, H=256, W=256 → 16 × 128 × 128 = 262_144 words
    localparam integer L0_OFM_OFF       = 0;
    localparam integer L0_OFM_WORDS     = 262_144;

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

    // ── AXI4 master ─────────────────────────────────────────────────────
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

    // ── Behavioral DRAM 모델 (16 MB) ───────────────────────────────────
    reg [31:0] dram [0:DRAM_WORDS-1];

    // ── AXI Read FSM ────────────────────────────────────────────────────
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

    // ── AXI Write FSM ──────────────────────────────────────────────────
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

    // ── 골든 비교 버퍼 (16 × 256 × 256 = 1_048_576 byte) ───────────────
    reg [7:0] golden_l0 [0:1048575];

    // ── 시퀀스 변수 ─────────────────────────────────────────────────────
    integer    di, fi, hb, wb, sub_h, sub_w, mismatch, mismatch_print;
    integer    pix_idx;
    reg [31:0] dword;
    reg [7:0]  got_b, exp_b;

    initial begin
        rstn = 1'b0;

        // 1) DRAM 초기화
        for (di = 0; di < DRAM_WORDS; di = di + 1) dram[di] = 32'd0;

        // 2) .mem 로드
        $display("[L0-TB] Loading WGT  : %s", WGT_MEM);
        $readmemh(WGT_MEM,  dram, 0,              WGT_TOTAL_WORDS - 1);
        $display("[L0-TB] Loading BIAS : %s", BIAS_MEM);
        $readmemh(BIAS_MEM, dram, BIAS_WORD_BASE, BIAS_WORD_BASE + BIAS_TOTAL_WORDS - 1);
        $display("[L0-TB] Loading IFM  : %s", IFM_MEM);
        $readmemh(IFM_MEM,  dram, IFM_WORD_BASE,  IFM_WORD_BASE  + IFM_TOTAL_WORDS  - 1);
        $display("[L0-TB] Loading GOLD : %s", GOLD_HEX);
        $readmemh(GOLD_HEX, golden_l0);

        $display("[L0-TB] DRAM[0]=%08x  IFM[%0d]=%08x  GOLD[0]=%02x",
                 dram[0], IFM_WORD_BASE, dram[IFM_WORD_BASE], golden_l0[0]);

        // 3) ctrl_reg 강제 설정
        force u_yolo_engine.u_axi.slv_reg1 = 32'h0000_0000;  // dram_wgt_base
        force u_yolo_engine.u_axi.slv_reg2 = 32'h00B0_0000;  // dram_ifm_base
        force u_yolo_engine.u_axi.slv_reg3 = 32'h00C0_0000;  // dram_ofm_base

        // 4) Reset 해제
        #(8*CLK_PERIOD) rstn = 1'b1;
        #(4*CLK_PERIOD);

        // 5) L0 시작: layer_idx=0, top_state=ST_INIT(1) force → release
        @(posedge clk);
        force u_yolo_engine.layer_idx = 5'd0;
        force u_yolo_engine.top_state = 4'd1;     // ST_INIT
        $display("[L0-TB][%0t] Layer 0 START (forced ST_INIT)", $time);
        @(posedge clk);
        release u_yolo_engine.layer_idx;
        release u_yolo_engine.top_state;

        // 6) 완료 대기: layer_idx 가 1 로 증가 (ST_NEXT 에서 +1)
        wait (u_yolo_engine.layer_idx == 5'd1);
        $display("[L0-TB][%0t] Layer 0 COMPLETED (layer_idx → 1)", $time);
        #(40*CLK_PERIOD);

        // 7) OFM 비교
        //    DRAM word(fi, h2, w2) at OFM_WORD_BASE + L0_OFM_OFF + fi*128*128 + h2*128 + w2
        //    word bits = {pix11, pix10, pix01, pix00}
        //      pix00 = OFM(fi, 2*h2,   2*w2  )
        //      pix01 = OFM(fi, 2*h2,   2*w2+1)
        //      pix10 = OFM(fi, 2*h2+1, 2*w2  )
        //      pix11 = OFM(fi, 2*h2+1, 2*w2+1)
        //    Golden NCHW: golden_l0[fi*65536 + h*256 + w]  (H=256, W=256)
        mismatch = 0; mismatch_print = 0;
        for (fi = 0; fi < 16; fi = fi + 1) begin
            for (hb = 0; hb < 128; hb = hb + 1) begin
                for (wb = 0; wb < 128; wb = wb + 1) begin
                    dword = dram[OFM_WORD_BASE + L0_OFM_OFF + fi*16384 + hb*128 + wb];
                    for (sub_h = 0; sub_h < 2; sub_h = sub_h + 1) begin
                        for (sub_w = 0; sub_w < 2; sub_w = sub_w + 1) begin
                            pix_idx = sub_h*2 + sub_w;     // 0..3 → byte slot
                            got_b   = dword[pix_idx*8 +: 8];
                            exp_b   = golden_l0[fi*65536 + (hb*2+sub_h)*256 + (wb*2+sub_w)];
                            if (got_b !== exp_b) begin
                                mismatch = mismatch + 1;
                                if (mismatch_print < 16) begin
                                    $display("[L0-TB MISMATCH] fi=%0d h=%0d w=%0d got=%02x exp=%02x",
                                             fi, hb*2+sub_h, wb*2+sub_w, got_b, exp_b);
                                    mismatch_print = mismatch_print + 1;
                                end
                            end
                        end
                    end
                end
            end
        end
        if (mismatch == 0) $display("[L0-TB] *** PASS: L0 OFM all 1,048,576 px match ***");
        else               $display("[L0-TB] *** FAIL: %0d mismatches / 1,048,576 ***", mismatch);

        // 8) 추가 sample 출력 (몇 개 word 의 원본 값)
        $display("[L0-TB] DRAM[OFM,0]=%08x  DRAM[OFM,128]=%08x  DRAM[OFM,16383]=%08x",
                 dram[OFM_WORD_BASE+0], dram[OFM_WORD_BASE+128], dram[OFM_WORD_BASE+16383]);
        $display("[L0-TB] DRAM[OFM,16384(fi=1,0,0)]=%08x", dram[OFM_WORD_BASE+16384]);

        #(20*CLK_PERIOD) $finish;
    end

    // ── Watchdog ──────────────────────────────────────────────────────
    initial begin
        repeat(2_000) #(1_000_000);
        $display("[L0-TB] *** TIMEOUT (200M cycles) ***");
        $finish;
    end

    // ── FSM 추적 ──────────────────────────────────────────────────────
    reg [3:0] prev_ts;
    reg [4:0] prev_li;
    initial begin prev_ts = 4'hF; prev_li = 5'h1F; end
    always @(posedge clk) begin
        if (rstn) begin
            if (u_yolo_engine.top_state !== prev_ts) begin
                $display("[L0-TB][%0t] L%0d top_state %0d→%0d",
                         $time, u_yolo_engine.layer_idx, prev_ts, u_yolo_engine.top_state);
                prev_ts <= u_yolo_engine.top_state;
            end
            if (u_yolo_engine.layer_idx !== prev_li) begin
                $display("[L0-TB][%0t] layer_idx %0d→%0d",
                         $time, prev_li, u_yolo_engine.layer_idx);
                prev_li <= u_yolo_engine.layer_idx;
            end
        end
    end

    // ── IFM line_buf write 추적 (eir=0 마다 = 새 row 시작 시점) ───────
    //    각 row 의 첫 entry 와 마지막 entry 만 출력 → spam 방지
    reg [11:0] dma_eir_prev_r;
    initial dma_eir_prev_r = 12'hFFF;
    always @(posedge clk) begin
        if (rstn && u_yolo_engine.dma_lb_wr_en) begin
            // 첫 entry of row (eir 가 0 으로 wrap 된 직후)
            if (u_yolo_engine.dma_ifm_eir_r == 12'd0) begin
                $display("[L0-TB][%0t] IFM_LB WR row=%0d bank=%0d addr=%0d data[31:0]=%08x (first)",
                         $time, u_yolo_engine.dma_ifm_row_r,
                         u_yolo_engine.dma_lb_wr_line, u_yolo_engine.dma_lb_wr_addr,
                         u_yolo_engine.dma_lb_wr_data[31:0]);
            end
            dma_eir_prev_r <= u_yolo_engine.dma_ifm_eir_r;
        end
    end

    // ── rb 진행 추적 (v1 yolo_engine: rb_r) ─────────────────────────
    reg [11:0] prev_rb_r;
    initial prev_rb_r = 12'hFFF;
    always @(posedge clk) begin
        if (rstn) begin
            if (u_yolo_engine.rb_r !== prev_rb_r) begin
                $display("[L0-TB][%0t] rb=%0d  ofm_fil=%0d  top_state=%0d",
                         $time, u_yolo_engine.rb_r, u_yolo_engine.ofm_fil_r,
                         u_yolo_engine.top_state);
                prev_rb_r <= u_yolo_engine.rb_r;
            end
        end
    end

    // ── Filter 완료 추적 ─────────────────────────────────────────────
    reg prev_fil_done;
    initial prev_fil_done = 1'b0;
    always @(posedge clk) begin
        if (rstn) begin
            prev_fil_done <= u_yolo_engine.conv_fil_done;
            if (u_yolo_engine.conv_fil_done && !prev_fil_done)
                $display("[L0-TB][%0t] conv_fil_done  ofm_fil=%0d  rb=%0d",
                         $time, u_yolo_engine.ofm_fil_r, u_yolo_engine.rb_r);
        end
    end

    // ── OFM DMA write 추적 (각 burst 의 첫 word 만) ──────────────────
    reg prev_dma_wr_start;
    initial prev_dma_wr_start = 1'b0;
    always @(posedge clk) begin
        if (rstn) begin
            prev_dma_wr_start <= u_yolo_engine.dma_wr_start;
            if (u_yolo_engine.dma_wr_start && !prev_dma_wr_start)
                $display("[L0-TB][%0t] OFM DMA start addr=%08x len=%0d",
                         $time, u_yolo_engine.dma_wr_start_addr,
                         u_yolo_engine.dma_wr_num_trans);
        end
    end

`endif  // !FPGA

endmodule
