`timescale 1ns / 1ns
//----------------------------------------------------------------+
// l0_verify_tb.v — L0 verification (streaming weight 모드)
//
// streaming 엔진에 맞춘 L0 검증. ap_start 만으로 자연 진행.
// L0 의 weight 는 매 filter 시작 직전에 per-fi DMA (16 word) 적재됨.
//
// 검증 흐름:
//   1. ap_start → layer_idx 0 → 1 까지 진행
//   2. L0 완료 시점에 DRAM[OFM] ↔ CONV00_output.hex 비교
//   3. mismatch 카운트 + 첫 8개 print
//
// 검증 흐름:
//   1. .mem 적재 (wgt/bias/ifm) + golden hex
//   2. ctrl_reg1..3 (DRAM base) force, ctrl_reg0[0] (ap_start) pulse
//   3. AXI master 인터페이스로 yolo_engine 동작 (DRAM read/write FSM)
//   4. u_dut.layer_idx == 5'd1 도달 시 L0 완료
//   5. DRAM[OFM 영역] 전수 비교 + 분포 통계
//----------------------------------------------------------------+
`include "user_define_h.v"

module l0_verify_tb;

`ifdef FPGA
    initial begin
        $display("[L0V-TB][FATAL] FPGA macro enabled.");
        $finish;
    end
`else

    parameter PERIOD = 10;
    reg clk, rstn;
    initial begin clk = 1'b0; forever #(PERIOD/2) clk = ~clk; end

    //--------------------------------------------------------------
    // DRAM 메모리 맵 상수
    //   yolo_engine 의 ctrl_reg1=wgt_base=0x00000000
    //                   ctrl_reg2=ifm_base=0x00B00000
    //                   ctrl_reg3=ofm_base=0x00C00000
    //   bias 는 wgt_base + 0x00A00000
    //--------------------------------------------------------------
    localparam DRAM_WORDS    = 4*1024*1024;        // 16 MB
    localparam WGT_WORDS     = 2_577_152;
    localparam BIAS_OFF_W    = 22'h280000;         // = 0x00A00000 >> 2
    localparam BIAS_WORDS    = 2294;
    localparam IFM_OFF_W     = 22'h2C0000;         // = 0x00B00000 >> 2
    localparam IFM_WORDS     = 65536;
    localparam OFM_OFF_W     = 22'h300000;         // = 0x00C00000 >> 2
    localparam L0_OFM_WORDS  = 262144;             // 16 × 128 × 128

    //--------------------------------------------------------------
    // AXI4-Lite slave (TB 는 ctrl_reg 를 force 로 직접 설정 → tie 처리)
    //--------------------------------------------------------------
    wire [3:0]  s_awaddr  = 4'd0;
    wire [2:0]  s_awprot  = 3'd0;
    wire        s_awvalid = 1'b0;
    wire        s_awready;
    wire [31:0] s_wdata   = 32'd0;
    wire [3:0]  s_wstrb   = 4'd0;
    wire        s_wvalid  = 1'b0;
    wire        s_wready;
    wire [1:0]  s_bresp;  wire s_bvalid;
    wire        s_bready  = 1'b1;
    wire [3:0]  s_araddr  = 4'd0;
    wire [2:0]  s_arprot  = 3'd0;
    wire        s_arvalid = 1'b0;  wire s_arready;
    wire [31:0] s_rdata;  wire [1:0] s_rresp;
    wire        s_rvalid;  wire s_rready = 1'b1;

    //--------------------------------------------------------------
    // AXI4 master 신호
    //--------------------------------------------------------------
    wire        M_ARVALID, M_ARREADY, M_RVALID, M_RREADY, M_RLAST;
    wire [31:0] M_ARADDR, M_RDATA;
    wire [3:0]  M_ARID, M_RID, M_RUSER;
    wire [7:0]  M_ARLEN;
    wire [2:0]  M_ARSIZE, M_ARPROT;
    wire [1:0]  M_ARBURST, M_ARLOCK, M_RRESP;
    wire [3:0]  M_ARCACHE, M_ARQOS, M_ARREGION, M_ARUSER;

    wire        M_AWVALID, M_AWREADY, M_WVALID, M_WREADY, M_WLAST, M_BVALID, M_BREADY, M_BUSER;
    wire [31:0] M_AWADDR, M_WDATA;
    wire [3:0]  M_AWID, M_WSTRB, M_WID, M_WUSER, M_BID;
    wire [7:0]  M_AWLEN;
    wire [2:0]  M_AWSIZE, M_AWPROT;
    wire [1:0]  M_AWBURST, M_AWLOCK, M_BRESP;
    wire [3:0]  M_AWCACHE, M_AWQOS, M_AWREGION, M_AWUSER;

    wire network_done, network_done_led;
    /* verilator lint_off UNUSED */
    wire _unused_top = network_done | network_done_led;
    /* verilator lint_on UNUSED */

    //--------------------------------------------------------------
    // DUT
    //--------------------------------------------------------------
    yolo_engine #(
        .C_S_AXI_DATA_WIDTH(32), .C_S_AXI_ADDR_WIDTH(4),
        .AXI_M_WIDTH_AD(32),     .AXI_M_WIDTH_DA(32), .AXI_M_WIDTH_ID(4)
    ) u_dut (
        .clk(clk), .rstn(rstn),
        .S_AXI_AWADDR(s_awaddr), .S_AXI_AWPROT(s_awprot),
        .S_AXI_AWVALID(s_awvalid), .S_AXI_AWREADY(s_awready),
        .S_AXI_WDATA(s_wdata), .S_AXI_WSTRB(s_wstrb),
        .S_AXI_WVALID(s_wvalid), .S_AXI_WREADY(s_wready),
        .S_AXI_BRESP(s_bresp), .S_AXI_BVALID(s_bvalid),
        .S_AXI_BREADY(s_bready),
        .S_AXI_ARADDR(s_araddr), .S_AXI_ARPROT(s_arprot),
        .S_AXI_ARVALID(s_arvalid), .S_AXI_ARREADY(s_arready),
        .S_AXI_RDATA(s_rdata), .S_AXI_RRESP(s_rresp),
        .S_AXI_RVALID(s_rvalid), .S_AXI_RREADY(s_rready),
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

    //--------------------------------------------------------------
    // DRAM 모델 (단일 outstanding burst, 단순)
    //--------------------------------------------------------------
    reg [31:0] dram [0:DRAM_WORDS-1];

    // AXI Read
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
            rd_beat_r <= 8'd0; rd_len_r <= 8'd0; rd_id_r <= 4'd0;
        end else begin
            if (!rd_busy_r) begin
                if (M_ARVALID) begin
                    rd_busy_r <= 1'b1; rd_addr_r <= M_ARADDR;
                    rd_len_r <= M_ARLEN; rd_beat_r <= 8'd0; rd_id_r <= M_ARID;
                end
            end else if (M_RREADY) begin
                if (rd_beat_r == rd_len_r) rd_busy_r <= 1'b0;
                else begin
                    rd_addr_r <= rd_addr_r + 32'd4;
                    rd_beat_r <= rd_beat_r + 8'd1;
                end
            end
        end
    end

    // AXI Write
    reg wr_aw_r, wr_w_r, wr_b_r;
    reg [31:0] wr_addr_r;
    reg [7:0]  wr_beat_r, wr_len_r;
    reg [3:0]  wr_id_r;
    assign M_AWREADY = !wr_aw_r;
    assign M_WREADY  = wr_w_r;
    assign M_BVALID  = wr_b_r;
    assign M_BRESP   = 2'b00;
    assign M_BID     = wr_id_r;
    assign M_BUSER   = 1'b0;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            wr_aw_r <= 1'b0; wr_w_r <= 1'b0; wr_b_r <= 1'b0;
            wr_addr_r <= 32'd0; wr_beat_r <= 8'd0; wr_len_r <= 8'd0; wr_id_r <= 4'd0;
        end else begin
            if (!wr_aw_r && M_AWVALID) begin
                wr_aw_r <= 1'b1; wr_w_r <= 1'b1;
                wr_addr_r <= M_AWADDR; wr_len_r <= M_AWLEN;
                wr_beat_r <= 8'd0; wr_id_r <= M_AWID;
            end
            if (wr_w_r && M_WVALID) begin
                dram[wr_addr_r[23:2]] <= M_WDATA;
                if (M_WLAST) begin
                    wr_w_r <= 1'b0; wr_aw_r <= 1'b0; wr_b_r <= 1'b1;
                end else begin
                    wr_addr_r <= wr_addr_r + 32'd4;
                    wr_beat_r <= wr_beat_r + 8'd1;
                end
            end
            if (wr_b_r && M_BREADY) wr_b_r <= 1'b0;
        end
    end

    //--------------------------------------------------------------
    // Golden 데이터 (16 × 256 × 256 byte)
    //--------------------------------------------------------------
    reg [7:0] golden [0:1048575];

    //--------------------------------------------------------------
    // Mismatch 분포 카운터
    //
    // PASS 기준: |diff| <= TOLERANCE 인 mismatch 는 양자화 정의 차이
    //           (skeleton float vs RTL int)로 간주 → 무시.
    // 즉 TOLERANCE 초과 mismatch (= mm_tol_fail) 가 0 이면 PASS.
    //--------------------------------------------------------------
    parameter TOLERANCE = 1;      // |got - exp| <= 1 까지 허용

    integer mm_total;             // 엄격 (got != exp) 카운트
    integer mm_tol_fail;          // |diff| > TOLERANCE 인 mismatch (PASS 판정용)
    integer mm_per_fi  [0:15];
    integer mm_per_rb  [0:127];   // rb = h/2
    integer mm_per_cb  [0:127];   // cb = w/2
    integer mm_sub_h_0, mm_sub_h_1;
    integer mm_sub_w_0, mm_sub_w_1;
    integer mm_cb_0_only;          // cb=0 (left edge) 인 mismatch
    integer mm_print_cnt;
    integer first_mm_fi, first_mm_h, first_mm_w;
    reg     first_mm_found;
    reg [7:0] first_mm_got, first_mm_exp;

    integer i;
    integer mm_pos, mm_neg;        // diff 부호 통계 (got > exp vs got < exp)
    integer sum_diff;              // 평균 diff 추정
    integer mm_diff_hist [-8:8];   // diff 분포 (-8 ~ +8)

    // unified delta-dist counters (l13 포맷)
    integer cnt_d1, cnt_d2, cnt_d3, cnt_d4_8, cnt_d_big;
    integer cnt_pos, cnt_neg;
    integer max_diff;

    //--------------------------------------------------------------
    // Stimulus
    //--------------------------------------------------------------
    integer ti, tj;
    initial begin
        rstn = 1'b0;
        mm_total = 0;
        mm_tol_fail = 0;
        mm_print_cnt = 0;
        first_mm_found = 1'b0;
        mm_sub_h_0 = 0; mm_sub_h_1 = 0;
        mm_sub_w_0 = 0; mm_sub_w_1 = 0;
        mm_cb_0_only = 0;
        mm_pos = 0; mm_neg = 0; sum_diff = 0;
        for (i = 0; i < 16;  i = i + 1) mm_per_fi[i] = 0;
        for (i = 0; i < 128; i = i + 1) begin
            mm_per_rb[i] = 0;
            mm_per_cb[i] = 0;
        end
        for (i = -8; i <= 8; i = i + 1) mm_diff_hist[i] = 0;

        // 1) DRAM 초기화
        for (i = 0; i < DRAM_WORDS; i = i + 1) dram[i] = 32'd0;

        // 2) .mem 적재 (Vivado xsim cwd 기준 6 ../)
        $display("[L0V-TB] Loading DRAM .mem files...");
        $readmemh("../../../../../../testbench/inout_data_sw/gen_wgt_dram.mem",
                  dram, 0, WGT_WORDS-1);
        $readmemh("../../../../../../testbench/inout_data_sw/gen_bias_dram.mem",
                  dram, BIAS_OFF_W, BIAS_OFF_W + BIAS_WORDS - 1);
        $readmemh("../../../../../../testbench/inout_data_sw/gen_ifm_dram.mem",
                  dram, IFM_OFF_W, IFM_OFF_W + IFM_WORDS - 1);
        $readmemh("../../../../../../testbench/inout_data_sw/log_feamap/CONV00_output.hex",
                  golden);

        $display("[L0V-TB] DRAM[0]=%08x  IFM[%0d]=%08x  GOLDEN[0]=%02x",
                 dram[0], IFM_OFF_W, dram[IFM_OFF_W], golden[0]);

        // 3) AXI slave reg 강제 설정 (DRAM base 주소)
        force u_dut.u_axi.slv_reg1 = 32'h0000_0000;  // wgt base
        force u_dut.u_axi.slv_reg2 = 32'h00B0_0000;  // ifm base
        force u_dut.u_axi.slv_reg3 = 32'h00C0_0000;  // ofm base

        // 4) Reset 해제
        #(20*PERIOD) rstn = 1'b1;
        #(8*PERIOD);

        // 5) ap_start 펄스 (slv_reg0[0])
        @(posedge clk);
        force u_dut.u_axi.slv_reg0 = 32'h0000_0001;
        @(posedge clk);
        force u_dut.u_axi.slv_reg0 = 32'h0000_0000;
        $display("[L0V-TB][%0t] ap_start sent", $time);

        // 6) L0 완료 대기 (layer_idx 가 0 → 1 로 전이)
        wait (u_dut.layer_idx == 5'd1);
        $display("[L0V-TB][%0t] L0 done (layer_idx -> 1)", $time);
        #(40*PERIOD);

        // 7) 비교
        compare_l0;
        report_stats;

        // 8) cleanup
        release u_dut.u_axi.slv_reg0;
        release u_dut.u_axi.slv_reg1;
        release u_dut.u_axi.slv_reg2;
        release u_dut.u_axi.slv_reg3;
        #(20*PERIOD) $finish;
    end

    //--------------------------------------------------------------
    // 비교 task — 모든 mismatch 의 5축 분포 + 처음 32 개 print
    //--------------------------------------------------------------
    task compare_l0;
        integer fi, hb, wb, sub_h, sub_w;
        integer h, w, cb;
        integer diff, abs;
        reg [31:0] dword;
        reg [7:0]  got, exp;
        begin
            // unified delta-dist counters
            cnt_d1 = 0; cnt_d2 = 0; cnt_d3 = 0; cnt_d4_8 = 0; cnt_d_big = 0;
            cnt_pos = 0; cnt_neg = 0; max_diff = 0;
            for (fi = 0; fi < 16; fi = fi + 1) begin
                for (hb = 0; hb < 128; hb = hb + 1) begin
                    for (wb = 0; wb < 128; wb = wb + 1) begin
                        dword = dram[OFM_OFF_W + fi*16384 + hb*128 + wb];
                        for (sub_h = 0; sub_h < 2; sub_h = sub_h + 1) begin
                            for (sub_w = 0; sub_w < 2; sub_w = sub_w + 1) begin
                                got = dword[(sub_h*2+sub_w)*8 +: 8];
                                h   = hb*2 + sub_h;
                                w   = wb*2 + sub_w;
                                cb  = w >> 1;
                                exp = golden[fi*65536 + h*256 + w];
                                if (got !== exp) begin
                                    mm_total = mm_total + 1;
                                    mm_per_fi[fi] = mm_per_fi[fi] + 1;
                                    mm_per_rb[hb] = mm_per_rb[hb] + 1;
                                    mm_per_cb[cb] = mm_per_cb[cb] + 1;
                                    if (sub_h == 0) mm_sub_h_0 = mm_sub_h_0 + 1;
                                    else            mm_sub_h_1 = mm_sub_h_1 + 1;
                                    if (sub_w == 0) mm_sub_w_0 = mm_sub_w_0 + 1;
                                    else            mm_sub_w_1 = mm_sub_w_1 + 1;
                                    if (cb == 0)    mm_cb_0_only = mm_cb_0_only + 1;
                                    diff = $signed({24'd0, got}) - $signed({24'd0, exp});
                                    sum_diff = sum_diff + diff;
                                    if (diff > 0) mm_pos = mm_pos + 1;
                                    else          mm_neg = mm_neg + 1;
                                    // diff histogram (clip to -8..+8)
                                    if (diff >  8) mm_diff_hist[ 8] = mm_diff_hist[ 8] + 1;
                                    else if (diff < -8) mm_diff_hist[-8] = mm_diff_hist[-8] + 1;
                                    else mm_diff_hist[diff] = mm_diff_hist[diff] + 1;
                                    // tolerance check (|diff| > TOLERANCE 면 PASS 불가)
                                    if ((diff > TOLERANCE) || (diff < -TOLERANCE))
                                        mm_tol_fail = mm_tol_fail + 1;
                                    // unified delta-dist counting (l13 포맷)
                                    abs = (diff < 0) ? -diff : diff;
                                    if (diff > 0) cnt_pos = cnt_pos + 1;
                                    else          cnt_neg = cnt_neg + 1;
                                    if (abs > max_diff) max_diff = abs;
                                    if      (abs == 1) cnt_d1   = cnt_d1   + 1;
                                    else if (abs == 2) cnt_d2   = cnt_d2   + 1;
                                    else if (abs == 3) cnt_d3   = cnt_d3   + 1;
                                    else if (abs <= 8) cnt_d4_8 = cnt_d4_8 + 1;
                                    else               cnt_d_big= cnt_d_big+ 1;
                                    if (!first_mm_found) begin
                                        first_mm_found = 1'b1;
                                        first_mm_fi  = fi;
                                        first_mm_h   = h;
                                        first_mm_w   = w;
                                        first_mm_got = got;
                                        first_mm_exp = exp;
                                    end
                                    if (mm_print_cnt < 8) begin
                                        $display("  [L0V-TB] MISMATCH fi=%0d h=%0d w=%0d got=%02x exp=%02x (d=%0d)",
                                            fi, h, w, got, exp, diff);
                                        mm_print_cnt = mm_print_cnt + 1;
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    endtask

    //--------------------------------------------------------------
    // 통계 리포트
    //--------------------------------------------------------------
    task report_stats;
        integer fi, rb, cb;
        integer non_cb0;
        begin
            // 미사용 경고 억제용 (bespoke 통계 변수는 더 이상 출력하지 않음)
            non_cb0 = mm_total - mm_cb_0_only;

            // unified delta-dist block (l13 포맷)
            $display("[L0V-TB] delta dist : total=%0d  +d=%0d  -d=%0d  max|d|=%0d",
                     mm_total, cnt_pos, cnt_neg, max_diff);
            $display("[L0V-TB]   |d|=1    : %0d  (%0d%%)",
                     cnt_d1, (cnt_d1*100)/((mm_total==0)?1:mm_total));
            $display("[L0V-TB]   |d|=2    : %0d", cnt_d2);
            $display("[L0V-TB]   |d|=3    : %0d", cnt_d3);
            $display("[L0V-TB]   |d|=4..8 : %0d", cnt_d4_8);
            $display("[L0V-TB]   |d|>8    : %0d", cnt_d_big);
            $display("[L0V-TB]   |d|>%0d (tol-exceed) : %0d", TOLERANCE, mm_tol_fail);

            $display("[L0V-TB][Result] OFM mismatch: %0d / 1048576   (tol-exceed: %0d)", mm_total, mm_tol_fail);
            if      (mm_total == 0)    $display("[L0V-TB][Result] *** PASS (exact, 0 mismatches) ***");
            else if (mm_tol_fail == 0) $display("[L0V-TB][Result] *** PASS (within tolerance +-%0d, %0d noise) ***", TOLERANCE, mm_total);
            else                       $display("[L0V-TB][Result] *** FAIL (%0d exceed +-%0d tolerance) ***", mm_tol_fail, TOLERANCE);

            $display("");
            $display("[L0V-TB] ============================================================");
            $display("[L0V-TB] L0 : %s (mismatch=%0d, tol-exceed=%0d)",
                     (mm_tol_fail == 0) ? "PASS" : "FAIL", mm_total, mm_tol_fail);
            $display("[L0V-TB] ============================================================");
        end
    endtask

    //--------------------------------------------------------------
    // Watchdog
    //--------------------------------------------------------------
    initial begin
        repeat (2000) #(1_000_000);
        $display("[L0V-TB] *** TIMEOUT (2 sec sim time) ***");
        $finish;
    end

`endif

endmodule
