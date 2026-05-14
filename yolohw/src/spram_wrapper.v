`timescale 1ns/1ps
`include"user_define_h.v"

module spram_wrapper (
	clk,					// clock 
	addr,					// input address 
	we,						// input write enable
	cs,						// input chip-select 
	wdata,					// input write data
	rdata					// output read-out data
);
// Declare parameters
parameter DW = 64;			// data bit-width per word
parameter AW = 8;			// address bit-width
parameter DEPTH = 256;		// depth, word length
parameter N_DELAY = 1;

// Declare Input & Output signals
// clock and reset
input							clk;
// input SRAM signals
input [AW-1			:	0]		addr;	// input address 
input							we;		// input write enable
input							cs;		// input chip-select 
input [DW-1			:	0]		wdata;	// input write data
// output SRAM signal
output [DW-1		:	0]		rdata;	// output read-out data

// Declare internal signals
reg	[DW-1			:	0]		rdata_o;


`ifdef FPGA
	//------------------------------------------------------------------------+
	// Implement generate block ram
	//------------------------------------------------------------------------+
	generate
		if((DEPTH == 512) && (DW == 72)) begin: gen_spram_512x72
			spram_512x72 u_spram_512x72( 
				// write
				.clka(clk),
				.ena(cs),
				.wea(we),
				.addra(addr),
				.dina(wdata),
				// read-out
				.douta(rdata)
			 );
		end
		else if((DEPTH == 4096) && (DW == 32)) begin: gen_spram_4096x32
			spram_4096x32 u_spram_4096x32( 
				// write
				.clka(clk),
				.ena(cs),
				.wea(we),
				.addra(addr),
				.dina(wdata),
				// read-out
				.douta(rdata)
			 );
		end		
		else if((DEPTH == 65536) && (DW == 32)) begin: gen_spram_65536x32
			spram_65536x32 u_spram_65536x32(
				// write
				.clka(clk),
				.ena(cs),
				.wea(we),
				.addra(addr),
				.dina(wdata),
				// read-out
				.douta(rdata)
			 );
		end
		// -------------------------------------------------------------
		// AIX2026 추가 케이스 (yolo_engine Tier 1 통합용)
		//   - spram_2048x128 : weight buffer (L0+L1+L2 가중치, 128-bit aligned)
		//   - spram_128x32   : bias buffer (INT16 sign-extended 32-bit)
		// FPGA 합성 전 Vivado IP Catalog → Block Memory Generator 로
		// 동일 이름의 IP 생성 필요 (Single-port RAM, Width/Depth = 위 조합)
		// -------------------------------------------------------------
		else if((DEPTH == 2048) && (DW == 128)) begin: gen_spram_2048x128
			spram_2048x128 u_spram_2048x128(
				.clka(clk),
				.ena(cs),
				.wea(we),
				.addra(addr),
				.dina(wdata),
				.douta(rdata)
			);
		end
		else if((DEPTH == 128) && (DW == 32)) begin: gen_spram_128x32
			spram_128x32 u_spram_128x32(
				.clka(clk),
				.ena(cs),
				.wea(we),
				.addra(addr),
				.dina(wdata),
				.douta(rdata)
			);
		end
	endgenerate

`else 
	//------------------------------------------------------------------------+
	// Memory modeling
	//------------------------------------------------------------------------+
	reg [DW-1			:	0]		mem[0:DEPTH-1];	// Memory cell
	// Write
	always @(posedge clk) begin
		if(cs && we)			mem[addr] <= wdata;
	end
	// Read
	generate
	   if(N_DELAY == 1) begin: gen_delay_1
		  always @(posedge clk)
			 if (cs && !(|we)) rdata_o <= mem[addr];

		  assign rdata = rdata_o;
	   end
	   else begin: gen_delay_n
		  reg [N_DELAY*DW-1:0] rdata_r;

		  always @(posedge clk)
			 if (cs && !(|we)) rdata_r[0*DW+:DW] <= mem[addr];

		  always @(posedge clk) begin: delay
			 integer i;
			 for(i = 0; i < N_DELAY-1; i = i+1)
				if(cs && !(|we))
				   rdata_r[(i+1)*DW+:DW] <= rdata_r[i*DW+:DW];
		  end
		  assign rdata = rdata_r[(N_DELAY-1)*DW+:DW];
	   end
	endgenerate

`endif


endmodule




