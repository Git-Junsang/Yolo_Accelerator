`timescale 1ns / 1ps
// w : INT8  (signed weight,  -128..127)
// x : UINT8 (unsigned IFM activation, 0..255)
// y = w × x  (16-bit signed, range -32640..32385)
//
// Pipeline latency: 4 cycles (matches mac_stack vld_m1..vld_m4 pipeline).
// add_tree_36in comment confirms max = 127×255 → x is UINT8.
module mul(
input clk,
input [7:0] w,
input [7:0] x,
output[15:0] y
);
`include "define.v"
`ifdef FPGA
	wire [17:0] dsp_A, dsp_B;
	wire [47:0] dsp_P;

	// w : sign-extend (INT8 → INT18)
	// x : zero-extend (UINT8 → non-negative INT18)
	assign dsp_A = w[7] ? {10'b11_1111_1111, w} : {10'b00_0000_0000, w};
	assign dsp_B = {10'b00_0000_0000, x};
	assign y = dsp_P[15:0];

	xbip_dsp48_macro_0 u_dsp(.CLK(clk), .A(dsp_A), .B(dsp_B), .C(48'b0), .P(dsp_P));
`else
	// Behavioral: 4-stage pipeline (INT8 signed × UINT8 unsigned)
	// $signed({1'b0,x}) zero-extends x to 9-bit non-negative signed → UINT8 semantics
	reg [15:0] dsp_P[0:3];
	always@(posedge clk) begin
		dsp_P[0] <= $signed(w) * $signed({1'b0, x});
		dsp_P[1] <= dsp_P[0];
		dsp_P[2] <= dsp_P[1];
		dsp_P[3] <= dsp_P[2];
	end
	assign y = dsp_P[3];
`endif
endmodule
