`timescale 1ns / 1ps
//----------------------------------------------------------------+
// mac_kern.v — Convolution kernel (mac_stack + accumulator + post)
//
// 강의 9차시 8-mac_kern 표제 모듈의 정통 경로 구현.
//
// 데이터패스 (한 사이클당 4 출력 픽셀, weight broadcast):
//   ifm_** (288 bit), wgt (288 bit) ──► mac_stack ──► acc_** (22-bit) ─┐
//                                                                       │
//      ┌────────────────────────────────────────────────────────────────┘
//      ▼
//   accumulator (i_len cycle 누적, 22→32-bit) ─► acc_done
//      ▼
//   post_process (bias 덧셈 + ReLU + arithmetic shift + uint8 clip)
//      ▼
//   pixel_out (4 × 8-bit), o_vld
//
// Mode select:
//   - 외부 컨트롤러가 CONV3x3 / CONV1x1 에 따라 wgt 와 ifm 의 패킹을
//     적절히 준비하여 넣어준다. 본 모듈은 mac_stack 으로 그대로 전달.
//   - i_mode 는 디버그/상위 분기용으로만 유지.
//
// 누적 길이 (i_len):
//   3×3 Conv: ceil(input_channel / 4) — 4 channel 씩 묶어 한 사이클 처리
//   1×1 Conv: ceil(input_channel / 36) 등 외부 컨트롤러가 결정
//
// 총 레이턴시 = 8 (mac_stack) + i_len (acc) + 1 (post) cycle.
//----------------------------------------------------------------+
module mac_kern(
    input                  clk,
    input                  rstn,

    // 컨트롤
    input                  i_vld,      // 입력 사이클 유효
    input                  i_mode,     // 0=CONV3x3, 1=CONV1x1 (디버그/상위 분기용)
    input  [7:0]           i_len,      // 누적 cycle 수

    // 데이터 입력
    input  [36*8-1:0]      i_wgt,      // 공유 가중치 288 bit
    input  [36*8-1:0]      i_ifm_00,
    input  [36*8-1:0]      i_ifm_01,
    input  [36*8-1:0]      i_ifm_10,
    input  [36*8-1:0]      i_ifm_11,

    // 후처리 파라미터 (4 출력 픽셀 공통 — 같은 필터 적용)
    input  signed [31:0]   i_bias,     // 16-bit bias × multiplier (sign-extend 결과)
    input  [4:0]           i_shift,    // descaling shift amount

    // 출력
    output [4*8-1:0]       o_pixel,    // 4 × 8-bit UINT8 (acc_00, 01, 10, 11)
    output                 o_vld
);

    // Tie unused mode bit to silence lint (실제 동작 분기는 외부에서 처리).
    /* verilator lint_off UNUSED */
    wire _unused_mode = i_mode;
    /* verilator lint_on UNUSED */

    //--------------------------------------------------------------
    // mac_stack instance — 4 partial sum (22-bit) 동시 생성
    //--------------------------------------------------------------
    wire signed [21:0] mac_00, mac_01, mac_10, mac_11;
    wire               mac_vld;

    mac_stack u_mac_stack (
        .clk    (clk),
        .rstn   (rstn),
        .vld_i  (i_vld),
        .wgt    (i_wgt),
        .ifm_00 (i_ifm_00),
        .ifm_01 (i_ifm_01),
        .ifm_10 (i_ifm_10),
        .ifm_11 (i_ifm_11),
        .acc_00 (mac_00),
        .acc_01 (mac_01),
        .acc_10 (mac_10),
        .acc_11 (mac_11),
        .vld_o  (mac_vld)
    );

    //--------------------------------------------------------------
    // Accumulator x 4 (22-bit MAC → 32-bit psum, i_len 회 누적)
    //   기존 accumulator.v 의 20-bit 입력과 폭이 달라 내부 구현.
    //--------------------------------------------------------------
    reg signed [31:0] psum_00, psum_01, psum_10, psum_11;
    reg        [7:0]  cyc_cnt;
    reg               acc_done;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            psum_00  <= 32'sd0;
            psum_01  <= 32'sd0;
            psum_10  <= 32'sd0;
            psum_11  <= 32'sd0;
            cyc_cnt  <= 8'd0;
            acc_done <= 1'b0;
        end else begin
            acc_done <= 1'b0;
            if (mac_vld) begin
                if (cyc_cnt == 8'd0) begin
                    psum_00 <= $signed(mac_00);
                    psum_01 <= $signed(mac_01);
                    psum_10 <= $signed(mac_10);
                    psum_11 <= $signed(mac_11);
                end else begin
                    psum_00 <= psum_00 + $signed(mac_00);
                    psum_01 <= psum_01 + $signed(mac_01);
                    psum_10 <= psum_10 + $signed(mac_10);
                    psum_11 <= psum_11 + $signed(mac_11);
                end

                if (cyc_cnt == i_len - 8'd1) begin
                    acc_done <= 1'b1;
                    cyc_cnt  <= 8'd0;
                end else begin
                    cyc_cnt  <= cyc_cnt + 8'd1;
                end
            end
        end
    end

    //--------------------------------------------------------------
    // Post-process x 4 (bias + ReLU + descale + UINT8 clip)
    //   기존 post_process.v 인스턴스 재사용 — 4 출력 모두 동일
    //   bias / shift 를 공유 (같은 필터 = 같은 출력 채널).
    //--------------------------------------------------------------
    wire [7:0] px_00, px_01, px_10, px_11;
    wire       vld_00, vld_01, vld_10, vld_11;

    post_process u_pp_00 (
        .clk(clk), .rstn(rstn),
        .acc_done(acc_done), .acc_result(psum_00),
        .bias(i_bias), .shift_amount(i_shift),
        .pixel_out(px_00), .output_valid(vld_00)
    );
    post_process u_pp_01 (
        .clk(clk), .rstn(rstn),
        .acc_done(acc_done), .acc_result(psum_01),
        .bias(i_bias), .shift_amount(i_shift),
        .pixel_out(px_01), .output_valid(vld_01)
    );
    post_process u_pp_10 (
        .clk(clk), .rstn(rstn),
        .acc_done(acc_done), .acc_result(psum_10),
        .bias(i_bias), .shift_amount(i_shift),
        .pixel_out(px_10), .output_valid(vld_10)
    );
    post_process u_pp_11 (
        .clk(clk), .rstn(rstn),
        .acc_done(acc_done), .acc_result(psum_11),
        .bias(i_bias), .shift_amount(i_shift),
        .pixel_out(px_11), .output_valid(vld_11)
    );

    // 4 후처리가 동일 레이턴시 → 한 vld 만 외부 노출.
    assign o_pixel = {px_11, px_10, px_01, px_00};
    assign o_vld   = vld_00;

endmodule
