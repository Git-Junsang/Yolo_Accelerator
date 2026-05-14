`timescale 1ns / 1ps
//----------------------------------------------------------------+
// max_pool_s1_unit.v — 2×2 stride-1 max pooling (same padding)
//
// 용도: Layer 11 전용 (8×8×512 → 8×8×512, stride 1).
//
// 동작:
//   stride-1 maxpool: output[r][c] = max(in[r][c], in[r][c+1],
//                                        in[r+1][c], in[r+1][c+1])
//   경계 (r+1 ≥ H, c+1 ≥ W) 는 0 padding (uint8, ReLU 이후라 OK).
//
// Packed format (입력/출력 동일):
//   32-bit word = 한 2×2 OFM block (filter f 의 좌표 (2R, 2C)..(2R+1, 2C+1))
//   byte 0 = (2R,   2C  )  pix_00
//   byte 1 = (2R,   2C+1)  pix_01
//   byte 2 = (2R+1, 2C  )  pix_10
//   byte 3 = (2R+1, 2C+1)  pix_11
//
//   ※ mac_kern 의 출력 packing 과 동일 → conv OFM 와 직접 호환.
//
// 출력 block (R, C) 계산 (4 sub-pixel):
//   필요한 입력 block:
//     blockRC   = (R,   C  )  ← 항상 valid
//     blockRC1  = (R,   C+1)  ← C+1 ≥ W_b 면 0
//     blockR1C  = (R+1, C  )  ← R+1 ≥ H_b 면 0
//     blockR1C1 = (R+1, C+1)  ← 둘 다 oob 면 0
//
//   out_pix_00 = max(blockRC.b0, blockRC.b1, blockRC.b2, blockRC.b3)
//   out_pix_01 = max(blockRC.b1, blockRC1.b0, blockRC.b3, blockRC1.b2)
//   out_pix_10 = max(blockRC.b2, blockRC.b3, blockR1C.b0, blockR1C.b1)
//   out_pix_11 = max(blockRC.b3, blockRC1.b2, blockR1C.b1, blockR1C1.b0)
//
// FSM: 한 output block 당 5 cycle (4 sequential read + 1 write).
//   cycle 0: issue read for blockRC
//   cycle 1: sample blockRC,   issue read for blockRC1
//   cycle 2: sample blockRC1,  issue read for blockR1C
//   cycle 3: sample blockR1C,  issue read for blockR1C1
//   cycle 4: sample blockR1C1, write output
//
// L11 비용: 512 × 4 × 4 × 5 = 40960 cycle ≈ 410 us @ 100 MHz.
//----------------------------------------------------------------+
module max_pool_s1_unit(
    input              clk,
    input              rstn,

    // 제어
    input              i_start,
    output             o_done,
    input  [11:0]      i_co_total,         // 512 (L11)
    input  [11:0]      i_h_blocks,         // H/2 = 4 (L11)
    input  [11:0]      i_w_blocks,         // W/2 = 4 (L11)
    input  [15:0]      i_in_base,          // input  base addr (32-bit word)
    input  [15:0]      i_out_base,         // output base addr (32-bit word)

    // OFM dpram read
    output             o_rd_en,
    output [15:0]      o_rd_addr,
    input  [31:0]      i_rd_data,

    // OFM dpram write
    output             o_wr_en,
    output [15:0]      o_wr_addr,
    output [31:0]      o_wr_data
);

    //----------------------------------------------------------------
    // FSM 상태
    //----------------------------------------------------------------
    localparam ST_IDLE = 2'd0,
               ST_RUN  = 2'd1,
               ST_DONE = 2'd2;
    reg [1:0]  state;

    reg [11:0] cnt_f, cnt_r, cnt_c;
    reg [2:0]  cnt_phase;          // 0..4 (5 cycle per output block)

    // 캐시된 4 input block
    reg [31:0] cache_rc;
    reg [31:0] cache_rc1;
    reg [31:0] cache_r1c;
    reg [31:0] cache_r1c1;

    // 경계 invalid 여부 (read 발사 시점에 결정 — sample 시점까지 유지)
    reg        valid_rc1;
    reg        valid_r1c;
    reg        valid_r1c1;

    //----------------------------------------------------------------
    // Read addr 발사 (조합) — 현재 phase 의 위치별 (f, r, c) 사용
    //   block addr = f × (H_b × W_b) + r × W_b + c
    //----------------------------------------------------------------
    wire [11:0] hwblk = i_h_blocks * i_w_blocks;       // 작은 곱 (4×4 = 16)
    wire [23:0] f_off = {12'd0, cnt_f} * {12'd0, hwblk};

    reg  [11:0] rd_r;
    reg  [11:0] rd_c;
    always @(*) begin
        rd_r = cnt_r;
        rd_c = cnt_c;
        case (cnt_phase)
            3'd0: begin rd_r = cnt_r;        rd_c = cnt_c;        end  // blockRC
            3'd1: begin rd_r = cnt_r;        rd_c = cnt_c + 12'd1;end  // blockRC1
            3'd2: begin rd_r = cnt_r + 12'd1;rd_c = cnt_c;        end  // blockR1C
            3'd3: begin rd_r = cnt_r + 12'd1;rd_c = cnt_c + 12'd1;end  // blockR1C1
            default: ;
        endcase
    end

    wire [23:0] blk_off = {12'd0, rd_r} * {12'd0, i_w_blocks} + {12'd0, rd_c};
    wire [23:0] addr_in = {8'd0, i_in_base} + f_off + blk_off;

    wire        in_rc1_oob  = (cnt_c + 12'd1 >= i_w_blocks);
    wire        in_r1c_oob  = (cnt_r + 12'd1 >= i_h_blocks);
    wire        in_r1c1_oob = in_rc1_oob | in_r1c_oob;

    //----------------------------------------------------------------
    // max-of-N combinational helpers
    //----------------------------------------------------------------
    function [7:0] max2;
        input [7:0] a, b;
        begin max2 = (a > b) ? a : b; end
    endfunction
    function [7:0] max4;
        input [7:0] a, b, c, d;
        reg [7:0] m1, m2;
        begin
            m1 = max2(a, b);
            m2 = max2(c, d);
            max4 = max2(m1, m2);
        end
    endfunction

    wire [7:0] rc_b0  = cache_rc  [ 7: 0];
    wire [7:0] rc_b1  = cache_rc  [15: 8];
    wire [7:0] rc_b2  = cache_rc  [23:16];
    wire [7:0] rc_b3  = cache_rc  [31:24];
    wire [7:0] rc1_b0 = cache_rc1 [ 7: 0];
    wire [7:0] rc1_b2 = cache_rc1 [23:16];
    wire [7:0] r1c_b0 = cache_r1c [ 7: 0];
    wire [7:0] r1c_b1 = cache_r1c [15: 8];
    wire [7:0] r1c1_b0= cache_r1c1[ 7: 0];

    wire [7:0] out_pix_00 = max4(rc_b0,  rc_b1,  rc_b2,  rc_b3);
    wire [7:0] out_pix_01 = max4(rc_b1,  rc1_b0, rc_b3,  rc1_b2);
    wire [7:0] out_pix_10 = max4(rc_b2,  rc_b3,  r1c_b0, r1c_b1);
    wire [7:0] out_pix_11 = max4(rc_b3,  rc1_b2, r1c_b1, r1c1_b0);

    wire [31:0] out_word = {out_pix_11, out_pix_10, out_pix_01, out_pix_00};
    wire [23:0] addr_out = {8'd0, i_out_base} + f_off + blk_off;

    //----------------------------------------------------------------
    // Output reg
    //----------------------------------------------------------------
    reg        rd_en_r;
    reg [15:0] rd_addr_r;
    reg        wr_en_r;
    reg [15:0] wr_addr_r;
    reg [31:0] wr_data_r;
    reg        done_r;

    assign o_rd_en   = rd_en_r;
    assign o_rd_addr = rd_addr_r;
    assign o_wr_en   = wr_en_r;
    assign o_wr_addr = wr_addr_r;
    assign o_wr_data = wr_data_r;
    assign o_done    = done_r;

    //----------------------------------------------------------------
    // FSM body
    //----------------------------------------------------------------
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state      <= ST_IDLE;
            cnt_f      <= 12'd0;
            cnt_r      <= 12'd0;
            cnt_c      <= 12'd0;
            cnt_phase  <= 3'd0;
            cache_rc   <= 32'd0;
            cache_rc1  <= 32'd0;
            cache_r1c  <= 32'd0;
            cache_r1c1 <= 32'd0;
            valid_rc1  <= 1'b0;
            valid_r1c  <= 1'b0;
            valid_r1c1 <= 1'b0;
            rd_en_r    <= 1'b0;
            rd_addr_r  <= 16'd0;
            wr_en_r    <= 1'b0;
            wr_addr_r  <= 16'd0;
            wr_data_r  <= 32'd0;
            done_r     <= 1'b0;
        end else begin
            wr_en_r <= 1'b0;
            done_r  <= 1'b0;

            case (state)
                ST_IDLE: begin
                    rd_en_r <= 1'b0;
                    if (i_start) begin
                        cnt_f     <= 12'd0;
                        cnt_r     <= 12'd0;
                        cnt_c     <= 12'd0;
                        cnt_phase <= 3'd0;
                        state     <= ST_RUN;
                    end
                end

                ST_RUN: begin
                    // ----- Read addr 발사 (phase 0..3) -----
                    if (cnt_phase < 3'd4) begin
                        rd_en_r   <= 1'b1;
                        rd_addr_r <= addr_in[15:0];
                        if (cnt_phase == 3'd1) valid_rc1  <= ~in_rc1_oob;
                        if (cnt_phase == 3'd2) valid_r1c  <= ~in_r1c_oob;
                        if (cnt_phase == 3'd3) valid_r1c1 <= ~in_r1c1_oob;
                    end else begin
                        rd_en_r <= 1'b0;
                    end

                    // ----- Sample data (1-cycle 후 BRAM 결과) -----
                    case (cnt_phase)
                        3'd1: cache_rc   <= i_rd_data;                                  // phase 0 read 결과
                        3'd2: cache_rc1  <= valid_rc1  ? i_rd_data : 32'd0;
                        3'd3: cache_r1c  <= valid_r1c  ? i_rd_data : 32'd0;
                        3'd4: cache_r1c1 <= valid_r1c1 ? i_rd_data : 32'd0;
                        default: ;
                    endcase

                    // ----- Phase 4: write output + advance counter -----
                    if (cnt_phase == 3'd4) begin
                        wr_en_r   <= 1'b1;
                        wr_addr_r <= addr_out[15:0];
                        wr_data_r <= out_word;

                        cnt_phase <= 3'd0;

                        if (cnt_c == i_w_blocks - 12'd1) begin
                            cnt_c <= 12'd0;
                            if (cnt_r == i_h_blocks - 12'd1) begin
                                cnt_r <= 12'd0;
                                if (cnt_f == i_co_total - 12'd1) begin
                                    state <= ST_DONE;
                                end else begin
                                    cnt_f <= cnt_f + 12'd1;
                                end
                            end else begin
                                cnt_r <= cnt_r + 12'd1;
                            end
                        end else begin
                            cnt_c <= cnt_c + 12'd1;
                        end
                    end else begin
                        cnt_phase <= cnt_phase + 3'd1;
                    end
                end

                ST_DONE: begin
                    done_r <= 1'b1;
                    state  <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
