`timescale 1ns / 1ps
//================================================================
// mul.v — 8-bit × 8-bit 부호 있는 곱셈기 (4-cycle pipeline)
//
// 역할:
//   - 가중치(w, INT8 signed) × 입력 특징맵(x, INT8 signed) 곱셈
//   - mac_stack 내부에서 36개 인스턴스로 병렬 사용됨 (총 36 × 4 = 144 MAC)
//
// 입출력 데이터 타입:
//   w  [7:0]  : 부호 있는 8비트 가중치  (-128 ~ +127, INT8 signed)
//   x  [7:0]  : 부호 있는 8비트 입력   (-128 ~ +127, INT8 signed)
//   y [15:0]  : 부호 있는 16비트 곱셈 결과
//               최댓값: (-128)×(-128) = 16384 → 15비트로 표현 가능
//               → 상위 1비트는 부호 확장으로 항상 부호 일치
//
// Latency:
//   - 4 clock cycle (FPGA DSP48 매크로 pipeline과 동일)
//   - mac_stack 의 vld_m1~vld_m4 파이프라인이 이 latency에 맞춰 valid 신호를 지연시킴
//
// FPGA/시뮬레이션 모드 전환:
//   - `define FPGA 시: Xilinx DSP48 매크로(xbip_dsp48_macro_0) 인스턴스화
//       → 실제 FPGA DSP slice 사용 (LUT 낭비 없음, 고속)
//       → 입력을 INT18로 부호 확장 후 DSP48 에 공급
//   - 시뮬레이션 시: 4-stage shift register로 behavioral 모델
//       → $signed() 연산자로 부호 있는 곱셈 수행
//================================================================
module mul(
input clk,
input [7:0] w,      // INT8 signed 가중치
input [7:0] x,      // INT8 signed 입력 픽셀
output[15:0] y      // 16비트 signed 곱셈 결과 (latency: 4 cycle)
);
`include "define.v"
`ifdef FPGA
    // ------------------------------------------------------------------
    // FPGA 합성 경로: DSP48 매크로 사용
    // ------------------------------------------------------------------
    wire [17:0] dsp_A, dsp_B;
    wire [47:0] dsp_P;

    // INT8 → INT18 부호 확장(sign extension):
    //   MSB(비트 7)가 1이면 음수 → 상위 10비트를 모두 1로 채움
    //   MSB(비트 7)가 0이면 양수 → 상위 10비트를 모두 0으로 채움
    assign dsp_A = w[7] ? {10'b11_1111_1111, w} : {10'b00_0000_0000, w};
    assign dsp_B = x[7] ? {10'b11_1111_1111, x} : {10'b00_0000_0000, x};

    // DSP48 출력 P[47:0] 중 하위 16비트만 사용 (최대값 16384 < 32768)
    assign y = dsp_P[15:0];

    // Vivado IP: xbip_dsp48_macro_0
    //   A×B 곱셈 전용 설정. C 입력은 0 고정 (누산 없음).
    //   Pipeline Stage 는 IP 생성 시 4로 설정.
    xbip_dsp48_macro_0 u_dsp(.CLK(clk), .A(dsp_A), .B(dsp_B), .C(48'b0), .P(dsp_P));
`else
    // ------------------------------------------------------------------
    // 시뮬레이션 경로: 4-stage 파이프라인 behavioral 모델
    //   - dsp_P[0]: 입력 w×x 를 $signed() 로 부호 있는 곱셈
    //   - dsp_P[1..3]: 파이프라인 지연 (DSP48 latency 4 cycle 모사)
    // ------------------------------------------------------------------
    reg [15:0] dsp_P[0:3];
    always@(posedge clk) begin
        dsp_P[0] <= $signed(w) * $signed(x);   // stage 1: 곱셈 수행
        dsp_P[1] <= dsp_P[0];                  // stage 2: 지연
        dsp_P[2] <= dsp_P[1];                  // stage 3: 지연
        dsp_P[3] <= dsp_P[2];                  // stage 4: 지연 (출력 유효)
    end
    assign y = dsp_P[3];
`endif
endmodule
