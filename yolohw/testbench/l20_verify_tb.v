`timescale 1ns / 1ns
//----------------------------------------------------------------------
// l20_verify_tb.v — L19 (ROUTE concat) + L20 (CONV1x1 Ci=384 Co=195, 16×16) 검증 TB
//   (로그/판정 포맷은 l13_verify_tb canonical 규격에 통일)
//
//   L19 = RTL REPACK: L18 OFM(16×16×128, ch 0..127) ‖ L8 OFM(16×16×256, ch 128..383)
//                     → L20 IFM(16×16×384, NHWC entry)
//   L20 = detection head 2 (Co=195, 1×1, ReLU off → INT8 signed raw output)
//
//   Golden source:
//     L20 IFM  → CONV20_input.hex  (NCHW byte, 384×16×16) ch0..127=L18 OFM, ch128..383=L8 OFM
//     L20 OFM  → CONV20_output.hex (NCHW byte, 195×16×16, INT8 signed)
//     L10 IFM  → CONV10_input.hex  (NCHW byte, 256×8×8) — Phase B chain 시작점
//
//   [Phase A] Standalone L19+L20
//     - L20 IFM golden ch 0..127 → DRAM L18 OFM (conv 2×2 packed) @ 0x328000
//     - L20 IFM golden ch 128..383 → DRAM L8 OFM (conv 2×2 packed) @ 0x2D0000
//     - wgt/bias .mem 적재
//     - force layer_idx=19, state_r=S_L19_RP_LOAD_A(45) → release
//     - L19 REPACK + L20 conv 단독 실행 → layer_idx=21
//     - DRAM L20 OFM ↔ CONV20_output 비교
//
//   [Phase B] Chain L10 → ... → L20
//     - L10 IFM (CONV10_input) → DRAM L10 IFM (NHWC packed) @ 0x2E4000
//     - L8 OFM golden(L20 IFM ch128..383) → DRAM L8 OFM (conv 2×2 packed) @ 0x2D0000
//         (L8 은 L10 chain 에 없으므로 route 소스로 golden 주입; L18 은 chain 이 생성)
//     - force layer_idx=10, conv_phase_r=10, state_r=S_LOAD_BIAS(1) → release
//     - L10→L11→L12→L13→L14→L17→L18→L19→L20 자연 chain → layer_idx=21
//     - DRAM L20 OFM ↔ CONV20_output 비교
//
// DRAM 메모리 맵 (dram_ofm_base = 0x00C00000):
//   L8  OFM           : 0x002D0000 (64KB = 16384 word, 16×16×256 conv 2×2 packed)
//   L10 IFM (REPACK)  : 0x002E4000 (16KB = 4096 word, 8×8×256 NHWC packed)
//   L18 OFM           : 0x00328000 (32KB = 8192 word, 16×16×128 conv 2×2 packed)
//   L20 IFM (REPACK)  : 0x00330000 (96KB = 24576 word, 16×16×384 NHWC entry)
//   L20 OFM           : 0x00348000 (~49KB = 12480 word, 16×16×195 conv 2×2 packed)
//----------------------------------------------------------------------
`include "user_define_h.v"

module l20_verify_tb;

`ifdef FPGA
    initial begin
        $display("[L20V-TB][FATAL] FPGA macro enabled.");
        $finish;
    end
`else

    parameter WGT_MEM      = "../../../../../../testbench/inout_data_sw/gen_wgt_dram.mem";
    parameter BIAS_MEM     = "../../../../../../testbench/inout_data_sw/gen_bias_dram.mem";
    parameter IFM_MEM      = "../../../../../../testbench/inout_data_sw/gen_ifm_dram.mem";
    parameter L20_IFM_HEX  = "../../../../../../testbench/inout_data_sw/log_feamap/CONV20_input.hex";
    parameter L20_OFM_HEX  = "../../../../../../testbench/inout_data_sw/log_feamap/CONV20_output.hex";
    parameter L10_IFM_HEX  = "../../../../../../testbench/inout_data_sw/log_feamap/CONV10_input.hex";

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
    localparam integer L8_OFM_OFF_W     = 32'h002D0000 >> 2;
    localparam integer L10_IFM_OFF_W    = 32'h002E4000 >> 2;
    localparam integer L18_OFM_OFF_W    = 32'h00328000 >> 2;
    localparam integer L20_OFM_OFF_W    = 32'h00348000 >> 2;

    // |got-exp| <= TOLERANCE 인 mismatch 는 양자화 noise 로 간주 (PASS).
    localparam integer TOLERANCE        = 1;

    // FSM state codes (yolo_engine 와 동일)
    localparam [5:0] ST_LOAD_BIAS     = 6'd1;
    localparam [5:0] ST_L19_RP_LOAD_A = 6'd45;

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
    reg [7:0] golden_l20_ifm [0:98303];   // 384 × 16 × 16 (CONV20_input, ch0..127=L18, ch128..383=L8)
    reg [7:0] golden_l20_ofm [0:49919];   // 195 × 16 × 16 (CONV20_output, INT8 signed)
    reg [7:0] golden_l10_ifm [0:16383];   // 256 × 8 × 8   (CONV10_input = L10 IFM)

    integer mm_l20_A, mm_l20_B;   // phase 별 total mismatch
    integer tf_l20_A, tf_l20_B;   // phase 별 |delta| > TOLERANCE mismatch

    task dram_zero;
        integer t_i;
        begin
            for (t_i = 0; t_i < DRAM_WORDS; t_i = t_i + 1) dram[t_i] = 32'd0;
        end
    endtask

    task load_dram_inputs;
        begin
            $display("[L20V-TB] Loading WGT  : %s", WGT_MEM);
            $readmemh(WGT_MEM,  dram, 0,              WGT_TOTAL_WORDS - 1);
            $display("[L20V-TB] Loading BIAS : %s", BIAS_MEM);
            $readmemh(BIAS_MEM, dram, BIAS_WORD_BASE, BIAS_WORD_BASE + BIAS_TOTAL_WORDS - 1);
            $display("[L20V-TB] Loading IFM  : %s (L0 IFM)", IFM_MEM);
            $readmemh(IFM_MEM,  dram, IFM_WORD_BASE,  IFM_WORD_BASE  + IFM_TOTAL_WORDS  - 1);
        end
    endtask

    task load_goldens;
        begin
            $display("[L20V-TB] Loading L20 IFM golden : %s", L20_IFM_HEX);
            $readmemh(L20_IFM_HEX, golden_l20_ifm);
            $display("[L20V-TB] Loading L20 OFM golden : %s", L20_OFM_HEX);
            $readmemh(L20_OFM_HEX, golden_l20_ofm);
            $display("[L20V-TB] Loading L10 IFM golden : %s", L10_IFM_HEX);
            $readmemh(L10_IFM_HEX, golden_l10_ifm);
        end
    endtask

    // 16×16 conv 2×2-packed OFM 영역에 golden 채널 적재 (L8/L18 공통)
    //   n_chan      : 채널 수 (L18=128, L8=256)
    //   dram_off_w  : DRAM OFM word offset (dram_ofm_base 기준)
    //   gold_ch_base: golden_l20_ifm 의 채널 시작 (L18=0, L8=128)
    //   word @ OFM_WORD_BASE + dram_off_w + f*64 + hb*8 + wb
    //     byte = pix(2hb,2wb), pix(2hb,2wb+1), pix(2hb+1,2wb), pix(2hb+1,2wb+1)
    //     golden byte = golden_l20_ifm[(gold_ch_base+f)*256 + h*16 + w]
    task software_pack_ofm_16x16;
        input integer n_chan;
        input integer dram_off_w;
        input integer gold_ch_base;
        integer t_f, t_hb, t_wb, t_gc;
        reg [7:0] p00, p01, p10, p11;
        begin
            for (t_f = 0; t_f < n_chan; t_f = t_f + 1) begin
                t_gc = gold_ch_base + t_f;
                for (t_hb = 0; t_hb < 8; t_hb = t_hb + 1) begin
                    for (t_wb = 0; t_wb < 8; t_wb = t_wb + 1) begin
                        p00 = golden_l20_ifm[t_gc*256 + (2*t_hb  )*16 + (2*t_wb  )];
                        p01 = golden_l20_ifm[t_gc*256 + (2*t_hb  )*16 + (2*t_wb+1)];
                        p10 = golden_l20_ifm[t_gc*256 + (2*t_hb+1)*16 + (2*t_wb  )];
                        p11 = golden_l20_ifm[t_gc*256 + (2*t_hb+1)*16 + (2*t_wb+1)];
                        dram[OFM_WORD_BASE + dram_off_w + t_f*64 + t_hb*8 + t_wb]
                            = {p11, p10, p01, p00};
                    end
                end
            end
        end
    endtask

    // L10 IFM (CONV10_input NCHW byte) → DRAM L10 IFM (NHWC packed, 8×8×256)
    task preload_l10_ifm;
        integer t_row, t_cig, t_cb, t_cl, t_chl, t_chfull, t_col, t_addr_w;
        reg [7:0] tb [0:15];
        begin
            for (t_row = 0; t_row < 8; t_row = t_row + 1) begin
                for (t_cig = 0; t_cig < 64; t_cig = t_cig + 1) begin
                    for (t_cb = 0; t_cb < 2; t_cb = t_cb + 1) begin
                        for (t_cl = 0; t_cl < 4; t_cl = t_cl + 1)
                            for (t_chl = 0; t_chl < 4; t_chl = t_chl + 1) begin
                                t_chfull = t_cig*4 + t_chl;
                                t_col    = t_cb*4 + t_cl;
                                tb[t_cl*4 + t_chl] = golden_l10_ifm[t_chfull*64 + t_row*8 + t_col];
                            end
                        for (t_cl = 0; t_cl < 4; t_cl = t_cl + 1) begin
                            t_addr_w = OFM_WORD_BASE + L10_IFM_OFF_W + t_row*512 + t_cig*8 + t_cb*4 + t_cl;
                            dram[t_addr_w] = {tb[t_cl*4 + 3], tb[t_cl*4 + 2],
                                              tb[t_cl*4 + 1], tb[t_cl*4 + 0]};
                        end
                    end
                end
            end
        end
    endtask

    // L20 OFM 비교 + delta magnitude 분포 (l13 canonical 규격)
    //   L20 OFM 형식 = conv 2×2 packed, 16×16×195, detection (INT8 signed raw)
    //   word @ OFM_WORD_BASE + L20_OFM_OFF_W + fi*64 + hb*8 + wb
    //   golden byte = golden_l20_ofm[fi*256 + (2hb+sh)*16 + (2wb+sw)]
    task compare_l20_ofm;
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
            cnt_d1 = 0; cnt_d2 = 0; cnt_d3 = 0;
            cnt_d4_8 = 0; cnt_d_big = 0;
            cnt_pos = 0; cnt_neg = 0;
            max_diff = 0;
            for (t_fi = 0; t_fi < 195; t_fi = t_fi + 1) begin
                for (t_hb = 0; t_hb < 8; t_hb = t_hb + 1) begin
                    for (t_wb = 0; t_wb < 8; t_wb = t_wb + 1) begin
                        tw = dram[OFM_WORD_BASE + L20_OFM_OFF_W + t_fi*64 + t_hb*8 + t_wb];
                        for (t_sh = 0; t_sh < 2; t_sh = t_sh + 1) begin
                            for (t_sw = 0; t_sw < 2; t_sw = t_sw + 1) begin
                                t_idx = t_sh*2 + t_sw;
                                tg = tw[t_idx*8 +: 8];
                                te = golden_l20_ofm[t_fi*256 + (2*t_hb+t_sh)*16 + (2*t_wb+t_sw)];
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
                                        $display("  [L20V-TB] MISMATCH fi=%0d h=%0d w=%0d got=%02x exp=%02x (d=%0d)",
                                                 t_fi, t_hb*2+t_sh, t_wb*2+t_sw, tg, te, diff_signed);
                                        t_print = t_print + 1;
                                    end
                                end
                            end
                        end
                    end
                end
            end
            $display("[L20V-TB] delta dist : total=%0d  +d=%0d  -d=%0d  max|d|=%0d",
                     mismatch_cnt, cnt_pos, cnt_neg, max_diff);
            $display("[L20V-TB]   |d|=1    : %0d  (%0d%%)",
                     cnt_d1, (cnt_d1*100)/((mismatch_cnt==0)?1:mismatch_cnt));
            $display("[L20V-TB]   |d|=2    : %0d", cnt_d2);
            $display("[L20V-TB]   |d|=3    : %0d", cnt_d3);
            $display("[L20V-TB]   |d|=4..8 : %0d", cnt_d4_8);
            $display("[L20V-TB]   |d|>8    : %0d", cnt_d_big);
            $display("[L20V-TB]   |d|>%0d (tol-exceed) : %0d", TOLERANCE, tol_fail_cnt);
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
        // [Phase A] Standalone L19 (ROUTE REPACK) + L20 (CONV1x1)
        //==================================================================
        $display("");
        $display("[L20V-TB] ============== Phase A : Standalone L20 ==============");

        load_dram_inputs;
        software_pack_ofm_16x16(128, L18_OFM_OFF_W, 0);    // L18 OFM = L20 IFM ch 0..127
        software_pack_ofm_16x16(256, L8_OFM_OFF_W,  128);  // L8  OFM = L20 IFM ch 128..383

        force u_yolo_engine.u_axi.slv_reg1 = 32'h0000_0000;
        force u_yolo_engine.u_axi.slv_reg2 = 32'h00B0_0000;
        force u_yolo_engine.u_axi.slv_reg3 = 32'h00C0_0000;

        #(8*CLK_PERIOD) rstn = 1'b1;
        #(4*CLK_PERIOD);

        @(posedge clk);
        force u_yolo_engine.layer_idx = 5'd19;
        force u_yolo_engine.fi_r      = 12'd0;
        force u_yolo_engine.rb_r      = 12'd0;
        force u_yolo_engine.state_r   = ST_L19_RP_LOAD_A;   // 6'd45 (L19 REPACK 부터)
        $display("[L20V-TB][%0t] Phase A : force layer_idx=19 state=S_L19_RP_LOAD_A", $time);
        @(posedge clk);
        release u_yolo_engine.layer_idx;
        release u_yolo_engine.fi_r;
        release u_yolo_engine.rb_r;
        release u_yolo_engine.state_r;

        wait (u_yolo_engine.layer_idx == 5'd21);
        $display("[L20V-TB][%0t] Phase A : L19+L20 COMPLETED (layer_idx -> 21)", $time);
        #(40*CLK_PERIOD);

        compare_l20_ofm(mm_l20_A, tf_l20_A);
        $display("[L20V-TB][Phase A] OFM mismatch: %0d / 49920   (tol-exceed: %0d)", mm_l20_A, tf_l20_A);
        if      (mm_l20_A == 0) $display("[L20V-TB][Phase A] *** PASS (exact, 0 mismatches) ***");
        else if (tf_l20_A == 0) $display("[L20V-TB][Phase A] *** PASS (within tolerance +-%0d, %0d noise) ***", TOLERANCE, mm_l20_A);
        else                    $display("[L20V-TB][Phase A] *** FAIL (%0d exceed +-%0d tolerance) ***", tf_l20_A, TOLERANCE);

        //==================================================================
        // [Phase B] Chain L10 → ... → L20
        //==================================================================
        $display("");
        $display("[L20V-TB] ============== Phase B : Chain L10 -> ... -> L20 ==============");

        rstn = 1'b0;
        #(8*CLK_PERIOD);
        dram_zero;
        load_dram_inputs;
        preload_l10_ifm;                                   // L10 IFM (chain 시작점)
        software_pack_ofm_16x16(256, L8_OFM_OFF_W, 128);   // L8 OFM golden (route 소스, chain 미생성)

        force u_yolo_engine.u_axi.slv_reg1 = 32'h0000_0000;
        force u_yolo_engine.u_axi.slv_reg2 = 32'h00B0_0000;
        force u_yolo_engine.u_axi.slv_reg3 = 32'h00C0_0000;

        #(4*CLK_PERIOD) rstn = 1'b1;
        #(4*CLK_PERIOD);

        @(posedge clk);
        force u_yolo_engine.layer_idx    = 5'd10;
        force u_yolo_engine.conv_phase_r = 5'd10;
        force u_yolo_engine.fi_r         = 12'd0;
        force u_yolo_engine.rb_r         = 12'd0;
        force u_yolo_engine.state_r      = ST_LOAD_BIAS;    // 6'd1
        $display("[L20V-TB][%0t] Phase B : force layer_idx=10 conv_phase=10 state=S_LOAD_BIAS", $time);
        @(posedge clk);
        release u_yolo_engine.layer_idx;
        release u_yolo_engine.conv_phase_r;
        release u_yolo_engine.fi_r;
        release u_yolo_engine.rb_r;
        release u_yolo_engine.state_r;

        wait (u_yolo_engine.layer_idx == 5'd21);
        $display("[L20V-TB][%0t] Phase B : L10 -> ... -> L20 ALL COMPLETED", $time);
        #(40*CLK_PERIOD);

        compare_l20_ofm(mm_l20_B, tf_l20_B);
        $display("[L20V-TB][Phase B] OFM mismatch: %0d / 49920   (tol-exceed: %0d)", mm_l20_B, tf_l20_B);
        if      (mm_l20_B == 0) $display("[L20V-TB][Phase B] *** PASS (exact, 0 mismatches) ***");
        else if (tf_l20_B == 0) $display("[L20V-TB][Phase B] *** PASS (within tolerance +-%0d, %0d noise) ***", TOLERANCE, mm_l20_B);
        else                    $display("[L20V-TB][Phase B] *** FAIL (%0d exceed +-%0d tolerance) ***", tf_l20_B, TOLERANCE);

        $display("");
        $display("[L20V-TB] ============================================================");
        $display("[L20V-TB] Phase A : %s (mismatch=%0d, tol-exceed=%0d)",
                 (tf_l20_A == 0) ? "PASS" : "FAIL", mm_l20_A, tf_l20_A);
        $display("[L20V-TB] Phase B : %s (mismatch=%0d, tol-exceed=%0d)",
                 (tf_l20_B == 0) ? "PASS" : "FAIL", mm_l20_B, tf_l20_B);
        $display("[L20V-TB] ============================================================");

        #(20*CLK_PERIOD) $finish;
    end

    initial begin
        repeat(600_000) #(1_000_000);
        $display("[L20V-TB] *** TIMEOUT ***");
        $finish;
    end

    reg [4:0] prev_li;
    initial prev_li = 5'h1F;
    always @(posedge clk) begin
        if (rstn && u_yolo_engine.layer_idx !== prev_li) begin
            $display("[L20V-TB][%0t] >>> layer_idx %0d -> %0d <<<",
                     $time, prev_li, u_yolo_engine.layer_idx);
            prev_li <= u_yolo_engine.layer_idx;
        end
    end

`endif

endmodule
