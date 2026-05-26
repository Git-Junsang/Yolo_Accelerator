`timescale 1ns / 1ps
//----------------------------------------------------------------+
// upsample_unit.v — 2× nearest-neighbor upsample (Layer 18 전용)
//
// 동작:
//   입력: 8×8 (= 4×4 packed blocks per filter) × 128 channels
//   출력: 16×16 (= 8×8 packed blocks per filter) × 128 channels
//   each input pixel → 2×2 output pixels (값 복제)
//
// Packed format (입력/출력 동일):
//   32-bit word = 한 2×2 OFM block (filter f 좌표 (2R, 2C)..(2R+1, 2C+1))
//   byte 0 = (2R,   2C  )  pix_00
//   byte 1 = (2R,   2C+1)  pix_01
//   byte 2 = (2R+1, 2C  )  pix_10
//   byte 3 = (2R+1, 2C+1)  pix_11
//
// 각 input block (R, C) → 4 개의 output block:
//   input pixel (2R,   2C  ) = pix_00 → output 2×2 block (in_row=4R,   in_col=4C  )
//                                       output word = {pix_00, pix_00, pix_00, pix_00}
//                                       output addr = f×(2H_b×2W_b) + 2R×(2W_b) + 2C
//   input pixel (2R,   2C+1) = pix_01 → output 2×2 block (4R,   4C+2)
//                                       output addr = f×(2H_b×2W_b) + 2R×(2W_b) + 2C+1
//   input pixel (2R+1, 2C  ) = pix_10 → output 2×2 block (4R+2, 4C  )
//                                       output addr = f×(2H_b×2W_b) + (2R+1)×(2W_b) + 2C
//   input pixel (2R+1, 2C+1) = pix_11 → output 2×2 block (4R+2, 4C+2)
//                                       output addr = f×(2H_b×2W_b) + (2R+1)×(2W_b) + 2C+1
//
// FSM:
//   cycle 0:    issue read for input block (f, R, C)
//   cycle 1:    sample input → cache + write output_00 (top-left 4 pixel)
//   cycle 2:    write output_01 (top-right)
//   cycle 3:    write output_10 (bottom-left)
//   cycle 4:    write output_11 (bottom-right) + advance counter
//
// 비용: L18 = 128 × 4 × 4 × 5 = 10240 cycle ≈ 100 us @ 100 MHz.
//----------------------------------------------------------------+
module upsample_unit(
    input              clk,
    input              rstn,

    input              i_start,
    output             o_done,
    input  [11:0]      i_co_total,         // 128 (L18)
    input  [11:0]      i_h_blocks,         // input H/2 = 4 (L18)
    input  [11:0]      i_w_blocks,         // input W/2 = 4 (L18)
    input  [15:0]      i_in_base,
    input  [15:0]      i_out_base,

    output             o_rd_en,
    output [15:0]      o_rd_addr,
    input  [31:0]      i_rd_data,

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
    reg [2:0]  cnt_phase;          // 0..4
    reg [31:0] cache_in;

    //----------------------------------------------------------------
    // 주소 계산
    //----------------------------------------------------------------
    wire [11:0] in_blocks_per_filter  = i_h_blocks * i_w_blocks;        // 4×4 = 16
    wire [11:0] out_blocks_per_filter = {1'b0, i_h_blocks[10:0]} *
                                        {1'b0, i_w_blocks[10:0]} << 2;  // 4 × in (= 64 for L18)

    wire [23:0] f_in_off  = {12'd0, cnt_f} * {12'd0, in_blocks_per_filter};
    wire [23:0] f_out_off = {12'd0, cnt_f} * {12'd0, out_blocks_per_filter};

    wire [23:0] in_blk_off = {12'd0, cnt_r} * {12'd0, i_w_blocks} + {12'd0, cnt_c};
    wire [23:0] addr_in    = {8'd0, i_in_base} + f_in_off + in_blk_off;

    // Output base (filter f) 에 더할 block offset.
    // 출력 dimension = 2×H_b × 2×W_b. out_W_blocks = 2 × i_w_blocks.
    wire [12:0] out_w_blocks = {1'b0, i_w_blocks} << 1;
    wire [23:0] out_row_top_off   = {11'd0, cnt_r} * {11'd0, out_w_blocks} << 1;
    //   = 2R × (2 × W_b)
    wire [23:0] out_row_bot_off   = ({11'd0, cnt_r} * {11'd0, out_w_blocks} << 1)
                                  + {11'd0, out_w_blocks};
    //   = (2R+1) × (2 × W_b)

    wire [23:0] out_col_left_off  = {11'd0, cnt_c} << 1;        // 2C
    wire [23:0] out_col_right_off = ({11'd0, cnt_c} << 1) + 24'd1;  // 2C+1

    // 4 output addr (top-left, top-right, bottom-left, bottom-right of input pixel quad)
    wire [23:0] addr_out_00 = {8'd0, i_out_base} + f_out_off + out_row_top_off + out_col_left_off;
    wire [23:0] addr_out_01 = {8'd0, i_out_base} + f_out_off + out_row_top_off + out_col_right_off;
    wire [23:0] addr_out_10 = {8'd0, i_out_base} + f_out_off + out_row_bot_off + out_col_left_off;
    wire [23:0] addr_out_11 = {8'd0, i_out_base} + f_out_off + out_row_bot_off + out_col_right_off;

    //----------------------------------------------------------------
    // Output word = 입력 한 pixel 값을 4 번 복제
    //----------------------------------------------------------------
    wire [7:0] pix_00 = cache_in[ 7: 0];
    wire [7:0] pix_01 = cache_in[15: 8];
    wire [7:0] pix_10 = cache_in[23:16];
    wire [7:0] pix_11 = cache_in[31:24];

    wire [31:0] word_00 = {pix_00, pix_00, pix_00, pix_00};
    wire [31:0] word_01 = {pix_01, pix_01, pix_01, pix_01};
    wire [31:0] word_10 = {pix_10, pix_10, pix_10, pix_10};
    wire [31:0] word_11 = {pix_11, pix_11, pix_11, pix_11};

    //----------------------------------------------------------------
    // Output regs
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
            state     <= ST_IDLE;
            cnt_f     <= 12'd0;
            cnt_r     <= 12'd0;
            cnt_c     <= 12'd0;
            cnt_phase <= 3'd0;
            cache_in  <= 32'd0;
            rd_en_r   <= 1'b0;
            rd_addr_r <= 16'd0;
            wr_en_r   <= 1'b0;
            wr_addr_r <= 16'd0;
            wr_data_r <= 32'd0;
            done_r    <= 1'b0;
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
                    case (cnt_phase)
                        3'd0: begin
                            // Issue read
                            rd_en_r   <= 1'b1;
                            rd_addr_r <= addr_in[15:0];
                            cnt_phase <= 3'd1;
                        end
                        3'd1: begin
                            // Wait: dpram N_DELAY=1 → phase0 에 주소 세팅,
                            //        phase1 clock edge 에서 BRAM 이 rdata 를 업데이트,
                            //        phase2 에서 i_rd_data 가 유효
                            rd_en_r   <= 1'b0;
                            cnt_phase <= 3'd2;
                        end
                        3'd2: begin
                            // Sample (now valid) + write word_00
                            cache_in  <= i_rd_data;
                            wr_en_r   <= 1'b1;
                            wr_addr_r <= addr_out_00[15:0];
                            wr_data_r <= {i_rd_data[7:0], i_rd_data[7:0],
                                          i_rd_data[7:0], i_rd_data[7:0]};
                            cnt_phase <= 3'd3;
                        end
                        3'd3: begin
                            wr_en_r   <= 1'b1;
                            wr_addr_r <= addr_out_01[15:0];
                            wr_data_r <= word_01;
                            cnt_phase <= 3'd4;
                        end
                        3'd4: begin
                            wr_en_r   <= 1'b1;
                            wr_addr_r <= addr_out_10[15:0];
                            wr_data_r <= word_10;
                            cnt_phase <= 3'd5;
                        end
                        3'd5: begin
                            wr_en_r   <= 1'b1;
                            wr_addr_r <= addr_out_11[15:0];
                            wr_data_r <= word_11;
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
                        end
                        default: cnt_phase <= 3'd0;
                    endcase
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
