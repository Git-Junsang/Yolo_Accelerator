`timescale 1ns / 1ps

module mac_tb;
reg clk;
reg rstn;
reg vld_i;
reg [127:0] win, din;
wire[19:0] acc_o;
wire       vld_o;

//-------------------------------------------
// DUT: multiplier
//-------------------------------------------
mac u_mac(
./*input 		 */clk(clk), 
./*input 		 */rstn(rstn), 
./*input 		 */vld_i(vld_i), 
./*input [127:0] */win(win), 
./*input [127:0] */din(din),
./*output[ 19:0] */acc_o(acc_o), 
./*output        */vld_o(vld_o)
);

// Clock
parameter CLK_PERIOD = 10;	//100MHz
initial begin
	clk = 1'b1;
	forever #(CLK_PERIOD/2) clk = ~clk;
end
integer i;
// Test cases
initial begin
	rstn = 1'b0;			// Reset, low active	
	vld_i= 0;
	win = 0;
	din = 0;
	i = 0; 
	#(4*CLK_PERIOD) rstn = 1'b1;
	
	#(4*CLK_PERIOD) 
	for(i = 0; i<16; i=i+1) begin
        @(posedge clk) 			
            vld_i = 1'b1;
            win = {16{8'd4}};
            din[  7:  0] = i;
            din[ 15:  8] = i;
            din[ 23: 16] = i;
            din[ 31: 24] = i;
            din[ 39: 32] = i;
            din[ 47: 40] = i;
            din[ 55: 48] = i;
            din[ 63: 56] = i;
            din[ 71: 64] = i;
            din[ 79: 72] = i;
            din[ 87: 80] = i;
            din[ 95: 88] = i;
            din[103: 96] = i;
            din[111:104] = i;
            din[119:112] = i;
            din[127:120] = i;      
	end

	#(CLK_PERIOD) 
	@(posedge clk) 		
	   vld_i = 0;
	   win = 0;
	   din = 0;	   		   
end

endmodule

