`timescale 1ns / 1ps

//================================================================
// 모듈명: post_process
// 
// 역할: Accumulator의 누적 결과에 바이어스를 더하고 스케일링을 거쳐 최종 8비트 픽셀로 변환하는 후처리 블록
// 
// 동작:
//   1. 조합 논리(Combinational Logic)를 통해 4단계의 후처리 연산을 한 사이클 내에 즉시 수행함.
//      - ① Bias 덧셈: 누적 결과(acc_result)에 바이어스(bias)를 더함.
//      - ② ReLU: 덧셈 결과가 음수이면 0으로 만들고, 양수이면 그대로 통과시킴.
//      - ③ Descaling: 지정된 시프트 양(shift_amount)만큼 산술 우측 시프트(>>>)하여 스케일을 줄임.
//      - ④ Clamp: 최종 값을 0에서 255 사이의 8비트 부호 없는 정수로 포화(Saturation) 연산함.
//   2. 누적 완료 신호(acc_done)가 1(HIGH)로 들어올 때, 
//      다음 클록 상승 에지에서 조합 논리의 최종 결과를 레지스터에 래치(Latch)하여 픽셀(pixel_out)로 출력함.
//   3. 이와 동시에 최종 유효 신호(output_valid)를 딱 1사이클 동안 1(HIGH)로 출력함.
// 
// 레이턴시: 1 클록
//================================================================

module post_process(
    input               clk,
    input               rstn,

    // Accumulator에서 오는 입력
    input               acc_done,
    input signed [31:0] acc_result,

    // 레이어별 파라미터
    input signed [31:0] bias,
    input [4:0]         shift_amount,

    // 최종 출력
    output reg [7:0]    pixel_out,
    output reg          output_valid
);

//----------------------------------------------------------------------
// 1. 조합 로직: 4단계를 wire로 연결하여 즉시 계산
//----------------------------------------------------------------------

// ① Bias 덧셈
wire signed [31:0] biased;
assign biased = acc_result + bias;

// ② ReLU (음수 -> 0)
wire signed [31:0] activated;
assign activated = (biased[31]) ? 32'd0 : biased;

// ③ Descaling (산술 우측 시프트)
wire signed [31:0] scaled;
assign scaled = activated >>> shift_amount;

// ④ Clamp (0~255 범위 제한)
wire [7:0] clamped;
assign clamped = (scaled[31])    ? 8'd0  : // 음수면 0
                 (|scaled[31:8]) ? 8'hFF : // 256 이상이면 255
                                   scaled[7:0];

//----------------------------------------------------------------------
// 2. 순차 로직: 다음 클록에 결과를 래치
//----------------------------------------------------------------------
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        pixel_out    <= 8'd0;
        output_valid <= 1'b0;
    end
    else begin
        output_valid <= acc_done;       // acc_done 다음 클록에 유효 신호 1 출력
        
        if (acc_done)
            pixel_out <= clamped;       // 조합 로직 연산이 끝난 최종 결과 래치
        else
            pixel_out <= 8'd0;
    end
end

endmodule