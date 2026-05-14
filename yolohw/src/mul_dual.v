`timescale 1ns / 1ps
//----------------------------------------------------------------+
// mul_dual.v — Dual 8-bit multiplier (weight reuse)
//
// 강의 9차시 "Dual Multiplier" 인터페이스:
//   y1 = w × x1
//   y2 = w × x2
//
// 가중치(w) 를 두 곱셈에 공유한다.
// 합성기는 fan-out 된 동일 w 입력을 보고
//   (a) DSP48E 의 packed-multiplication (B 의 상하위에 x1/x2 패킹), 또는
//   (b) shared input register
// 형태로 최적화할 수 있다.
// 본 구현은 보수적으로 mul 인스턴스 2 개를 인스턴스화한다.
//   - 시뮬레이션 동작: $signed(w) × $signed(x) 2 회, 4-cycle pipeline
//   - 추후 packed-DSP 코드로 교체 시 DSP 사용량 절반 가능.
// Latency: y1/y2 모두 입력 후 4 cycle 뒤 valid (mul.v 와 동일).
//----------------------------------------------------------------+
module mul_dual(
    input         clk,
    input  [7:0]  w,    // 공유 가중치 (signed INT8)
    input  [7:0]  x1,   // 입력 1 (UINT8)
    input  [7:0]  x2,   // 입력 2 (UINT8)
    output [15:0] y1,   // w × x1
    output [15:0] y2    // w × x2
);

    mul u_mul_1 (.clk(clk), .w(w), .x(x1), .y(y1));
    mul u_mul_2 (.clk(clk), .w(w), .x(x2), .y(y2));

endmodule
