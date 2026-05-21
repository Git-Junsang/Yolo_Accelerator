`timescale 1ns / 1ps
//----------------------------------------------------------------+
// ifm_line_buf_tb.v — IFM line buffer Phase 3 격리 검증
//
// 검증 목표:
//   - DMA write 경로 (i_dma_wr_en, i_dma_wr_line, i_dma_wr_addr, i_dma_wr_data)
//   - Cyclic row mapping (base_line = i_rb[0] ? 1 : 3)
//   - 3×3 window read at boundary (left/right col padding, top/bottom row padding)
//   - 다중 rb 값에서의 정상 동작 (L2 LB overflow 버그 회귀 방지)
//   - lb_addr_calc 수정 후 의도: row r → bank r%4 의 addr 0..w_blocks-1
//
// 동작 모델 (3×3 mode):
//   col_start  = 2*Cb - 1
//   base_entry = col_start >> 2  (= floor)
//   offset     = col_start[1:0]
//   row_off    = i_acc_cyc × w_blocks   (acc_cyc=0 에서 row_off=0)
//
//   physical line index = (base_line + window_row) mod 4
//     base_line = i_rb[0] ? 1 : 3
//
//   row j (window slot j) 의 IFM row = 2*Rb - 1 + j
//   row_invalid[j] = (IFM_row < 0) || (IFM_row >= H)
//   col_invalid[k] = (col_pos_k < 0) || (col_pos_k >= W)
//
// 시나리오:
//   Scenario A: 단일 rb=0, IFM rows 0,1,2 + row -1 padding
//   Scenario B: rb=2 (가운데), 4 rows in 4 banks, 패딩 없음
//   Scenario C: 마지막 rb (rows W-2 ~ W+1 중 bottom padding 발생)
//   Scenario D: 컬럼 boundary (cb=0 left pad, cb=W_h-1 right pad)
//----------------------------------------------------------------+
`include "user_define_h.v"

module ifm_line_buf_tb;

`ifdef FPGA
    initial begin
        $display("[ifm_line_buf_tb][FATAL] FPGA macro 활성. user_define_h.v 의 `define FPGA 주석 처리 필요.");
        $finish;
    end
`else

    parameter CLK_PERIOD = 10;
    reg clk, rstn;
    initial begin clk = 1'b0; forever #(CLK_PERIOD/2) clk = ~clk; end

    //--------------------------------------------------------------
    // Test 사이즈
    //   W=16, H=8 → w_blocks=4, ofm_h_half=4 (rb=0..3)
    //   Ci=4 (=1 ci_group), 3×3 conv mode
    //--------------------------------------------------------------
    localparam integer W_IFM    = 16;
    localparam integer H_IFM    = 8;
    localparam integer W_BLOCKS = W_IFM / 4;     // 4 — DMA entry 수 per row
    localparam integer OFM_WH   = W_IFM / 2;     // 8 — cb 범위 0..7
    localparam integer CI_GRP   = 1;
    localparam integer RB_MAX   = H_IFM / 2;     // 4 (rb=0..3)

    //--------------------------------------------------------------
    // DUT signals
    //--------------------------------------------------------------
    reg          dut_mode;
    reg  [11:0]  dut_w_blocks;
    reg  [7:0]   dut_ci_groups;
    reg  [11:0]  dut_w;
    reg  [11:0]  dut_h;
    reg  [3:0]   dut_line_valid;

    reg          dut_dma_wr_en;
    reg  [1:0]   dut_dma_wr_line;
    reg  [10:0]  dut_dma_wr_addr;
    reg  [127:0] dut_dma_wr_data;

    reg          dut_rd_en;
    reg  [11:0]  dut_rb;
    reg  [11:0]  dut_cb;
    reg  [7:0]   dut_acc;

    wire [287:0] dut_ifm_00, dut_ifm_01, dut_ifm_10, dut_ifm_11;
    wire         dut_vld;

    ifm_line_buf u_dut (
        .clk(clk), .rstn(rstn),
        .i_mode       (dut_mode),
        .i_w_blocks   (dut_w_blocks),
        .i_ci_groups  (dut_ci_groups),
        .i_w          (dut_w),
        .i_h          (dut_h),
        .i_line_valid (dut_line_valid),
        .i_dma_wr_en  (dut_dma_wr_en),
        .i_dma_wr_line(dut_dma_wr_line),
        .i_dma_wr_addr(dut_dma_wr_addr),
        .i_dma_wr_data(dut_dma_wr_data),
        .i_rd_en  (dut_rd_en),
        .i_rb     (dut_rb),
        .i_cb     (dut_cb),
        .i_acc_cyc(dut_acc),
        .o_ifm_00(dut_ifm_00),
        .o_ifm_01(dut_ifm_01),
        .o_ifm_10(dut_ifm_10),
        .o_ifm_11(dut_ifm_11),
        .o_vld(dut_vld)
    );

    //--------------------------------------------------------------
    // Reference IFM 모델 (TB software side)
    //   ifm_ref[ch][row][col] = ((row << 4) | (col & 0x0F) ^ ch) & 0xFF
    //   결정적 비-trivial 패턴 — 단순 0/255 만으로 cyclic mapping 오작동을
    //   못 잡으므로 row/col/ch 모두 byte 에 반영되는 함수 사용.
    //--------------------------------------------------------------
    function [7:0] ifm_byte;
        input integer ch;
        input integer row;
        input integer col;
        begin
            if (row < 0 || row >= H_IFM || col < 0 || col >= W_IFM ||
                ch  < 0 || ch  >= 4)
                ifm_byte = 8'd0;
            else
                ifm_byte = ((row << 4) | (col & 4'hF)) ^ ch;
        end
    endfunction

    // 한 4-col × 4-ch entry packing: byte b = col*4 + ch (LSB byte = col0 ch0)
    function [127:0] pack_entry;
        input integer row;
        input integer cblk;
        integer cc, ch, b;
        begin
            pack_entry = 128'd0;
            for (cc = 0; cc < 4; cc = cc + 1)
                for (ch = 0; ch < 4; ch = ch + 1) begin
                    b = cc*4 + ch;
                    pack_entry[b*8 +: 8] = ifm_byte(ch, row, cblk*4 + cc);
                end
        end
    endfunction

    //--------------------------------------------------------------
    // DMA write helper — row r → phys bank r%4, addr 0..OFM_WH-1
    //   (yolo_engine 의 lb_addr_calc = eir 적용 후 매핑)
    //--------------------------------------------------------------
    task automatic dma_load_row;
        input integer r;
        integer cblk;
        begin
            for (cblk = 0; cblk < W_BLOCKS; cblk = cblk + 1) begin
                @(posedge clk);
                dut_dma_wr_en   <= 1'b1;
                dut_dma_wr_line <= r % 4;
                dut_dma_wr_addr <= cblk[10:0];
                dut_dma_wr_data <= pack_entry(r, cblk);
            end
            @(posedge clk);
            dut_dma_wr_en   <= 1'b0;
            dut_dma_wr_addr <= 11'd0;
            dut_dma_wr_data <= 128'd0;
        end
    endtask

    //--------------------------------------------------------------
    // 3×3 packing reference (mac_kern 의 i = c_local*9 + kh*3 + kw 와 동일)
    //   ifm_00 = window[ln=0..2][cl=0..2] × 4 ch
    //   ifm_01 = window[ln=0..2][cl=1..3]
    //   ifm_10 = window[ln=1..3][cl=0..2]
    //   ifm_11 = window[ln=1..3][cl=1..3]
    //
    //   각 (ln, cl) 의 픽셀 IFM 위치:
    //     IFM_row = 2*rb - 1 + ln
    //     IFM_col = 2*cb - 1 + cl
    //   row/col 이 [0, H/W) 밖이면 0 padding.
    //--------------------------------------------------------------
    function [287:0] ref_ifm_box;
        input integer rb;
        input integer cb;
        input integer ln_lo;   // 0 or 1 (window row offset)
        input integer cl_lo;   // 0 or 1 (window col offset)
        integer cl, kh, kw, idx;
        integer irow, icol;
        reg [7:0] b;
        integer ch;
        begin
            ref_ifm_box = 288'd0;
            for (cl = 0; cl < 4; cl = cl + 1) begin
                for (kh = 0; kh < 3; kh = kh + 1) begin
                    for (kw = 0; kw < 3; kw = kw + 1) begin
                        idx = cl * 9 + kh * 3 + kw;
                        irow = 2*rb - 1 + ln_lo + kh;
                        icol = 2*cb - 1 + cl_lo + kw;
                        // c_local (= channel local to ci_group) 는 cl 이 아니라
                        // mac_kern 의 c_local 차원. ifm_line_buf 는 wid c_local=cl 매핑.
                        //   window[ln][cl][ch] → ifm_xx[idx*8 +: 8] for ch = cl
                        //   ※ mac_kern 의 i = c_local*9 + kh*3 + kw, c_local 은 채널 0..3.
                        //   ifm_line_buf 는 win[kh][kw][cl_loc] 으로 packing
                        //   (cl_loc 가 channel 역할). 따라서 ref 도 cl 을 ch 로 해석.
                        ch = cl;
                        if (irow < 0 || irow >= H_IFM || icol < 0 || icol >= W_IFM)
                            b = 8'd0;
                        else
                            b = ifm_byte(ch, irow, icol);
                        ref_ifm_box[idx*8 +: 8] = b;
                    end
                end
            end
        end
    endfunction

    //--------------------------------------------------------------
    // Read probe — i_rb / i_cb 설정 후 2 cycle 뒤에 output 확정
    //   ifm_line_buf 의 latency:
    //     T   : i_rd_en + (rb, cb, acc) 발사
    //     T+1 : BRAM data + pipeline_reg 갱신
    //     T+2 : output_reg 갱신 (o_ifm_** 확정), o_vld=1
    //--------------------------------------------------------------
    integer    mismatch_total;

    task automatic probe;
        input integer rb;
        input integer cb;
        input integer scenario_id;   // 디버그용 식별자
        reg [287:0] exp_00, exp_01, exp_10, exp_11;
        integer mm;
        begin
            mm = 0;

            // 1 cycle dead time
            @(posedge clk);
            dut_rd_en <= 1'b1;
            dut_rb    <= rb[11:0];
            dut_cb    <= cb[11:0];
            dut_acc   <= 8'd0;

            @(posedge clk);
            dut_rd_en <= 1'b0;

            // 2 cycle 후 output 확정
            @(posedge clk);
            @(posedge clk);

            exp_00 = ref_ifm_box(rb, cb, 0, 0);
            exp_01 = ref_ifm_box(rb, cb, 0, 1);
            exp_10 = ref_ifm_box(rb, cb, 1, 0);
            exp_11 = ref_ifm_box(rb, cb, 1, 1);

            if (dut_ifm_00 !== exp_00) begin
                $display("[S%0d MISMATCH] rb=%0d cb=%0d ifm_00:", scenario_id, rb, cb);
                $display("  got=%h", dut_ifm_00);
                $display("  exp=%h", exp_00);
                mm = mm + 1;
            end
            if (dut_ifm_01 !== exp_01) begin
                $display("[S%0d MISMATCH] rb=%0d cb=%0d ifm_01:", scenario_id, rb, cb);
                $display("  got=%h", dut_ifm_01);
                $display("  exp=%h", exp_01);
                mm = mm + 1;
            end
            if (dut_ifm_10 !== exp_10) begin
                $display("[S%0d MISMATCH] rb=%0d cb=%0d ifm_10:", scenario_id, rb, cb);
                $display("  got=%h", dut_ifm_10);
                $display("  exp=%h", exp_10);
                mm = mm + 1;
            end
            if (dut_ifm_11 !== exp_11) begin
                $display("[S%0d MISMATCH] rb=%0d cb=%0d ifm_11:", scenario_id, rb, cb);
                $display("  got=%h", dut_ifm_11);
                $display("  exp=%h", exp_11);
                mm = mm + 1;
            end
            mismatch_total = mismatch_total + mm;
        end
    endtask

    //--------------------------------------------------------------
    // 시나리오들
    //--------------------------------------------------------------
    integer s_mm_start;

    // iverilog 는 generate 인덱스를 동적 변수로 못 받으므로 4개 bank 를 명시적으로 unroll.
    task automatic init_clear_banks;
        integer ii;
        begin
            for (ii = 0; ii < 2048; ii = ii + 1) begin
                u_dut.g_line[0].mem[ii] = 128'd0;
                u_dut.g_line[1].mem[ii] = 128'd0;
                u_dut.g_line[2].mem[ii] = 128'd0;
                u_dut.g_line[3].mem[ii] = 128'd0;
            end
        end
    endtask

    task automatic scenario_A;
        begin
            $display("============================================================");
            $display("[Scenario A] rb=0  rows {-1(pad), 0, 1, 2} → banks {3, 0, 1, 2}");
            $display("============================================================");
            s_mm_start = mismatch_total;
            init_clear_banks;            // phys[3] = 0 (= row -1 padding)

            dma_load_row(0);             // phys[0] = row 0
            dma_load_row(1);             // phys[1] = row 1
            dma_load_row(2);             // phys[2] = row 2

            // rb=0 에서 다양한 cb probe
            probe(0, 0,           0);   // 좌측 가장자리 (col=-1 padding)
            probe(0, 1,           0);   // 안쪽
            probe(0, OFM_WH-1,  0);   // 우측 가장자리 (col=W padding)

            $display("[Scenario A] mismatches = %0d", mismatch_total - s_mm_start);
        end
    endtask

    task automatic scenario_B;
        begin
            $display("============================================================");
            $display("[Scenario B] rb=2  rows {3, 4, 5, 6} → banks {3, 0, 1, 2}");
            $display("                    (모든 row 유효, padding 없음)");
            $display("============================================================");
            s_mm_start = mismatch_total;
            init_clear_banks;

            // rb=2 시 base_line = 3 (rb[0]=0 → 3)
            //   window[0]=phys[3]=row 3, window[1]=phys[0]=row 4,
            //   window[2]=phys[1]=row 5, window[3]=phys[2]=row 6
            dma_load_row(3);             // phys[3] (3%4=3)
            dma_load_row(4);             // phys[0]
            dma_load_row(5);             // phys[1]
            dma_load_row(6);             // phys[2]

            probe(2, 0,          1);
            probe(2, 1,          1);
            probe(2, OFM_WH-1, 1);

            $display("[Scenario B] mismatches = %0d", mismatch_total - s_mm_start);
        end
    endtask

    task automatic scenario_C;
        begin
            $display("============================================================");
            $display("[Scenario C] rb=3 (last)  rows {5, 6, 7, 8(=H, pad)}");
            $display("                          → banks {3, 0, 1, 2}");
            $display("                          base_line = i_rb[0] ? 1 : 3 → rb=3 → 1");
            $display("                          window[0]=phys[1] (row 5), ..., [3]=phys[0] (row 8 invalid → 0)");
            $display("============================================================");
            s_mm_start = mismatch_total;
            init_clear_banks;

            // rb=3 (odd) → base_line=1
            //   window[0]=phys[1]=row 5, window[1]=phys[2]=row 6,
            //   window[2]=phys[3]=row 7, window[3]=phys[0]=row 8 (invalid)
            dma_load_row(5);             // phys[1]
            dma_load_row(6);             // phys[2]
            dma_load_row(7);             // phys[3]
            // row 8 은 H_IFM 밖 — phys[0] 은 0 으로 남김 (init_clear)

            probe(3, 0,          2);
            probe(3, 1,          2);
            probe(3, OFM_WH-1, 2);

            $display("[Scenario C] mismatches = %0d", mismatch_total - s_mm_start);
        end
    endtask

    task automatic scenario_D;
        begin
            $display("============================================================");
            $display("[Scenario D] rb=1  rows {1, 2, 3, 4}");
            $display("                   base_line=1, window[0]=phys[1] (row 1) ...");
            $display("                   middle rb, no row pad");
            $display("============================================================");
            s_mm_start = mismatch_total;
            init_clear_banks;

            // rb=1 (odd) → base_line=1
            //   window[0]=phys[1]=row 1, window[1]=phys[2]=row 2,
            //   window[2]=phys[3]=row 3, window[3]=phys[0]=row 4
            dma_load_row(1);             // phys[1]
            dma_load_row(2);             // phys[2]
            dma_load_row(3);             // phys[3]
            dma_load_row(4);             // phys[0]

            probe(1, 0,          3);
            probe(1, 2,          3);
            probe(1, OFM_WH-1, 3);

            $display("[Scenario D] mismatches = %0d", mismatch_total - s_mm_start);
        end
    endtask

    //--------------------------------------------------------------
    // Main
    //--------------------------------------------------------------
    initial begin
        rstn            = 1'b0;
        dut_mode        = 1'b0;
        dut_w_blocks    = W_BLOCKS[11:0];
        dut_ci_groups   = CI_GRP[7:0];
        dut_w           = W_IFM[11:0];
        dut_h           = H_IFM[11:0];
        dut_line_valid  = 4'b1111;
        dut_dma_wr_en   = 1'b0;
        dut_dma_wr_line = 2'd0;
        dut_dma_wr_addr = 11'd0;
        dut_dma_wr_data = 128'd0;
        dut_rd_en       = 1'b0;
        dut_rb          = 12'd0;
        dut_cb          = 12'd0;
        dut_acc         = 8'd0;
        mismatch_total  = 0;

        #(8*CLK_PERIOD) rstn = 1'b1;
        #(4*CLK_PERIOD);

        scenario_A;
        scenario_B;
        scenario_C;
        scenario_D;

        $display("============================================================");
        if (mismatch_total == 0)
            $display("[ifm_line_buf_tb] *** ALL PASSED *** (A + B + C + D)");
        else
            $display("[ifm_line_buf_tb] *** FAILED *** total mismatches = %0d", mismatch_total);
        $display("============================================================");

        #(20*CLK_PERIOD) $finish;
    end

    initial begin
        #(10_000_000 * CLK_PERIOD);
        $display("[ifm_line_buf_tb] *** TIMEOUT ***");
        $finish;
    end

`endif

endmodule
