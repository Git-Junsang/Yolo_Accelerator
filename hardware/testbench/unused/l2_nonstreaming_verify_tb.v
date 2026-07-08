`timescale 1ns / 1ns
//----------------------------------------------------------------------
// l2_nonstreaming_verify_tb.v — L2 (CONV3x3 Ci=16 Co=32) 검증 TB (archive)
// streaming refactor 이전 — weight 전체 적재(S_LOAD_WGT) 시절의 TB.
//
//   [Phase A] Standalone L2
//     - DRAM 의 L2 IFM 영역에 CONV02_input.hex 을 NHWC packed 포맷으로 사전 적재
//     - wgt/bias 도 .mem 파일에서 로드 (L2 의 entry base 16 부터 사용)
//     - layer_idx=2, conv_phase_r=2, state_r=S_LOAD_WGT 로 강제 진입 → release
//     - L2 conv 만 단독 실행 후 layer_idx=3 도달
//     - DRAM L2 OFM ↔ CONV02_output.hex 비교
//
//   [Phase B] Chain L0 → L1 → REPACK → L2
//     - 시뮬레이션 리셋 → wgt/bias/ifm .mem 적재 → ap_start=1
//     - 엔진 자연 흐름: L0 → L1 → REPACK → L2 (layer_idx 0→1→2→3)
//     - DRAM L2 OFM ↔ CONV02_output.hex 비교
//
// DRAM 메모리 맵 (yolo_engine.v 기준):
//   WGT  : 0x0000_0000 (L0=0..1023 byte, L2=1024..9215 byte)
//   BIAS : 0x00A0_0000 (L0=0..63 byte, L2=64..191 byte)
//   IFM  : 0x00B0_0000 (L0 IFM, 65536 word)
//   OFM  : 0x00C0_0000 →
//            L0 OFM      : offset      0..0x0FFFFF (= 262,144 word)
//            L1 OFM      : offset 0x100000..0x13FFFF (=  65,536 word)
//            L2 IFM (rp) : offset 0x140000..0x17FFFF (=  65,536 word)
//            L2 OFM      : offset 0x180000..0x1FFFFF (= 131,072 word)
//----------------------------------------------------------------------
`include "user_define_h.v"

module l2_nonstreaming_verify_tb;

`ifdef FPGA
    initial begin
        $display("[L2V-TB][FATAL] FPGA macro enabled.");
        $finish;
    end
`else

    parameter WGT_MEM     = "../../../../../../testbench/inout_data_sw/gen_wgt_dram.mem";
    parameter BIAS_MEM    = "../../../../../../testbench/inout_data_sw/gen_bias_dram.mem";
    parameter IFM_MEM     = "../../../../../../testbench/inout_data_sw/gen_ifm_dram.mem";
    parameter L1_GOLD_HEX = "../../../../../../testbench/inout_data_sw/log_feamap/CONV02_input.hex";
    parameter L2_GOLD_HEX = "../../../../../../testbench/inout_data_sw/log_feamap/CONV02_output.hex";

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
    localparam integer L2_IFM_OFF_W     = 32'h00140000 >> 2;   // 327,680 word
    localparam integer L2_OFM_OFF_W     = 32'h00180000 >> 2;   // 393,216 word

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
    reg [7:0] golden_l1 [0:262143];    // 16 × 128 × 128 = L1 OFM = L2 IFM (NCHW)
    reg [7:0] golden_l2 [0:524287];    // 32 × 128 × 128 = L2 OFM (NCHW)

    integer mm_l2_A, mm_l2_B;   // phase 별 total mismatch
    integer tf_l2_A, tf_l2_B;   // phase 별 |delta| > TOLERANCE mismatch

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
            $display("[L2V-TB] Loading WGT  : %s", WGT_MEM);
            $readmemh(WGT_MEM,  dram, 0,              WGT_TOTAL_WORDS - 1);
            $display("[L2V-TB] Loading BIAS : %s", BIAS_MEM);
            $readmemh(BIAS_MEM, dram, BIAS_WORD_BASE, BIAS_WORD_BASE + BIAS_TOTAL_WORDS - 1);
            $display("[L2V-TB] Loading IFM  : %s", IFM_MEM);
            $readmemh(IFM_MEM,  dram, IFM_WORD_BASE,  IFM_WORD_BASE  + IFM_TOTAL_WORDS  - 1);
        end
    endtask

    task load_goldens;
        begin
            $display("[L2V-TB] Loading L1 OFM golden (= L2 IFM source): %s", L1_GOLD_HEX);
            $readmemh(L1_GOLD_HEX, golden_l1);
            $display("[L2V-TB] Loading L2 OFM golden                  : %s", L2_GOLD_HEX);
            $readmemh(L2_GOLD_HEX, golden_l2);
        end
    endtask

    // Phase A 용: golden_l1 (NCHW byte) → DRAM L2 IFM 영역 (NHWC packed)
    //   per (row, ci_g, col_b) 16-byte entry:
    //     byte[col_l*4 + ch_l] = golden_l1[(ci_g*4+ch_l)*16384 + row*128 + (col_b*4 + col_l)]
    //   DRAM word addr = OFM_WORD_BASE + L2_IFM_OFF_W + row*512 + ci_g*128 + col_b*4 + col_l
    task preload_l2_ifm;
        integer t_row, t_cig, t_cb, t_cl, t_chl;
        integer t_chfull, t_col, t_addr_w;
        reg [7:0] tb [0:15];
        reg [31:0] tword;
        begin
            $display("[L2V-TB] Pre-loading DRAM L2 IFM region (NHWC packed, 65,536 word)...");
            for (t_row = 0; t_row < 128; t_row = t_row + 1) begin
                for (t_cig = 0; t_cig < 4; t_cig = t_cig + 1) begin
                    for (t_cb = 0; t_cb < 32; t_cb = t_cb + 1) begin
                        // entry 의 16 byte 수집
                        for (t_cl = 0; t_cl < 4; t_cl = t_cl + 1) begin
                            for (t_chl = 0; t_chl < 4; t_chl = t_chl + 1) begin
                                t_chfull = t_cig*4 + t_chl;
                                t_col    = t_cb*4 + t_cl;
                                tb[t_cl*4 + t_chl] = golden_l1[t_chfull*16384 + t_row*128 + t_col];
                            end
                        end
                        // 16 byte → 4 × 32-bit word (little-endian)
                        for (t_cl = 0; t_cl < 4; t_cl = t_cl + 1) begin
                            tword = {tb[t_cl*4 + 3], tb[t_cl*4 + 2],
                                     tb[t_cl*4 + 1], tb[t_cl*4 + 0]};
                            t_addr_w = OFM_WORD_BASE + L2_IFM_OFF_W + t_row*512 + t_cig*128 + t_cb*4 + t_cl;
                            dram[t_addr_w] = tword;
                        end
                    end
                end
            end
        end
    endtask

    // L2 OFM 비교 → mismatch 개수 반환
    //   DRAM word(fi, hb, wb) at L2_OFM_OFF_W + fi*4096 + hb*64 + wb
    //   bytes = {p11, p10, p01, p00}, p_sh_sw = golden_l2[fi*16384 + (2hb+sh)*128 + (2wb+sw)]
    task compare_l2_ofm;
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
            cnt_d1 = 0; cnt_d2 = 0; cnt_d3 = 0; cnt_d4_8 = 0; cnt_d_big = 0;
            cnt_pos = 0; cnt_neg = 0; max_diff = 0;
            for (t_fi = 0; t_fi < 32; t_fi = t_fi + 1) begin
                for (t_hb = 0; t_hb < 64; t_hb = t_hb + 1) begin
                    for (t_wb = 0; t_wb < 64; t_wb = t_wb + 1) begin
                        // L2 OFM DRAM word addr = OFM_WORD_BASE + L2_OFM_OFF_W + fi*4096 + hb*64 + wb
                        tw = dram[OFM_WORD_BASE + L2_OFM_OFF_W + t_fi*4096 + t_hb*64 + t_wb];
                        for (t_sh = 0; t_sh < 2; t_sh = t_sh + 1) begin
                            for (t_sw = 0; t_sw < 2; t_sw = t_sw + 1) begin
                                t_idx = t_sh*2 + t_sw;
                                tg = tw[t_idx*8 +: 8];
                                te = golden_l2[t_fi*16384 + (t_hb*2+t_sh)*128 + (t_wb*2+t_sw)];
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
                                        $display("  [L2V-TB] MISMATCH fi=%0d h=%0d w=%0d got=%02x exp=%02x (d=%0d)",
                                                 t_fi, t_hb*2+t_sh, t_wb*2+t_sw, tg, te, diff_signed);
                                        t_print = t_print + 1;
                                    end
                                end
                            end
                        end
                    end
                end
            end
            $display("[L2V-TB] delta dist : total=%0d  +d=%0d  -d=%0d  max|d|=%0d",
                     mismatch_cnt, cnt_pos, cnt_neg, max_diff);
            $display("[L2V-TB]   |d|=1    : %0d  (%0d%%)",
                     cnt_d1, (cnt_d1*100)/((mismatch_cnt==0)?1:mismatch_cnt));
            $display("[L2V-TB]   |d|=2    : %0d", cnt_d2);
            $display("[L2V-TB]   |d|=3    : %0d", cnt_d3);
            $display("[L2V-TB]   |d|=4..8 : %0d", cnt_d4_8);
            $display("[L2V-TB]   |d|>8    : %0d", cnt_d_big);
            $display("[L2V-TB]   |d|>%0d (tol-exceed) : %0d", TOLERANCE, tol_fail_cnt);
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
        // [Phase A] Standalone L2
        //   wgt/bias .mem 로드 + L2 IFM 영역 NHWC packed 사전 적재
        //   layer_idx=2, conv_phase_r=2, state_r=S_LOAD_WGT 강제 진입 → release
        //   layer_idx=3 도달 시 L2 완료
        //==================================================================
        $display("");
        $display("[L2V-TB] ============== Phase A : Standalone L2 ==============");

        load_dram_inputs;             // wgt/bias/ifm .mem
        preload_l2_ifm;               // L2 IFM = NHWC packed CONV02_input.hex

        force u_yolo_engine.u_axi.slv_reg1 = 32'h0000_0000;
        force u_yolo_engine.u_axi.slv_reg2 = 32'h00B0_0000;
        force u_yolo_engine.u_axi.slv_reg3 = 32'h00C0_0000;

        #(8*CLK_PERIOD) rstn = 1'b1;
        #(4*CLK_PERIOD);

        // L2 시작 위치로 강제 진입
        @(posedge clk);
        force u_yolo_engine.layer_idx    = 5'd2;
        force u_yolo_engine.conv_phase_r = 5'd2;
        force u_yolo_engine.fi_r         = 5'd0;
        force u_yolo_engine.rb_r         = 12'd0;
        force u_yolo_engine.state_r      = 5'd1;       // S_LOAD_WGT
        $display("[L2V-TB][%0t] Phase A : force layer_idx=2 conv_phase=2 state=S_LOAD_WGT", $time);
        @(posedge clk);
        release u_yolo_engine.layer_idx;
        release u_yolo_engine.conv_phase_r;
        release u_yolo_engine.fi_r;
        release u_yolo_engine.rb_r;
        release u_yolo_engine.state_r;

        // L2 완료 대기 (layer_idx → 3)
        wait (u_yolo_engine.layer_idx == 5'd3);
        $display("[L2V-TB][%0t] Phase A : L2 COMPLETED (layer_idx -> 3)", $time);
        #(40*CLK_PERIOD);

        compare_l2_ofm(mm_l2_A, tf_l2_A);
        $display("[L2V-TB][Phase A] OFM mismatch: %0d / 524288   (tol-exceed: %0d)", mm_l2_A, tf_l2_A);
        if      (mm_l2_A == 0) $display("[L2V-TB][Phase A] *** PASS (exact, 0 mismatches) ***");
        else if (tf_l2_A == 0) $display("[L2V-TB][Phase A] *** PASS (within tolerance +-%0d, %0d noise) ***", TOLERANCE, mm_l2_A);
        else                    $display("[L2V-TB][Phase A] *** FAIL (%0d exceed +-%0d tolerance) ***", tf_l2_A, TOLERANCE);

        //==================================================================
        // [Phase B] Chain L0 → L1 → REPACK → L2
        //==================================================================
        $display("");
        $display("[L2V-TB] ============== Phase B : Chain L0 -> L1 -> REPACK -> L2 ==============");

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
        $display("[L2V-TB][%0t] Phase B : ap_start = 1", $time);
        @(posedge clk); @(posedge clk);
        force u_yolo_engine.u_axi.slv_reg0 = 32'd0;

        wait (u_yolo_engine.layer_idx == 5'd3);
        $display("[L2V-TB][%0t] Phase B : L0 -> L1 -> REPACK -> L2 ALL COMPLETED", $time);
        #(40*CLK_PERIOD);

        compare_l2_ofm(mm_l2_B, tf_l2_B);
        $display("[L2V-TB][Phase B] OFM mismatch: %0d / 524288   (tol-exceed: %0d)", mm_l2_B, tf_l2_B);
        if      (mm_l2_B == 0) $display("[L2V-TB][Phase B] *** PASS (exact, 0 mismatches) ***");
        else if (tf_l2_B == 0) $display("[L2V-TB][Phase B] *** PASS (within tolerance +-%0d, %0d noise) ***", TOLERANCE, mm_l2_B);
        else                    $display("[L2V-TB][Phase B] *** FAIL (%0d exceed +-%0d tolerance) ***", tf_l2_B, TOLERANCE);

        //==================================================================
        $display("");
        $display("[L2V-TB] ============================================================");
        $display("[L2V-TB] Phase A : %s (mismatch=%0d, tol-exceed=%0d)",
                 (tf_l2_A == 0) ? "PASS" : "FAIL", mm_l2_A, tf_l2_A);
        $display("[L2V-TB] Phase B : %s (mismatch=%0d, tol-exceed=%0d)",
                 (tf_l2_B == 0) ? "PASS" : "FAIL", mm_l2_B, tf_l2_B);
        $display("[L2V-TB] ============================================================");

        #(20*CLK_PERIOD) $finish;
    end

    // ── Watchdog ──────────────────────────────────────────────────────
    initial begin
        repeat(40_000) #(1_000_000);   // 40s sim time
        $display("[L2V-TB] *** TIMEOUT ***");
        $finish;
    end

    // ── FSM 추적 ──────────────────────────────────────────────────────
    reg [4:0] prev_st;
    reg [4:0] prev_li;
    initial begin prev_st = 5'h1F; prev_li = 5'h1F; end
    always @(posedge clk) begin
        if (rstn) begin
            if (u_yolo_engine.state_r !== prev_st) begin
                $display("[L2V-TB][%0t] L%0d state %0d -> %0d  (cp=%0d fi=%0d rb=%0d)",
                         $time, u_yolo_engine.layer_idx,
                         prev_st, u_yolo_engine.state_r,
                         u_yolo_engine.conv_phase_r,
                         u_yolo_engine.fi_r, u_yolo_engine.rb_r);
                prev_st <= u_yolo_engine.state_r;
            end
            if (u_yolo_engine.layer_idx !== prev_li) begin
                $display("[L2V-TB][%0t] >>> layer_idx %0d -> %0d <<<",
                         $time, prev_li, u_yolo_engine.layer_idx);
                prev_li <= u_yolo_engine.layer_idx;
            end
        end
    end

`endif

endmodule
