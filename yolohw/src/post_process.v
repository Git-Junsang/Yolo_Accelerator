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
    input               i_relu_en,    // 1=ReLU+UINT8 (L0~L13, L17), 0=INT8 raw (L14, L20)

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

// ② ReLU (relu_en=1 시 음수 → 0, relu_en=0 시 통과)
wire signed [31:0] activated;
assign activated = (i_relu_en && biased[31]) ? 32'd0 : biased;

// ③ Descaling (산술 우측 시프트, signed 보존)
//   C 의 `/` 는 toward-zero rounding, Verilog `>>>` 는 floor (toward -∞)
//   → 음수일 때 +1 LSB 차이 발생 (예: -50/64 = 0 in C vs -1 in Verilog).
//   해결: 음수면 (2^shift - 1) 더한 후 shift → toward-zero 동작.
//   (양수일 때 round_bias=0 이라 기존 동작 그대로 — L0~L13/L17 에 영향 없음)
wire signed [31:0] round_bias = activated[31] ?
    (($signed(32'sd1) <<< shift_amount) - 32'sd1) : 32'sd0;
wire signed [31:0] scaled = (activated + round_bias) >>> shift_amount;

// ④ Clamp
//   relu_en=1: 0~255 UINT8 (기존 동작)
//   relu_en=0: -128~+127 INT8 (2's complement, L14/L20 detection layer)
wire signed [31:0] s127  = 32'sd127;
wire signed [31:0] sn128 = -32'sd128;
wire [7:0] clamped =
    i_relu_en ?
        ( (scaled[31])    ? 8'd0  :
          (|scaled[31:8]) ? 8'hFF :
                            scaled[7:0] ) :
        // INT8 signed clamp
        ( (scaled > s127)  ? 8'h7F :
          (scaled < sn128) ? 8'h80 :
                             scaled[7:0] );

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