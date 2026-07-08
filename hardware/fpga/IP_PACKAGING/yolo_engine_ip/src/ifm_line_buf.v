`timescale 1ns / 1ps
//----------------------------------------------------------------+
// ifm_line_buf.v — IFM 4-row line buffer + 4×4 window packing
//
// Phase 4 (현재): cyclic row rotation (i_rb 사용) + 1×1 mode packing
// Phase 3   : boundary padding (left/right col, top/bottom row)
// Phase 2   : column 정렬 어긋남 처리 + 3×3 mode 완전 packing
//
// 설계:
//   4 line buffer (True Dual Port BRAM, 2048 entry × 128-bit).
//   각 entry = 4 col × 4 ch (col-outer + ch-inner) = 16 byte.
//     byte index in entry: b = col*4 + ch  (col ∈ [0,4), ch ∈ [0,4))
//     LSB byte = col0_ch0, ..., MSB byte = col3_ch3
//
//   매 cycle read:
//     col_start = 2*Cb - 1            (signed)
//     base_entry = col_start >> 2
//     offset     = col_start[1:0]
//     Port A read addr = row_off + base_entry      → ent_a
//     Port B read addr = row_off + base_entry + 1  → ent_b
//
//   ★ cyclic row mapping (Phase 4 추가):
//     window row r ∈ {0,1,2,3} → IFM physical row (2*Rb - 1 + r)
//     physical line index    = IFM_row mod 4
//     base_line = (2*Rb - 1) mod 4
//     window[r] reads from physical line ((base_line + r) mod 4)
//
//   3×3 mode packing (mac_stack 의 i = c_local × 9 + (kh × 3 + kw)):
//     ifm_00 = window[line 0..2][col 0..2] × 4 ch
//     ifm_01 = window[line 0..2][col 1..3] × 4 ch
//     ifm_10 = window[line 1..3][col 0..2] × 4 ch
//     ifm_11 = window[line 1..3][col 1..3] × 4 ch
//
//   1×1 mode packing:
//     receptive field = 1 col × 1 row × Ci_group (4 ch / group)
//     한 cycle 에 9 개 ci_group (36 ch) 누적 → 4 pixel 모두 다른 위치.
//     ifm_00 = (R,   C  ) 의 36 ch (9 group × 4 ch)
//     ifm_01 = (R,   C+1) 의 36 ch
//     ifm_10 = (R+1, C  ) 의 36 ch
//     ifm_11 = (R+1, C+1) 의 36 ch
//     (단, ci_groups 는 9 의 배수 보장 필요 — software 패딩으로 처리)
//
//   line buffer 의 line index = IFM_row mod 4.
//   외부 (yolo_engine top) 가 row 진행 시 DMA write 로 갱신.
//   i_dma_wr_line 은 외부가 직접 계산 (IFM_row mod 4).
//----------------------------------------------------------------+
`include "user_define_h.v"

module ifm_line_buf(
    input              clk,
    input              rstn,
    input              i_mode,            // 0=3x3, 1=1x1

    // ===== Layer 파라미터 =====
    input  [11:0]      i_w_blocks,        // ceil(W/4) — col entry 수 per row
    input  [7:0]       i_ci_groups,       // ceil(Ci/4)
    input  [11:0]      i_w,               // 실제 IFM width (right padding 판정)
    input  [11:0]      i_h,               // 실제 IFM height (top/bottom row padding 판정)
    input  [3:0]       i_line_valid,      // [k]=1: window slot k 가 유효 IFM row.
                                          //   (3x3: 외부가 i_rb 보고 계산. 1x1: 사용 안 함)

    // ===== DMA write =====
    //   외부가 IFM_row → line index = IFM_row mod 4 매핑하여 전달
    input              i_dma_wr_en,
    input  [1:0]       i_dma_wr_line,     // 0..3 (physical line)
    input  [10:0]      i_dma_wr_addr,
    input  [127:0]     i_dma_wr_data,

    // ===== conv_top read =====
    input              i_rd_en,
    input  [11:0]      i_rb,              // OFM half-row index (=row_idx)
    input  [11:0]      i_cb,              // OFM half-col index (=col_idx)
    input  [7:0]       i_acc_cyc,
    input  [22:0]      i_row_off,         // = i_acc_cyc * i_w_blocks (conv_top 누산값, DSP 곱셈 대체)

    output reg [287:0] o_ifm_00,
    output reg [287:0] o_ifm_01,
    output reg [287:0] o_ifm_10,
    output reg [287:0] o_ifm_11,
    output reg         o_vld
);

    //----------------------------------------------------------------
    // Read addr 계산 (3×3 path)
    //   col_start = 2*Cb - 1 (signed)
    //----------------------------------------------------------------
    wire signed [13:0] col_start_s    = $signed({1'b0, i_cb, 1'b0}) - 14'sd1;
    wire signed [13:0] base_entry_s   = col_start_s >>> 2;
    wire        [1:0]  offset_3x3     = col_start_s[1:0];

    wire [22:0] row_off       = i_row_off;   // (구)i_acc_cyc*i_w_blocks → conv_top 누산값
    wire [10:0] base_entry_u  = base_entry_s[10:0];
    wire [10:0] rd_addr_a_3x3 = row_off[10:0] + base_entry_u;
    wire [10:0] rd_addr_b_3x3 = row_off[10:0] + base_entry_u + 11'd1;

    //----------------------------------------------------------------
    // 1×1 path
    //   각 cycle 에 1 col × 4 row × 9 ci_group (= 36 ch) 읽음.
    //   read addr = (acc_cyc * 9 + 0..8) * W_blocks + Cb_block
    //     where Cb_block = i_cb >> 2 (col 4-block index)
    //     col_in_block = i_cb[1:0]
    //   1×1 mode 에서는 ci_groups 가 매우 큼 (예: L12 Ci=512 → 128 groups).
    //   acc_cyc 한 step = 9 ci_groups 처리.
    //----------------------------------------------------------------
    //----------------------------------------------------------------
    // 1×1 mode 매핑 (2026-05-22 수정):
    //   i_cb = OFM block coord (W_HALF 까지 진행, 3×3 mode 와 동일 의미).
    //   한 호출 = OFM 2×2 block at (2*Rb..2*Rb+1, 2*Cb..2*Cb+1).
    //
    //   col_block_1x1 = i_cb >> 1   (entry index = OFM block / 2 = input col_block)
    //   col_inblk_1x1 = (i_cb[0]) ? 2 : 0  (0 또는 2 — entry 내 짝수 col)
    //   offset_1x1    = 0           (window col 0..3 = entry_a[0..3] 직접 매핑)
    //
    //   → ifm00 = window[1][col_inblk]     = input col (col_block*4 + col_inblk)
    //     ifm01 = window[1][col_inblk + 1] = input col + 1
    //     OFM cols = (2*Cb, 2*Cb+1) = (col_block*4 + col_inblk, +1)
    //----------------------------------------------------------------
    wire [11:0] col_block_1x1   = i_cb[11:1];           // i_cb >> 1
    wire [1:0]  col_inblk_1x1   = {i_cb[0], 1'b0};      // 0 or 2
    wire [1:0]  offset_1x1      = 2'd0;
    wire [11:0] cgrp_base_1x1   = {i_acc_cyc, 4'd0} - {4'd0, i_acc_cyc};  // acc_cyc * 15...
    // 위 식 부정확. 단순화: cgrp_base = acc_cyc * 9. 9 = 8 + 1.
    // 1×1 path 는 별도 read addr 9 개 필요 → 본 모듈에서는 base 만 계산하고
    // 9 개 group 을 순차 read 하지 않고 한 cycle 에 한 group 만 read.
    // 따라서 acc_cyc 의 정의를 9 group 단위로 두지 않고 1 group 단위로 둠:
    //   1×1 mode 의 i_acc_len = ci_groups (= ceil(Ci/4))
    //   mac_kern 에서는 36-byte ifm 중 4 byte 만 valid (한 group)
    //   ※ 본 설계는 단순화: 1×1 도 36-byte 단위로 묶음 = acc_len = ceil(Ci/36)
    //   software 가 ceil(Ci/36)*36 으로 padding 한다고 가정 (강의자료 가정).
    //----------------------------------------------------------------

    //----------------------------------------------------------------
    // 1×1 path 단순화 — 9 ci_group 묶음 단위 read
    //   매 acc_cyc step 에서 한 column 의 9 ci_group 을 9 개 entry 에서 read.
    //   ※ 본 구현은 single-port 모델로 9 cycle 분산할 수 없으므로,
    //     별도 reorder buffer 도입 없이 9 ci_group 을 연속 읽어 누적하는
    //     mac_kern.i_len 식 누적으로 처리. 한 acc_cyc 에 4-byte (= 1 group)
    //     공급 → 36-byte ifm 중 (acc_cyc mod 9) group 만 valid.
    //   현실적 단순화 → 1×1 layer 의 acc_len 을 ci_groups (Ci/4) 단위로 운용.
    //----------------------------------------------------------------
    wire [22:0] addr_1x1_a_long = i_row_off + {11'd0, col_block_1x1};
    wire [22:0] addr_1x1_b_long = i_row_off + {11'd0, col_block_1x1} + 23'd1;
    wire [10:0] rd_addr_a_1x1   = addr_1x1_a_long[10:0];
    wire [10:0] rd_addr_b_1x1   = addr_1x1_b_long[10:0];

    //----------------------------------------------------------------
    // Mode mux: read addr + offset
    //----------------------------------------------------------------
    wire [10:0] rd_addr_a = i_mode ? rd_addr_a_1x1 : rd_addr_a_3x3;
    wire [10:0] rd_addr_b = i_mode ? rd_addr_b_1x1 : rd_addr_b_3x3;
    wire [1:0]  offset    = i_mode ? offset_1x1    : offset_3x3;

    //----------------------------------------------------------------
    // 4 line buffer (True Dual Port BRAM, behavioral + FPGA IP)
    //   Port A: DMA write 또는 base entry read (시간 분리)
    //   Port B: base+1 entry read (always read)
    //----------------------------------------------------------------
    wire [127:0] phys_ent_a [0:3];
    wire [127:0] phys_ent_b [0:3];

    genvar gi;
    generate
        for (gi = 0; gi < 4; gi = gi + 1) begin: g_line
            wire        en_a_g   = (i_rd_en && !i_dma_wr_en) ||
                                   (i_dma_wr_en && (i_dma_wr_line == gi[1:0]));
            wire        we_a_g   =  i_dma_wr_en && (i_dma_wr_line == gi[1:0]);
            wire [10:0] addr_a_g =  i_dma_wr_en ? i_dma_wr_addr : rd_addr_a;
            wire        en_b_g   =  i_rd_en;

`ifdef FPGA
            // True Dual Port BMG IP (dpram_2048x128_tdp)
            dpram_2048x128_tdp u_line (
                .clka  (clk),
                .ena   (en_a_g),
                .wea   (we_a_g),
                .addra (addr_a_g),
                .dina  (i_dma_wr_data),
                .douta (phys_ent_a[gi]),
                .clkb  (clk),
                .enb   (en_b_g),
                .web   (1'b0),
                .addrb (rd_addr_b),
                .dinb  (128'd0),
                .doutb (phys_ent_b[gi])
            );
`else
            reg [127:0] mem    [0:2047];
            reg [127:0] dout_a_r;
            reg [127:0] dout_b_r;
            // sim 재현성: uninitialized line buffer(X) 로 인한 시뮬레이터 간 결과 차이 방지
            integer lb_init_idx;
            initial begin
                for (lb_init_idx = 0; lb_init_idx < 2048; lb_init_idx = lb_init_idx + 1)
                    mem[lb_init_idx] = 128'd0;
                dout_a_r = 128'd0;   // read 레지스터 X 제거
                dout_b_r = 128'd0;
            end
            always @(posedge clk) begin
                if (en_a_g) begin
                    if (we_a_g) mem[addr_a_g] <= i_dma_wr_data;
                    dout_a_r <= mem[addr_a_g];
                end
                if (en_b_g) dout_b_r <= mem[rd_addr_b];
            end
            assign phys_ent_a[gi] = dout_a_r;
            assign phys_ent_b[gi] = dout_b_r;
`endif
        end
    endgenerate

    //----------------------------------------------------------------
    // ★ Cyclic row mapping
    //   IFM physical row j = (2*i_rb - 1 + ln_y) for window ln_y ∈ {0..3}
    //   physical line index = j mod 4
    //   base_line = (2*i_rb - 1) mod 4 (computed combinationally)
    //   window[ln_y] read pulls from physical line ((base_line + ln_y) mod 4)
    //
    //   base_line 의 평가:
    //     2*i_rb - 1 의 하위 2 bit. i_rb[0]=0 → base=3, i_rb[0]=1 → base=1.
    //----------------------------------------------------------------
    wire [1:0] base_line = i_rb[0] ? 2'd1 : 2'd3;

    //----------------------------------------------------------------
    // 1-cycle pipeline registers (BRAM read latency 보상)
    //   BRAM 에 request 를 보낸 cycle 의 window 추출 파라미터를 1 cycle 저장.
    //   다음 cycle 에 BRAM 출력이 유효해질 때 동일 파라미터로 window 추출.
    //   conv_top 이 look-ahead i_cb 를 보내므로, 여기서 pipeline 하지 않으면
    //   BRAM data (request cycle 기준) 와 offset/boundary 판정 (현재 cycle 기준)
    //   이 1 cycle 어긋난다.
    //----------------------------------------------------------------
    reg [1:0] offset_r;
    reg [3:0] col_inv_r;
    reg [3:0] row_inv_r;
    reg [1:0] bline_r;
    reg [1:0] col_inblk_r;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            offset_r    <= 2'd0;
            col_inv_r   <= 4'hF;
            row_inv_r   <= 4'hF;
            bline_r     <= 2'd3;
            col_inblk_r <= 2'd0;
        end else if (i_rd_en) begin
            offset_r    <= offset;
            col_inv_r   <= col_invalid_3x3;
            row_inv_r   <= row_invalid;
            bline_r     <= base_line;
            col_inblk_r <= col_inblk_1x1;
        end
    end

    // window slot ln_y 의 physical line index (BRAM read 결과 mux)
    //   line_sel[ln_y] = (bline_r + ln_y) mod 4  — pipeline 된 base_line 사용
    wire [1:0] line_sel_0 = bline_r;
    wire [1:0] line_sel_1 = bline_r + 2'd1;
    wire [1:0] line_sel_2 = bline_r + 2'd2;
    wire [1:0] line_sel_3 = bline_r + 2'd3;

    wire [127:0] ent_a [0:3];
    wire [127:0] ent_b [0:3];

    assign ent_a[0] = phys_ent_a[line_sel_0];
    assign ent_a[1] = phys_ent_a[line_sel_1];
    assign ent_a[2] = phys_ent_a[line_sel_2];
    assign ent_a[3] = phys_ent_a[line_sel_3];
    assign ent_b[0] = phys_ent_b[line_sel_0];
    assign ent_b[1] = phys_ent_b[line_sel_1];
    assign ent_b[2] = phys_ent_b[line_sel_2];
    assign ent_b[3] = phys_ent_b[line_sel_3];

    //----------------------------------------------------------------
    // Offset mux — 4-col window 추출 (3×3 mode 와 1×1 mode 공통)
    //   1×1 mode 에서는 window[ln_y][col_inblk_1x1] 만 사용.
    //----------------------------------------------------------------
    function [31:0] get_col32;
        input [127:0] ent;
        input [1:0]   c;
        begin
            get_col32 = ent[ {c, 5'b00000} +: 32 ];  // c*32 +: 32
        end
    endfunction

    //----------------------------------------------------------------
    // Column boundary 판정 (3×3 path)
    //----------------------------------------------------------------
    wire signed [13:0] col_pos_0 = col_start_s;
    wire signed [13:0] col_pos_1 = col_start_s + 14'sd1;
    wire signed [13:0] col_pos_2 = col_start_s + 14'sd2;
    wire signed [13:0] col_pos_3 = col_start_s + 14'sd3;
    wire signed [13:0] w_s       = $signed({2'b00, i_w});

    wire [3:0] col_invalid_3x3 = {
        (col_pos_3 < 14'sd0) || (col_pos_3 >= w_s),
        (col_pos_2 < 14'sd0) || (col_pos_2 >= w_s),
        (col_pos_1 < 14'sd0) || (col_pos_1 >= w_s),
        (col_pos_0 < 14'sd0) || (col_pos_0 >= w_s)
    };

    //----------------------------------------------------------------
    // Row boundary 판정 — i_rb 기준 4 row position (2*Rb-1 .. 2*Rb+2)
    //   외부 i_line_valid 와 AND 결합 (외부가 더 보수적일 수 있음)
    //----------------------------------------------------------------
    wire signed [13:0] row_pos_0 = $signed({1'b0, i_rb, 1'b0}) - 14'sd1;
    wire signed [13:0] row_pos_1 = $signed({1'b0, i_rb, 1'b0});
    wire signed [13:0] row_pos_2 = $signed({1'b0, i_rb, 1'b0}) + 14'sd1;
    wire signed [13:0] row_pos_3 = $signed({1'b0, i_rb, 1'b0}) + 14'sd2;
    wire signed [13:0] h_s       = $signed({2'b00, i_h});

    wire [3:0] row_invalid = {
        (row_pos_3 < 14'sd0) || (row_pos_3 >= h_s),
        (row_pos_2 < 14'sd0) || (row_pos_2 >= h_s),
        (row_pos_1 < 14'sd0) || (row_pos_1 >= h_s),
        (row_pos_0 < 14'sd0) || (row_pos_0 >= h_s)
    };

    // 최종 line_valid = !row_invalid AND i_line_valid (i_line_valid 가 강한 override 면 사용)
    //   여기서는 단순화 — 내부 row_invalid 만 사용.
    /* verilator lint_off UNUSED */
    wire _unused_lv = |i_line_valid;
    /* verilator lint_on UNUSED */

    reg [31:0] window [0:3][0:3];
    integer    rr;

    always @(*) begin
        for (rr = 0; rr < 4; rr = rr + 1) begin
            // ----- Offset mux로 raw 4-col window 형성 (pipeline 된 offset_r 사용) -----
            case (offset_r)
                2'd0: begin
                    window[rr][0] = get_col32(ent_a[rr], 2'd0);
                    window[rr][1] = get_col32(ent_a[rr], 2'd1);
                    window[rr][2] = get_col32(ent_a[rr], 2'd2);
                    window[rr][3] = get_col32(ent_a[rr], 2'd3);
                end
                2'd1: begin
                    window[rr][0] = get_col32(ent_a[rr], 2'd1);
                    window[rr][1] = get_col32(ent_a[rr], 2'd2);
                    window[rr][2] = get_col32(ent_a[rr], 2'd3);
                    window[rr][3] = get_col32(ent_b[rr], 2'd0);
                end
                2'd2: begin
                    window[rr][0] = get_col32(ent_a[rr], 2'd2);
                    window[rr][1] = get_col32(ent_a[rr], 2'd3);
                    window[rr][2] = get_col32(ent_b[rr], 2'd0);
                    window[rr][3] = get_col32(ent_b[rr], 2'd1);
                end
                2'd3: begin
                    window[rr][0] = get_col32(ent_a[rr], 2'd3);
                    window[rr][1] = get_col32(ent_b[rr], 2'd0);
                    window[rr][2] = get_col32(ent_b[rr], 2'd1);
                    window[rr][3] = get_col32(ent_b[rr], 2'd2);
                end
            endcase

            // ----- Boundary padding (3×3 path 만, pipeline 된 row_inv_r/col_inv_r 사용) -----
            if (!i_mode) begin
                if (row_inv_r[rr]) begin
                    window[rr][0] = 32'd0;
                    window[rr][1] = 32'd0;
                    window[rr][2] = 32'd0;
                    window[rr][3] = 32'd0;
                end else begin
                    if (col_inv_r[0]) window[rr][0] = 32'd0;
                    if (col_inv_r[1]) window[rr][1] = 32'd0;
                    if (col_inv_r[2]) window[rr][2] = 32'd0;
                    if (col_inv_r[3]) window[rr][3] = 32'd0;
                end
            end
            // 1×1 mode: padding 없음 (kernel size 1, stride 1, no border)
        end
    end

    //----------------------------------------------------------------
    // mac_kern 3×3 packing
    //   i = c_local * 9 + (kh*3 + kw)
    //----------------------------------------------------------------
    function [7:0] win_byte;
        input integer ln;
        input integer cl;
        input integer ch;
        begin
            win_byte = window[ln][cl][ch*8 +: 8];
        end
    endfunction

    reg [287:0] ifm00_w, ifm01_w, ifm10_w, ifm11_w;
    integer cl_loc, kh, kw, idx;

    always @(*) begin
        ifm00_w = 288'd0;
        ifm01_w = 288'd0;
        ifm10_w = 288'd0;
        ifm11_w = 288'd0;
        if (!i_mode) begin
            // ===== 3×3 packing =====
            for (cl_loc = 0; cl_loc < 4; cl_loc = cl_loc + 1) begin
                for (kh = 0; kh < 3; kh = kh + 1) begin
                    for (kw = 0; kw < 3; kw = kw + 1) begin
                        idx = cl_loc * 9 + kh * 3 + kw;
                        ifm00_w[idx*8 +: 8] = win_byte(kh,     kw,     cl_loc);
                        ifm01_w[idx*8 +: 8] = win_byte(kh,     kw + 1, cl_loc);
                        ifm10_w[idx*8 +: 8] = win_byte(kh + 1, kw,     cl_loc);
                        ifm11_w[idx*8 +: 8] = win_byte(kh + 1, kw + 1, cl_loc);
                    end
                end
            end
        end else begin
            // ===== 1×1 packing (2026-05-23 수정) =====
            //   receptive field = 1 col × 1 row × 4 ch (single ci_group per cycle).
            //   mac_stack 의 mul[i] = wgt[i*8+:8] × ifm[i*8+:8] 매핑에 맞춰:
            //     weight 의 ch 0..3 은 byte 0, 9, 18, 27 위치 (slot 별 LSB)
            //     따라서 ifm 의 ch 0..3 도 동일 위치 (byte 0, 9, 18, 27) 에 배치
            //   pixel mapping:
            //     ifm_00 ← window[1][col_inblk_1x1]      (row 2*Rb,   col 2*Cb_block + col_inblk)
            //     ifm_01 ← window[1][col_inblk_1x1 + 1]  (col + 1)
            //     ifm_10 ← window[2][col_inblk_1x1]      (row 2*Rb+1, col 동일)
            //     ifm_11 ← window[2][col_inblk_1x1 + 1]
            ifm00_w[7:0]     = window[1][col_inblk_r][7:0];        // ch 0 @ byte 0
            ifm00_w[79:72]   = window[1][col_inblk_r][15:8];       // ch 1 @ byte 9
            ifm00_w[151:144] = window[1][col_inblk_r][23:16];      // ch 2 @ byte 18
            ifm00_w[223:216] = window[1][col_inblk_r][31:24];      // ch 3 @ byte 27

            ifm01_w[7:0]     = window[1][col_inblk_r + 2'd1][7:0];
            ifm01_w[79:72]   = window[1][col_inblk_r + 2'd1][15:8];
            ifm01_w[151:144] = window[1][col_inblk_r + 2'd1][23:16];
            ifm01_w[223:216] = window[1][col_inblk_r + 2'd1][31:24];

            ifm10_w[7:0]     = window[2][col_inblk_r][7:0];
            ifm10_w[79:72]   = window[2][col_inblk_r][15:8];
            ifm10_w[151:144] = window[2][col_inblk_r][23:16];
            ifm10_w[223:216] = window[2][col_inblk_r][31:24];

            ifm11_w[7:0]     = window[2][col_inblk_r + 2'd1][7:0];
            ifm11_w[79:72]   = window[2][col_inblk_r + 2'd1][15:8];
            ifm11_w[151:144] = window[2][col_inblk_r + 2'd1][23:16];
            ifm11_w[223:216] = window[2][col_inblk_r + 2'd1][31:24];
        end
    end

    //----------------------------------------------------------------
    // Output register (BRAM read 1 cycle + window mux 0 cycle + output reg 1 cycle
    //   = 2 cycle total latency from i_rd_en)
    //----------------------------------------------------------------
    reg rd_en_d;
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            rd_en_d  <= 1'b0;
            o_vld    <= 1'b0;
            o_ifm_00 <= 288'd0;
            o_ifm_01 <= 288'd0;
            o_ifm_10 <= 288'd0;
            o_ifm_11 <= 288'd0;
        end else begin
            rd_en_d  <= i_rd_en;
            o_vld    <= rd_en_d;
            o_ifm_00 <= ifm00_w;
            o_ifm_01 <= ifm01_w;
            o_ifm_10 <= ifm10_w;
            o_ifm_11 <= ifm11_w;
        end
    end

    //----------------------------------------------------------------
    // Unused (호환성)
    //----------------------------------------------------------------
    /* verilator lint_off UNUSED */
    wire _unused_cgr  = |i_ci_groups;
    /* verilator lint_on UNUSED */

endmodule
