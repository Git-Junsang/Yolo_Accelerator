`timescale 1ns / 1ps

module conv_unit(
    input             clk,
    input             rstn,
    input             vld_i,
    input   [127:0]   win,
    input   [127:0]   din,
    input   [4:0]     num_cycles, 
    input   signed [31:0] bias,
    input   [4:0]     shift_amount,
    output  [7:0]     pixel_out,
    output            output_valid
);

    // 1. MAC과 Accumulator 사이를 연결할 내부 Wire
    wire [19:0] mac_out_w;
    wire        mac_vld_w;
    
    // 2. Accumulator와 Post Process 사이를 연결할 내부 Wire
    wire signed [31:0] acc_out_w;
    wire               acc_done_w;  // accumulator가 1을 뱉으면 이 선을 타고 흐릅니다.

    // MAC 인스턴스 (기존 코드)
    mac u_mac(
        .clk   (clk),
        .rstn  (rstn),
        .vld_i (vld_i),
        .win   (win),
        .din   (din),
        .acc_o (mac_out_w), 
        .vld_o (mac_vld_w)
    );

    // Accumulator 인스턴스 (작성하신 포트명 적용)
    accumulator u_accumulator(
        .clk        (clk),
        .rstn       (rstn),
        .vld_i      (mac_vld_w),
        .mac_result (mac_out_w),
        .num_cycles ({3'b000, num_cycles}), // 8비트 포트 크기에 맞게 0 패딩
        .acc_out    (acc_out_w),            // 누적 결과 출력
        .acc_done   (acc_done_w)            // 누적 완료 신호(1) 출력
    );

    // Post Process 인스턴스 (방금 직접 짜신 포트명 적용)
    post_process u_post_process(
        .clk          (clk),
        .rstn         (rstn),
        .acc_done     (acc_done_w),         // accumulator의 1을 여기서 입력으로 받음!
        .acc_result   (acc_out_w),          // 누적 결과 전달
        .bias         (bias),
        .shift_amount (shift_amount),
        .pixel_out    (pixel_out),          // 최종 픽셀 출력 (conv_unit 밖으로 나감)
        .output_valid (output_valid)        // 최종 유효 신호 출력 (conv_unit 밖으로 나감)
    );

endmodule