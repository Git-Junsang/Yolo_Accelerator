`timescale 1ns / 1ns
//----------------------------------------------------------------+
// conv_top_tb.v — Layer 0 단일 conv end-to-end 검증
//
// 검증 범위:
//   - mac_kern (산술) + gbuff_param (메모리) + ifm_line_buf (라인 버퍼)
//   - L0 (Ci=3, Co=16, H=W=256, 3×3 conv) 의 row_idx=0 OFM
//
// 사전 조건:
//   - yolohw/src/user_define_h.v 의 `define FPGA 줄을 주석 처리.
//     gbuff_param 의 behavioral wgt_mem/bias_mem 및 ifm_line_buf 의
//     g_line[].mem 에 hierarchical 접근 (FPGA IP 인스턴스 사용 시 접근 불가)
//
// 전략:
//   1. hex 파일 ($readmemh) 로 raw IFM/Weight/Bias 로드
//   2. 16-byte entry packing 으로 재배열 → 각 buffer 의 mem 에 직접 대입
//   3. conv_start 펄스 → conv_done 대기
//   4. conv 가 출력한 픽셀 (conv_pixel + conv_ofm_addr) 을 캡쳐
//   5. golden OFM 의 첫 spatial row (= row_idx=0 의 출력 2 row × W cols × Co)
//      와 비교
//----------------------------------------------------------------+
`include "user_define_h.v"

module conv_top_tb;

`ifdef FPGA
    initial begin
        $display("[TB][FATAL] FPGA macro 활성. user_define_h.v 의 `define FPGA 주석 처리 필요.");
        $finish;
    end
`else

    //--------------------------------------------------------------
    // Clock / Reset
    //--------------------------------------------------------------
    parameter CLK_PERIOD = 10;
    reg clk, rstn;
    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    //--------------------------------------------------------------
    // L0 parameters
    //--------------------------------------------------------------
    localparam integer L0_CI         = 3;
    localparam integer L0_CO         = 16;
    localparam integer L0_H          = 256;
    localparam integer L0_W          = 256;
    localparam integer L0_OFM_W_HALF = L0_W / 2;
    localparam integer L0_OFM_H_HALF = L0_H / 2;
    localparam integer L0_W_BLOCKS   = L0_W / 4;
    localparam integer L0_IFM_BYTES  = L0_H * L0_W * L0_CI;
    localparam integer L0_OFM_BYTES  = L0_CO * L0_H * L0_W;
    localparam integer L0_WGT_BYTES  = L0_CO * L0_CI * 9;

    parameter IFM_HEX   = "../../../../../../sim/inout_data_sw/log_feamap/CONV00_input.hex";
    parameter WGT_HEX   = "../../../../../../sim/inout_data_sw/log_param/CONV00_param_weight.hex";
    parameter BIAS_HEX  = "../../../../../../sim/inout_data_sw/log_param/CONV00_param_biases.hex";
    parameter SCALE_HEX = "../../../../../../sim/inout_data_sw/log_param/CONV00_param_scales.hex";
    parameter OFM_HEX   = "../../../../../../sim/inout_data_sw/log_feamap/CONV00_output.hex";

    //--------------------------------------------------------------
    // ifm_line_buf 결선 (DMA write port 는 TB 가 직접 mem 에 적재하므로 tie LOW)
    //--------------------------------------------------------------
    wire         conv_ifm_re;
    wire [11:0]  conv_ifm_row, conv_ifm_col;
    wire [7:0]   conv_ifm_acc;
    wire [287:0] ifm_00, ifm_01, ifm_10, ifm_11;
    wire         ifm_vld;

    ifm_line_buf u_line_buf (
        .clk(clk), .rstn(rstn),
        .i_mode(1'b0),                          // 3×3
        .i_w_blocks(12'd64),                    // L0
        .i_ci_groups(8'd1),
        .i_w(12'd256),
        .i_h(12'd256),
        .i_line_valid(4'b1111),
        .i_dma_wr_en(1'b0),
        .i_dma_wr_line(2'd0),
        .i_dma_wr_addr(11'd0),
        .i_dma_wr_data(128'd0),
        .i_rd_en(conv_ifm_re),
        .i_rb(conv_ifm_row), .i_cb(conv_ifm_col),
        .i_acc_cyc(conv_ifm_acc),
        .o_ifm_00(ifm_00), .o_ifm_01(ifm_01),
        .o_ifm_10(ifm_10), .o_ifm_11(ifm_11),
        .o_vld(ifm_vld)
    );
    /* verilator lint_off UNUSED */ wire _uv = ifm_vld; /* verilator lint_on UNUSED */

    //--------------------------------------------------------------
    // conv_top — gbuff_param DMA port 는 비활성 (TB 가 직접 mem 적재)
    //--------------------------------------------------------------
    reg          conv_start;
    wire         conv_done;
    wire [31:0]  conv_pixel;
    wire         conv_pixel_vld;
    wire [25:0]  conv_ofm_addr;

    conv_top u_conv (
        .clk(clk), .rstn(rstn),
        .i_start(conv_start),
        .o_done(conv_done),
        .i_mode(1'b0),
        .i_ofm_w_half(12'd128),
        .i_ofm_h_half(12'd128),
        .i_co_total(12'd16),
        .i_acc_len(8'd1),
        .i_wgt_base(10'd0),
        .i_bias_base(12'd0),
        .i_shift(l0_shift),                     // CONV00_param_scales.hex 에서 계산
        .dma_wgt_we(1'b0),  .dma_wgt_addr(12'd0),  .dma_wgt_data(72'd0),
        .dma_bias_we(1'b0), .dma_bias_addr(12'd0), .dma_bias_data(32'd0),
        .o_ifm_re(conv_ifm_re),
        .o_ifm_row(conv_ifm_row), .o_ifm_col(conv_ifm_col), .o_ifm_acc(conv_ifm_acc),
        .i_ifm_00(ifm_00), .i_ifm_01(ifm_01),
        .i_ifm_10(ifm_10), .i_ifm_11(ifm_11),
        .o_pixel(conv_pixel),
        .o_pixel_vld(conv_pixel_vld),
        .o_ofm_addr(conv_ofm_addr)
    );

    //--------------------------------------------------------------
    // OFM 캡쳐 (conv_top 이 출력하는 픽셀을 reg array 에 누적)
    //--------------------------------------------------------------
    // 16 filter × 128 × 128 = 262144 entries → 18-bit address
    reg [31:0] ofm_cap [0:262143];

    always @(posedge clk) begin
        if (conv_pixel_vld) ofm_cap[conv_ofm_addr[17:0]] <= conv_pixel;
    end

    //--------------------------------------------------------------
    // TB-local raw buffer + golden
    //--------------------------------------------------------------
    reg [7:0]  ifm_raw   [0:L0_IFM_BYTES-1];
    reg [7:0]  wgt_raw   [0:L0_WGT_BYTES-1];
    reg [15:0] bias_raw  [0:L0_CO-1];
    reg [15:0] scale_raw [0:L0_CO-1];   // 2^shift per filter (e.g. 0x0080 = 128 = 2^7)
    reg [7:0]  ofm_gold  [0:L0_OFM_BYTES-1];

    // shift = log2(scale_raw[0]) — L0 에서 모든 filter 동일 (0x0080 → 7)
    reg [4:0] l0_shift;

    function [7:0] ifm_byte;
        input integer c; input integer h; input integer w;
        integer idx;
        begin
            if (c<0||c>=L0_CI||h<0||h>=L0_H||w<0||w>=L0_W) ifm_byte = 8'd0;
            else begin idx = c*L0_H*L0_W + h*L0_W + w; ifm_byte = ifm_raw[idx]; end
        end
    endfunction

    function [7:0] wgt_byte;
        input integer ff; input integer cc; input integer kk;
        begin
            if (cc >= L0_CI) wgt_byte = 8'd0;
            else             wgt_byte = wgt_raw[ff*27 + cc*9 + kk];
        end
    endfunction

    //--------------------------------------------------------------
    // 비교 / 통계
    //--------------------------------------------------------------
    integer mismatch_cnt;
    integer compare_cnt;
    integer first_mismatch_at;

    //--------------------------------------------------------------
    // Stimulus
    //--------------------------------------------------------------
    integer f, ci, k, r, c_blk, col_local, ch_local, b_in_entry, entry_idx;
    reg [127:0] entry_data;
    reg [287:0] wgt_entry_288;
    reg [7:0]   wb;
    integer dummy;

    initial begin
        rstn         = 1'b0;
        conv_start   = 1'b0;
        mismatch_cnt = 0;
        compare_cnt  = 0;
        first_mismatch_at = -1;

        // ----- Hex 로드 -----
        $display("[conv_top_tb] Loading hex files...");
        $readmemh(IFM_HEX,   ifm_raw);
        $readmemh(WGT_HEX,   wgt_raw);
        $readmemh(BIAS_HEX,  bias_raw);
        $readmemh(SCALE_HEX, scale_raw);
        $readmemh(OFM_HEX,   ofm_gold);

        // scale_raw[f] = 2^shift (e.g. 0x0080 = 128 = 2^7 → shift=7)
        // L0 에서 모든 filter 동일 — filter 0 기준으로 shift 계산
        l0_shift = 0;
        begin : blk_shift
            reg [15:0] sv;
            sv = scale_raw[0];
            while (sv > 16'h0001) begin sv = sv >> 1; l0_shift = l0_shift + 5'd1; end
        end
        $display("[conv_top_tb] L0 shift = %0d  (scale=0x%04h)", l0_shift, scale_raw[0]);

        // ----- gbuff_param weight 적재 (16 filter × 4 slot = 64 entry) -----
        for (f = 0; f < L0_CO; f = f + 1) begin
            wgt_entry_288 = 288'd0;
            for (ci = 0; ci < 4; ci = ci + 1) begin
                for (k = 0; k < 9; k = k + 1) begin
                    wb = wgt_byte(f, ci, k);
                    wgt_entry_288[(ci*9 + k)*8 +: 8] = wb;
                end
            end
            u_conv.u_gbuff.wgt_mem[f*4 + 0] = wgt_entry_288[71:0];
            u_conv.u_gbuff.wgt_mem[f*4 + 1] = wgt_entry_288[143:72];
            u_conv.u_gbuff.wgt_mem[f*4 + 2] = wgt_entry_288[215:144];
            u_conv.u_gbuff.wgt_mem[f*4 + 3] = wgt_entry_288[287:216];
        end
        $display("[conv_top_tb] Weights preloaded (%0d filter × 4 slot)", L0_CO);

        // ----- gbuff_param bias 적재 (sign-extended) -----
        for (f = 0; f < L0_CO; f = f + 1) begin
            u_conv.u_gbuff.bias_mem[f] = { {16{bias_raw[f][15]}}, bias_raw[f] };
        end
        $display("[conv_top_tb] Biases preloaded (%0d)", L0_CO);

        // ----- ifm_line_buf 적재 (cyclic mapping: r → phys line) -----
        //   r=0 (window pos 0, IFM row -1, padding) → phys line 3
        //   r=1 (IFM row 0)                          → phys line 0
        //   r=2 (IFM row 1)                          → phys line 1
        //   r=3 (IFM row 2)                          → phys line 2
        for (r = 0; r < 4; r = r + 1) begin
            for (c_blk = 0; c_blk < L0_W_BLOCKS; c_blk = c_blk + 1) begin
                entry_data = 128'd0;
                for (col_local = 0; col_local < 4; col_local = col_local + 1) begin
                    for (ch_local = 0; ch_local < 4; ch_local = ch_local + 1) begin
                        b_in_entry = col_local*4 + ch_local;
                        if ((r - 1) < 0) wb = 8'd0;
                        else             wb = ifm_byte(ch_local, r-1, c_blk*4 + col_local);
                        entry_data[b_in_entry*8 +: 8] = wb;
                    end
                end
                entry_idx = c_blk;
                case (r)
                    0: u_line_buf.g_line[3].mem[entry_idx] = entry_data;
                    1: u_line_buf.g_line[0].mem[entry_idx] = entry_data;
                    2: u_line_buf.g_line[1].mem[entry_idx] = entry_data;
                    3: u_line_buf.g_line[2].mem[entry_idx] = entry_data;
                endcase
            end
        end
        $display("[conv_top_tb] IFM preloaded (4 rows, cyclic-mapped)");

        // 로드 검증 덤프
        dump_wgt_bias;
        $display("[DBG] gold[f=0,row=0,col=0]=0x%02h  gold[f=0,row=0,col=1]=0x%02h",
            ofm_gold[0*L0_H*L0_W + 0*L0_W + 0], ofm_gold[0*L0_H*L0_W + 0*L0_W + 1]);
        $display("[DBG] IFM[ch0,row0,col0]=0x%02h  IFM[ch1,row0,col0]=0x%02h  IFM[ch2,row0,col0]=0x%02h",
            ifm_raw[0*L0_H*L0_W + 0], ifm_raw[1*L0_H*L0_W + 0], ifm_raw[2*L0_H*L0_W + 0]);

        // ofm_cap 초기화 (X 방지)
        for (dummy = 0; dummy < 262144; dummy = dummy + 1) ofm_cap[dummy] = 32'd0;

        // ----- Reset 해제 + conv 시작 -----
        #(8*CLK_PERIOD) rstn = 1'b1;
        #(4*CLK_PERIOD);

        @(posedge clk);
        conv_start <= 1'b1;
        @(posedge clk);
        conv_start <= 1'b0;
        $display("[conv_top_tb] conv_start asserted @ t=%0t", $time);

        // ----- conv_done 대기 -----
        wait (conv_done == 1'b1);
        @(posedge clk);
        $display("[conv_top_tb] conv_done received @ t=%0t", $time);

        // ----- 비교: row_idx=0 (= OFM row 0,1) × 16 filter -----
        compare_row0;

        $display("============================================================");
        $display("[conv_top_tb] compare DONE: compared=%0d  mismatched=%0d",
                 compare_cnt, mismatch_cnt);
        if (mismatch_cnt == 0) $display("[conv_top_tb] *** L0 row 0 PASSED ***");
        else                    $display("[conv_top_tb] *** L0 row 0 FAILED (first @ byte %0d) ***",
                                         first_mismatch_at);
        $display("============================================================");

        #(20*CLK_PERIOD) $finish;
    end

    //--------------------------------------------------------------
    // 비교 task
    //--------------------------------------------------------------
    task compare_row0;
        integer fi, col, sub, ofm_addr, gold_idx;
        reg [31:0] wd;
        reg [7:0]  hwb, gldb;
        begin
            for (fi = 0; fi < L0_CO; fi = fi + 1) begin
                for (col = 0; col < L0_OFM_W_HALF; col = col + 1) begin
                    ofm_addr = fi * L0_OFM_H_HALF * L0_OFM_W_HALF + 0 + col;
                    wd       = ofm_cap[ofm_addr];
                    for (sub = 0; sub < 4; sub = sub + 1) begin
                        hwb = wd[sub*8 +: 8];
                        case (sub)
                            0: gold_idx = fi*L0_H*L0_W + 0*L0_W + (2*col    );
                            1: gold_idx = fi*L0_H*L0_W + 0*L0_W + (2*col + 1);
                            2: gold_idx = fi*L0_H*L0_W + 1*L0_W + (2*col    );
                            3: gold_idx = fi*L0_H*L0_W + 1*L0_W + (2*col + 1);
                        endcase
                        gldb = ofm_gold[gold_idx];
                        compare_cnt = compare_cnt + 1;
                        if (hwb !== gldb) begin
                            if (first_mismatch_at < 0) first_mismatch_at = compare_cnt - 1;
                            if (mismatch_cnt < 16) begin
                                $display("[MISMATCH] f=%0d col=%0d sub=%0d  hw=0x%02h  gold=0x%02h",
                                         fi, col, sub, hwb, gldb);
                            end
                            mismatch_cnt = mismatch_cnt + 1;
                        end
                    end
                end
            end
        end
    endtask

    //--------------------------------------------------------------
    // DEBUG: mac_pixel_vld 최초 16개 출력 + 내부 신호 덤프
    //--------------------------------------------------------------
    integer dbg_pix_cnt;
    initial dbg_pix_cnt = 0;

    always @(posedge clk) begin
        if (conv_pixel_vld && dbg_pix_cnt < 16) begin
            $display("[DBG_PIX] #%0d  addr=0x%06h  pixel=0x%08h  fil=%0d col=%0d row=%0d  out_cnt=%0d",
                dbg_pix_cnt,
                conv_ofm_addr,
                conv_pixel,
                u_conv.fil_idx, u_conv.col_idx, u_conv.row_idx,
                u_conv.out_cnt);
            dbg_pix_cnt = dbg_pix_cnt + 1;
        end
        // mac_vld_d 최초 4회: IFM/WGT 입력 덤프 (타이밍 정렬 확인)
        if (u_conv.mac_vld_d && dbg_pix_cnt == 0) begin
            $display("[DBG_MAC] mac_vld_d=1  wgt[7:0]=0x%02h  ifm00[7:0]=0x%02h  bias=0x%08h  col=%0d",
                u_conv.wgt_data[7:0],
                ifm_00[7:0],
                u_conv.bias_data,
                u_conv.col_idx);
        end
    end

    // 가중치/바이어스 로드 후 첫 entry 검증 (initial 보조)
    task dump_wgt_bias;
        integer fi;
        begin
            $display("--- WGT/BIAS DUMP (filter 0..2) ---");
            for (fi = 0; fi < 3; fi = fi + 1) begin
                $display("  wgt_mem[%0d]=%0h  wgt_mem[%0d]=%0h",
                    fi*4+0, u_conv.u_gbuff.wgt_mem[fi*4+0],
                    fi*4+1, u_conv.u_gbuff.wgt_mem[fi*4+1]);
                $display("  bias_mem[%0d]=0x%08h", fi, u_conv.u_gbuff.bias_mem[fi]);
            end
            $display("  IFM line_buf[phys0][0]=%0h", u_line_buf.g_line[0].mem[0]);
            $display("  IFM line_buf[phys3][0]=%0h (padding row)", u_line_buf.g_line[3].mem[0]);
            $display("-----------------------------------");
        end
    endtask

    //--------------------------------------------------------------
    // Watchdog
    //--------------------------------------------------------------
    initial begin
        #(50_000_000 * CLK_PERIOD);
        $display("[conv_top_tb] *** TIMEOUT ***");
        $finish;
    end
`endif

endmodule
