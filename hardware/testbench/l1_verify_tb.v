`timescale 1ns / 1ns
//----------------------------------------------------------------------
// l1_verify_tb.v — L1 (POOL_S2) 2-단계 통합 검증 TB (streaming engine)
//
// L1 자체는 weight 없으므로 streaming 영향 없음. L0 (chain Phase B) 가
// streaming 으로 동작하는 것만 추가됨. L1 의 FSM state numbering (13..19) 은
// streaming refactor 후에도 그대로 유지됨.
//
// 한 번의 시뮬레이션 안에서 다음 2 단계가 순차적으로 진행됩니다.
//
//   [Phase A] Standalone L1
//     - L0 OFM (CONV00_output.hex) 를 DRAM 의 L0 OFM 영역에 사전 적재
//     - layer_idx, state_r 을 강제로 L1 시작 위치로 force
//     - L1 만 단독 실행
//     - DRAM L1 OFM 결과 ↔ CONV02_input.hex 비교
//
//   [Phase B] Chain L0 → L1
//     - 시뮬레이션 리셋 후 wgt/bias/ifm .mem 만 적재 (L0 OFM 영역은 0 초기화)
//     - ap_start=1 → 엔진이 자연스럽게 L0 → L1 순차 실행
//     - DRAM L0 OFM ↔ CONV00_output.hex 비교 (참고용)
//     - DRAM L1 OFM ↔ CONV02_input.hex 비교
//
// DRAM 메모리 맵:
//   WGT  : 0x0000_0000 (2_577_152 word)
//   BIAS : 0x00A0_0000 (   2_294 word)
//   IFM  : 0x00B0_0000 (  65_536 word)
//   OFM  : 0x00C0_0000 →
//            L0 OFM : offset      0..262143 word   (16 ch × 128 × 128 packed)
//            L1 OFM : offset 262144..327679 word   (16 ch × 128 × 32 packed)
//----------------------------------------------------------------------
`include "user_define_h.v"

module l1_verify_tb;

`ifdef FPGA
    initial begin
        $display("[L1V-TB][FATAL] FPGA macro enabled.");
        $finish;
    end
`else

    parameter WGT_MEM     = "../../../../../../testbench/inout_data_sw/gen_wgt_dram.mem";
    parameter BIAS_MEM    = "../../../../../../testbench/inout_data_sw/gen_bias_dram.mem";
    parameter IFM_MEM     = "../../../../../../testbench/inout_data_sw/gen_ifm_dram.mem";
    parameter L0_GOLD_HEX = "../../../../../../testbench/inout_data_sw/log_feamap/CONV00_output.hex";
    parameter L1_GOLD_HEX = "../../../../../../testbench/inout_data_sw/log_feamap/CONV02_input.hex";

    parameter CLK_PERIOD = 10;
    reg clk, rstn;
    initial begin clk = 1'b0; forever #(CLK_PERIOD/2) clk = ~clk; end

    // ── DRAM 워드 베이스 ───────────────────────────────────────────────
    localparam integer DRAM_WORDS       = 4 * 1024 * 1024;
    localparam integer WGT_TOTAL_WORDS  = 2_577_152;
    localparam integer BIAS_WORD_BASE   = 32'h00A00000 >> 2;
    localparam integer BIAS_TOTAL_WORDS = 2_294;
    localparam integer IFM_WORD_BASE    = 32'h00B00000 >> 2;
    localparam integer IFM_TOTAL_WORDS  = 65_536;
    localparam integer OFM_WORD_BASE    = 32'h00C00000 >> 2;
    localparam integer L0_OFM_OFF       = 0;
    localparam integer L1_OFM_OFF       = 262_144;

    // |got-exp| <= TOLERANCE 인 mismatch 는 양자화 noise 로 간주 (PASS).
    localparam integer TOLERANCE        = 1;

    // ── AXI4-Lite tied ────────────────────────────────────────────────
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
    reg [7:0] golden_l0 [0:1048575];   // 16 × 256 × 256 (L0 OFM, NCHW)
    reg [7:0] golden_l1 [0:262143];    // 16 × 128 × 128 (L1 OFM, NCHW)

    // ── 공통 시퀀스 변수 ──────────────────────────────────────────────
    integer di, fi, hb, wb;
    integer r_pool, cb_pool, c4;
    integer mm_l0, mm_l1_A, mm_l1_B;   // phase 별 total mismatch
    integer tf_l1_A, tf_l1_B;          // phase 별 |delta| > TOLERANCE mismatch
    integer mm_print;
    integer addr_dp;
    reg [31:0] dword;
    reg [7:0]  got_b, exp_b;
    reg [7:0]  p0, p1, p2, p3;

    //----------------------------------------------------------------
    // Tasks
    //----------------------------------------------------------------

    // DRAM 전체 0 초기화
    task dram_zero;
        integer t_i;
        begin
            for (t_i = 0; t_i < DRAM_WORDS; t_i = t_i + 1) dram[t_i] = 32'd0;
        end
    endtask

    // wgt/bias/ifm .mem 로드 (Phase B 용)
    task load_dram_inputs;
        begin
            $display("[L1V-TB] Loading WGT  : %s", WGT_MEM);
            $readmemh(WGT_MEM,  dram, 0,              WGT_TOTAL_WORDS - 1);
            $display("[L1V-TB] Loading BIAS : %s", BIAS_MEM);
            $readmemh(BIAS_MEM, dram, BIAS_WORD_BASE, BIAS_WORD_BASE + BIAS_TOTAL_WORDS - 1);
            $display("[L1V-TB] Loading IFM  : %s", IFM_MEM);
            $readmemh(IFM_MEM,  dram, IFM_WORD_BASE,  IFM_WORD_BASE  + IFM_TOTAL_WORDS  - 1);
        end
    endtask

    // 골든 hex 로드
    task load_goldens;
        begin
            $display("[L1V-TB] Loading L0 OFM golden : %s", L0_GOLD_HEX);
            $readmemh(L0_GOLD_HEX, golden_l0);
            $display("[L1V-TB] Loading L1 OFM golden : %s", L1_GOLD_HEX);
            $readmemh(L1_GOLD_HEX, golden_l1);
        end
    endtask

    // golden_l0 (NCHW byte) → DRAM L0 OFM 영역에 2×2 conv-block packed 적재
    //   word(fi, h_block, w_block) at OFM_BASE + fi*16384 + h_block*128 + w_block
    //   bytes = {p11, p10, p01, p00}, p_sh_sw = golden_l0[fi*65536 + (2hb+sh)*256 + (2wb+sw)]
    task preload_l0_ofm;
        integer t_fi, t_hb, t_wb, t_addr;
        reg [7:0] tp0, tp1, tp2, tp3;
        begin
            $display("[L1V-TB] Pre-loading DRAM L0 OFM region (16 x 16384 word)...");
            for (t_fi = 0; t_fi < 16; t_fi = t_fi + 1) begin
                for (t_hb = 0; t_hb < 128; t_hb = t_hb + 1) begin
                    for (t_wb = 0; t_wb < 128; t_wb = t_wb + 1) begin
                        tp0 = golden_l0[t_fi*65536 + (t_hb*2  )*256 + (t_wb*2  )];
                        tp1 = golden_l0[t_fi*65536 + (t_hb*2  )*256 + (t_wb*2+1)];
                        tp2 = golden_l0[t_fi*65536 + (t_hb*2+1)*256 + (t_wb*2  )];
                        tp3 = golden_l0[t_fi*65536 + (t_hb*2+1)*256 + (t_wb*2+1)];
                        t_addr = OFM_WORD_BASE + L0_OFM_OFF + t_fi*16384 + t_hb*128 + t_wb;
                        dram[t_addr] = {tp3, tp2, tp1, tp0};
                    end
                end
            end
        end
    endtask

    // L1 OFM 비교 → mismatch 개수 반환
    //   DRAM word(fi, r, cb) at L1_OFM_OFF + fi*4096 + r*32 + cb
    //   byte_k = pool(fi, r, cb*4 + k) = golden_l1[fi*16384 + r*128 + cb*4 + k]
    task compare_l1_ofm;
        output integer mismatch_cnt;   // total byte mismatch (got !== exp)
        output integer tol_fail_cnt;   // |delta| > TOLERANCE mismatch
        integer t_fi, t_r, t_cb, t_c4;
        integer t_print;
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
            for (t_fi = 0; t_fi < 16; t_fi = t_fi + 1) begin
                for (t_r = 0; t_r < 128; t_r = t_r + 1) begin
                    for (t_cb = 0; t_cb < 32; t_cb = t_cb + 1) begin
                        tw = dram[OFM_WORD_BASE + L1_OFM_OFF + t_fi*4096 + t_r*32 + t_cb];
                        for (t_c4 = 0; t_c4 < 4; t_c4 = t_c4 + 1) begin
                            tg = tw[t_c4*8 +: 8];
                            te = golden_l1[t_fi*16384 + t_r*128 + t_cb*4 + t_c4];
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
                                    $display("  [L1V-TB] MISMATCH fi=%0d r=%0d c=%0d got=%02x exp=%02x (d=%0d)",
                                             t_fi, t_r, t_cb*4+t_c4, tg, te, diff_signed);
                                    t_print = t_print + 1;
                                end
                            end
                        end
                    end
                end
            end
            $display("[L1V-TB] delta dist : total=%0d  +d=%0d  -d=%0d  max|d|=%0d",
                     mismatch_cnt, cnt_pos, cnt_neg, max_diff);
            $display("[L1V-TB]   |d|=1    : %0d  (%0d%%)",
                     cnt_d1, (cnt_d1*100)/((mismatch_cnt==0)?1:mismatch_cnt));
            $display("[L1V-TB]   |d|=2    : %0d", cnt_d2);
            $display("[L1V-TB]   |d|=3    : %0d", cnt_d3);
            $display("[L1V-TB]   |d|=4..8 : %0d", cnt_d4_8);
            $display("[L1V-TB]   |d|>8    : %0d", cnt_d_big);
            $display("[L1V-TB]   |d|>%0d (tol-exceed) : %0d", TOLERANCE, tol_fail_cnt);
        end
    endtask

    // L0 OFM 비교 → mismatch 개수 반환 (Phase B 의 chain 확인 용)
    //   DRAM word(fi, hb, wb) at L0_OFM_OFF + fi*16384 + hb*128 + wb
    //   bytes = {p11, p10, p01, p00}, p_sh_sw = golden_l0[fi*65536 + (2hb+sh)*256 + (2wb+sw)]
    task compare_l0_ofm;
        output integer mismatch_cnt;
        integer t_fi, t_hb, t_wb, t_sh, t_sw, t_idx;
        integer t_print;
        reg [31:0] tw;
        reg [7:0]  tg, te;
        begin
            mismatch_cnt = 0;
            t_print      = 0;
            for (t_fi = 0; t_fi < 16; t_fi = t_fi + 1) begin
                for (t_hb = 0; t_hb < 128; t_hb = t_hb + 1) begin
                    for (t_wb = 0; t_wb < 128; t_wb = t_wb + 1) begin
                        tw = dram[OFM_WORD_BASE + L0_OFM_OFF + t_fi*16384 + t_hb*128 + t_wb];
                        for (t_sh = 0; t_sh < 2; t_sh = t_sh + 1) begin
                            for (t_sw = 0; t_sw < 2; t_sw = t_sw + 1) begin
                                t_idx = t_sh*2 + t_sw;
                                tg = tw[t_idx*8 +: 8];
                                te = golden_l0[t_fi*65536 + (t_hb*2+t_sh)*256 + (t_wb*2+t_sw)];
                                if (tg !== te) begin
                                    mismatch_cnt = mismatch_cnt + 1;
                                    if (t_print < 4) begin
                                        $display("  [L1V-TB] L0 MISMATCH fi=%0d h=%0d w=%0d got=%02x exp=%02x",
                                                 t_fi, t_hb*2+t_sh, t_wb*2+t_sw, tg, te);
                                        t_print = t_print + 1;
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    endtask

    // DRAM L1 OFM 영역 0 초기화 (Phase A → B 사이)
    task clear_l1_ofm_region;
        integer t_i;
        begin
            for (t_i = 0; t_i < 65_536; t_i = t_i + 1)
                dram[OFM_WORD_BASE + L1_OFM_OFF + t_i] = 32'd0;
        end
    endtask

    //----------------------------------------------------------------
    // Main 시퀀스
    //----------------------------------------------------------------
    initial begin
        rstn = 1'b0;
        dram_zero;
        load_goldens;

        //==================================================================
        // [Phase A] Standalone L1
        //   L0 OFM 영역에 골든 hex 사전 적재, layer_idx=1, state_r=S_L1_FI_LOAD
        //   force → release. L1 만 단독으로 16 filter 처리 후 layer_idx=2 도달.
        //==================================================================
        $display("");
        $display("[L1V-TB] ============== Phase A : Standalone L1 ==============");

        preload_l0_ofm;

        // ctrl_reg 설정 (wgt_base 0x0, ifm_base 0x00B0_0000, ofm_base 0x00C0_0000)
        //   wgt/ifm 영역은 L1 단독 실행 시 접근하지 않음. ofm_base 만 중요.
        force u_yolo_engine.u_axi.slv_reg1 = 32'h0000_0000;
        force u_yolo_engine.u_axi.slv_reg2 = 32'h00B0_0000;
        force u_yolo_engine.u_axi.slv_reg3 = 32'h00C0_0000;

        #(8*CLK_PERIOD) rstn = 1'b1;
        #(4*CLK_PERIOD);

        // L1 시작 위치로 강제 진입
        @(posedge clk);
        force u_yolo_engine.layer_idx = 5'd1;
        force u_yolo_engine.fi_r      = 12'd0;
        force u_yolo_engine.state_r   = 5'd13;   // S_L1_FI_LOAD
        $display("[L1V-TB][%0t] Phase A : force layer_idx=1, state_r=S_L1_FI_LOAD", $time);
        @(posedge clk);
        release u_yolo_engine.layer_idx;
        release u_yolo_engine.fi_r;
        release u_yolo_engine.state_r;

        // L1 완료 대기 (layer_idx → 2)
        wait (u_yolo_engine.layer_idx == 5'd2);
        $display("[L1V-TB][%0t] Phase A : L1 COMPLETED (layer_idx -> 2)", $time);
        #(40*CLK_PERIOD);

        compare_l1_ofm(mm_l1_A, tf_l1_A);
        $display("[L1V-TB][Phase A] OFM mismatch: %0d / 262144   (tol-exceed: %0d)", mm_l1_A, tf_l1_A);
        if      (mm_l1_A == 0) $display("[L1V-TB][Phase A] *** PASS (exact, 0 mismatches) ***");
        else if (tf_l1_A == 0) $display("[L1V-TB][Phase A] *** PASS (within tolerance +-%0d, %0d noise) ***", TOLERANCE, mm_l1_A);
        else                   $display("[L1V-TB][Phase A] *** FAIL (%0d exceed +-%0d tolerance) ***", tf_l1_A, TOLERANCE);

        //==================================================================
        // [Phase B] Chain L0 → L1
        //   DUT 리셋 → wgt/bias/ifm .mem 로드 → ap_start=1
        //   L0 → L1 자연 진행. layer_idx → 2 도달.
        //==================================================================
        $display("");
        $display("[L1V-TB] ============== Phase B : Chain L0 -> L1 ==============");

        // DUT 리셋 + DRAM 재초기화
        rstn = 1'b0;
        // 기존 force 는 이미 release 됨. ap_start 도 release 한 적 없으니 슬레이브
        // 레지스터는 자체 동작.
        #(8*CLK_PERIOD);
        dram_zero;
        load_dram_inputs;

        // ctrl_reg 재설정 (포스 유지)
        force u_yolo_engine.u_axi.slv_reg1 = 32'h0000_0000;
        force u_yolo_engine.u_axi.slv_reg2 = 32'h00B0_0000;
        force u_yolo_engine.u_axi.slv_reg3 = 32'h00C0_0000;

        #(4*CLK_PERIOD) rstn = 1'b1;
        #(4*CLK_PERIOD);

        // ap_start = 1 → L0 자연 시작
        @(posedge clk);
        force u_yolo_engine.u_axi.slv_reg0 = 32'd1;
        $display("[L1V-TB][%0t] Phase B : ap_start = 1", $time);
        @(posedge clk); @(posedge clk);
        force u_yolo_engine.u_axi.slv_reg0 = 32'd0;

        // L1 완료까지 대기 (layer_idx → 2)
        wait (u_yolo_engine.layer_idx == 5'd2);
        $display("[L1V-TB][%0t] Phase B : L0 -> L1 ALL COMPLETED", $time);
        #(40*CLK_PERIOD);

        // L0 확인 (chain 의 연결 무결성 sanity check)
        compare_l0_ofm(mm_l0);
        $display("[L1V-TB][Phase B] L0 sanity mismatch: %0d / 1048576", mm_l0);

        // L1 확인 (실제 검증 포인트)
        compare_l1_ofm(mm_l1_B, tf_l1_B);
        $display("[L1V-TB][Phase B] OFM mismatch: %0d / 262144   (tol-exceed: %0d)", mm_l1_B, tf_l1_B);
        if      (mm_l1_B == 0) $display("[L1V-TB][Phase B] *** PASS (exact, 0 mismatches) ***");
        else if (tf_l1_B == 0) $display("[L1V-TB][Phase B] *** PASS (within tolerance +-%0d, %0d noise) ***", TOLERANCE, mm_l1_B);
        else                   $display("[L1V-TB][Phase B] *** FAIL (%0d exceed +-%0d tolerance) ***", tf_l1_B, TOLERANCE);

        //==================================================================
        // 최종 요약
        //==================================================================
        $display("");
        $display("[L1V-TB] ============================================================");
        $display("[L1V-TB] Phase A : %s (mismatch=%0d, tol-exceed=%0d)",
                 (tf_l1_A == 0) ? "PASS" : "FAIL", mm_l1_A, tf_l1_A);
        $display("[L1V-TB] Phase B : %s (mismatch=%0d, tol-exceed=%0d)",
                 (tf_l1_B == 0) ? "PASS" : "FAIL", mm_l1_B, tf_l1_B);
        $display("[L1V-TB] ============================================================");

        #(20*CLK_PERIOD) $finish;
    end

    // ── Watchdog ──────────────────────────────────────────────────────
    initial begin
        repeat(20_000) #(1_000_000);   // 20s sim time
        $display("[L1V-TB] *** TIMEOUT ***");
        $finish;
    end

    // ── FSM 추적 ──────────────────────────────────────────────────────
    reg [4:0] prev_st;
    reg [4:0] prev_li;
    initial begin prev_st = 5'h1F; prev_li = 5'h1F; end
    always @(posedge clk) begin
        if (rstn) begin
            if (u_yolo_engine.state_r !== prev_st) begin
                $display("[L1V-TB][%0t] L%0d state %0d -> %0d  (fi=%0d rb=%0d)",
                         $time, u_yolo_engine.layer_idx,
                         prev_st, u_yolo_engine.state_r,
                         u_yolo_engine.fi_r, u_yolo_engine.rb_r);
                prev_st <= u_yolo_engine.state_r;
            end
            if (u_yolo_engine.layer_idx !== prev_li) begin
                $display("[L1V-TB][%0t] >>> layer_idx %0d -> %0d <<<",
                         $time, prev_li, u_yolo_engine.layer_idx);
                prev_li <= u_yolo_engine.layer_idx;
            end
        end
    end

    // ── pool 활동 모니터 (시작/완료) ─────────────────────────────────
    reg prev_pool_start;
    initial prev_pool_start = 1'b0;
    always @(posedge clk) begin
        if (rstn) begin
            prev_pool_start <= u_yolo_engine.pool_start_r;
            if (u_yolo_engine.pool_start_r && !prev_pool_start)
                $display("[L1V-TB][%0t] pool_start (fi=%0d)",
                         $time, u_yolo_engine.fi_r);
            if (u_yolo_engine.pool_done)
                $display("[L1V-TB][%0t] pool_done  (fi=%0d)",
                         $time, u_yolo_engine.fi_r);
        end
    end

`endif

endmodule
