`timescale 1ns / 1ps
//----------------------------------------------------------------+
// max_pool_unit.v — 2×2 stride-2 max pooling (BRAM-aware FSM)
//
// 동작:
//   입력  : OFM dpram 의 32-bit packed word (한 word = 한 2×2 conv block)
//           addr 순서 = filter-major + row-major
//             addr(f, R, C) = f × (W_h × H_h) + R × W_h + C
//   처리  : 한 입력 word (= 4 byte = 한 2×2 OFM block) 의 max → 1 output byte
//           → conv 2×2 block 자체가 pool stride-2 window 와 일치하므로 직접 매핑
//   출력  : 4 byte 누적 → 32-bit packed (2×2 pool OFM block) → OFM dpram 동일 영역 write
//             addr(f, r, c) = f × (W_pool/2 × H_pool/2) + r × (W_pool/2) + c
//
// In-place write 안전성:
//   output word index K ≤ floor((4K+3)/4) = K. 입력 4K+3 까지 읽은 후 K 에 write
//   → read addr (4K+3) > write addr (K) (for K > 0). K=0 도 read 4 cycle 후 write
//     so no overlap.
//
// Latency:
//   BRAM read = 1 cycle. addr 발사 → 1 cycle 후 데이터 도착.
//   total cycles ≈ N_in + 1 (last sample 위해 1 cycle drain)
//   write 는 4 byte 가 누적될 때마다 발생 (N_in / 4 회).
//
// Layer 11 (stride 1) 은 별도 모듈 필요 — 본 모듈은 stride 2 전용.
//----------------------------------------------------------------+
module max_pool_unit(
    input              clk,
    input              rstn,

    // 제어
    input              i_start,             // 1-cycle pulse
    output             o_done,              // 1-cycle pulse
    input  [19:0]      i_total_in_words,    // 입력 word 총 개수 (Co × H_h × W_h)

    // OFM dpram read port (port B)
    output             o_rd_en,
    output [15:0]      o_rd_addr,
    input  [31:0]      i_rd_data,

    // OFM dpram write port (port A)
    output             o_wr_en,
    output [15:0]      o_wr_addr,
    output [31:0]      o_wr_data
);

    //----------------------------------------------------------------
    // FSM
    //----------------------------------------------------------------
    localparam ST_IDLE = 2'd0,
               ST_RUN  = 2'd1,
               ST_DRAIN = 2'd2,
               ST_DONE  = 2'd3;
    reg [1:0] state;

    reg [19:0] in_addr_r;       // 다음에 발사할 read addr
    reg [15:0] out_addr_r;      // 다음에 write 할 out addr
    reg [1:0]  buf_cnt_r;       // 누적 byte 인덱스 0..3
    reg [7:0]  buf_b0, buf_b1, buf_b2;
    reg        issued_d;        // 1-cycle 지연 — read result 가 valid 한 cycle 표시
    reg [31:0] packed_word_r;
    reg        packed_vld_r;
    reg [15:0] packed_addr_r;
    reg        done_r;

    //----------------------------------------------------------------
    // max-of-4 combinational (i_rd_data 는 BRAM 의 등록된 출력 = 1-cycle 지연)
    //----------------------------------------------------------------
    wire [7:0] b0 = i_rd_data[ 7: 0];
    wire [7:0] b1 = i_rd_data[15: 8];
    wire [7:0] b2 = i_rd_data[23:16];
    wire [7:0] b3 = i_rd_data[31:24];
    wire [7:0] m01 = (b0 > b1) ? b0 : b1;
    wire [7:0] m23 = (b2 > b3) ? b2 : b3;
    wire [7:0] in_max = (m01 > m23) ? m01 : m23;

    //----------------------------------------------------------------
    // FSM body
    //----------------------------------------------------------------
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state         <= ST_IDLE;
            in_addr_r     <= 18'd0;
            out_addr_r    <= 16'd0;
            buf_cnt_r     <= 2'd0;
            buf_b0        <= 8'd0;
            buf_b1        <= 8'd0;
            buf_b2        <= 8'd0;
            issued_d      <= 1'b0;
            packed_word_r <= 32'd0;
            packed_vld_r  <= 1'b0;
            packed_addr_r <= 16'd0;
            done_r        <= 1'b0;
        end else begin
            packed_vld_r <= 1'b0;
            done_r       <= 1'b0;

            case (state)
                ST_IDLE: begin
                    issued_d <= 1'b0;
                    if (i_start) begin
                        state      <= ST_RUN;
                        in_addr_r  <= 20'd0;
                        out_addr_r <= 16'd0;
                        buf_cnt_r  <= 2'd0;
                    end
                end

                ST_RUN: begin
                    // ----- Issue 단계: in_addr_r 발사, 증가 -----
                    if (in_addr_r < i_total_in_words) begin
                        in_addr_r <= in_addr_r + 20'd1;
                        issued_d  <= 1'b1;
                    end else begin
                        issued_d <= 1'b0;
                        state    <= ST_DRAIN;
                    end

                    // ----- Sample 단계: 1-cycle 전 발사 결과 처리 -----
                    if (issued_d) begin
                        case (buf_cnt_r)
                            2'd0: buf_b0 <= in_max;
                            2'd1: buf_b1 <= in_max;
                            2'd2: buf_b2 <= in_max;
                            2'd3: begin
                                packed_word_r <= {in_max, buf_b2, buf_b1, buf_b0};
                                packed_vld_r  <= 1'b1;
                                packed_addr_r <= out_addr_r;
                                out_addr_r    <= out_addr_r + 16'd1;
                            end
                        endcase
                        buf_cnt_r <= buf_cnt_r + 2'd1;
                    end
                end

                ST_DRAIN: begin
                    // 마지막 발사된 read 결과 처리
                    if (issued_d) begin
                        case (buf_cnt_r)
                            2'd0: buf_b0 <= in_max;
                            2'd1: buf_b1 <= in_max;
                            2'd2: buf_b2 <= in_max;
                            2'd3: begin
                                packed_word_r <= {in_max, buf_b2, buf_b1, buf_b0};
                                packed_vld_r  <= 1'b1;
                                packed_addr_r <= out_addr_r;
                                out_addr_r    <= out_addr_r + 16'd1;
                            end
                        endcase
                        buf_cnt_r <= buf_cnt_r + 2'd1;
                        issued_d  <= 1'b0;
                    end else begin
                        state  <= ST_DONE;
                        done_r <= 1'b1;
                    end
                end

                ST_DONE: state <= ST_IDLE;

                default: state <= ST_IDLE;
            endcase
        end
    end

    //----------------------------------------------------------------
    // 외부 인터페이스
    //----------------------------------------------------------------
    assign o_rd_en   = (state == ST_RUN) && (in_addr_r < i_total_in_words);
    assign o_rd_addr = in_addr_r[15:0];      // 상위 2 bit 는 사용 안 함 (dpram AW=16)

    assign o_wr_en   = packed_vld_r;
    assign o_wr_addr = packed_addr_r;
    assign o_wr_data = packed_word_r;

    assign o_done    = done_r;

endmodule
