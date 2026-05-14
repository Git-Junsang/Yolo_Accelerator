`timescale 1ns / 1ps

module cnn_ctrl_tb;
parameter W_SIZE  = 12;					// Max 4K QHD (3840x1920).
parameter W_FRAME_SIZE  = 2 * W_SIZE + 1;	// Max 4K QHD (3840x1920).
parameter W_DELAY = 12;
parameter WIDTH 	= 256;
parameter HEIGHT 	= 256;
parameter FRAME_SIZE = WIDTH * HEIGHT;
parameter VSYNC_DELAY = 100;
parameter HSYNC_DELAY = 100;
	
reg clk, rstn;
reg [W_SIZE-1 :0] q_width;
reg [W_SIZE-1 :0] q_height;
reg [W_DELAY-1:0] q_vsync_delay;
reg [W_DELAY-1:0] q_hsync_delay;
reg [W_FRAME_SIZE-1:0] q_frame_size;
reg q_start;

wire 			     ctrl_vsync_run;
wire [W_DELAY-1:0]	 ctrl_vsync_cnt;
wire 				 ctrl_hsync_run;
wire [W_DELAY-1:0]	 ctrl_hsync_cnt;
wire 				 ctrl_data_run;
wire [W_SIZE-1:0] 	 row;
wire [W_SIZE-1:0] 	 col;
wire [W_FRAME_SIZE-1:0]data_count;
wire end_frame;

//-------------------------------------------------
// Controller (FSM)
//-------------------------------------------------
cnn_ctrl u_cnn_ctrl (
.clk			(clk			),
.rstn			(rstn			),
// Inputs
.q_width		(q_width		),
.q_height		(q_height		),
.q_vsync_delay	(q_vsync_delay	),
.q_hsync_delay	(q_hsync_delay	),
.q_frame_size	(q_frame_size	),
.q_start		(q_start		),
//output
.o_ctrl_vsync_run(ctrl_vsync_run),
.o_ctrl_vsync_cnt(ctrl_vsync_cnt),
.o_ctrl_hsync_run(ctrl_hsync_run),
.o_ctrl_hsync_cnt(ctrl_hsync_cnt),
.o_ctrl_data_run(ctrl_data_run	),
.o_row			(row			),
.o_col			(col			),
.o_data_count	(data_count		),
.o_end_frame	(end_frame		)
);

// Clock
parameter CLK_PERIOD = 10;	//100MHz
initial begin
	clk = 1'b1;
	forever #(CLK_PERIOD/2) clk = ~clk;
end

//------------------------------------------------------------------------------------------------------
// Test cases
//------------------------------------------------------------------------------------------------------
initial begin
	rstn = 1'b0;			// Reset, low active	
	q_width 		= WIDTH;
	q_height 		= HEIGHT;
	q_vsync_delay 	= VSYNC_DELAY;
	q_hsync_delay 	= HSYNC_DELAY;		
	q_frame_size 	= FRAME_SIZE;
	q_start 		= 1'b0;	
	
	#(4*CLK_PERIOD) rstn = 1'b1;
	
	#(100*CLK_PERIOD) 
        @(posedge clk)
            q_start = 1'b1;
	#(4*CLK_PERIOD) 
        @(posedge clk)
            q_start = 1'b0;
                        			
end

endmodule
