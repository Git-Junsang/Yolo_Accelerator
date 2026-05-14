`timescale 1ns/1ns
`include"user_define_h.v"

module dpram_wrapper (	
	clk,		// clock 
	ena,		// enable for write address
	addra,		// input address for write
	wea,		// input write enable
	enb,		// enable for read address
	addrb,		// input address for read
	dia,		// input write data
	dob			// output read-out data
);

// Declare parameters
// output parameters
parameter DW = 64;			// data bit-width per word
parameter AW = 8;			// address bit-width
parameter DEPTH = 256;		// depth, word length
parameter N_DELAY = 1;

// Declare Input & Output signals
// clock and reset
input							clk;
// input SRAM signals
input [AW-1			:	0]		addra;	// input address 
input							wea;	// input write enable
input							ena;	// input enable
input [DW-1			:	0]		dia;	// input write data
input [AW-1			:	0]		addrb;	// input address 
input							enb;	// input chip-select 
// output SRAM signal
output [DW-1		:	0]		dob;	// output read-out data

// Declare internal signals
reg	[DW-1			:	0]		rdata;

`ifdef FPGA
	//------------------------------------------------------------------------+
	// implement generate block ram
	//------------------------------------------------------------------------+
	generate
		if((DEPTH == 512) && (DW == 72)) begin: gen_dpram_512x72
			dpram_512x72 u_dpram_512x72 (
				// write ports
				.clka    (clk),
				.ena     (ena),
				.wea     (wea),
				.addra   (addra),
				.dina    (dia),
				// read ports 
				.clkb    (clk),
				.enb     (enb),
				.addrb   (addrb),
				.doutb   (dob)
			);
		end
		else if((DEPTH == 4096) && (DW == 32)) begin: gen_dpram_4096x32
			dpram_4096x32 u_dpram_4096x32 (
				// write ports
				.clka    (clk),
				.ena     (ena),
				.wea     (wea),
				.addra   (addra),
				.dina    (dia),
				// read ports 
				.clkb    (clk),
				.enb     (enb),
				.addrb   (addrb),
				.doutb   (dob)
			);
		end
        else if((DEPTH == 65536) && (DW == 32)) begin: gen_dpram_65536x32
            dpram_65536x32 u_dpram_65536x32 (
				// write ports
				.clka    (clk),
				.ena     (ena),
				.wea     (wea),
				.addra   (addra),
				.dina    (dia),
				// read ports
				.clkb    (clk),
				.enb     (enb),
				.addrb   (addrb),
				.doutb   (dob)
			);
		end
		// -------------------------------------------------------------
		// AIX2026 추가 케이스 (이전 Tier 1, deprecated 경로)
		//   - dpram_16384x128 : 구 IFM 핑퐁 버퍼
		// 강의자료 144-MAC 경로에서는 미사용. IP 는 유지 (호환성).
		// -------------------------------------------------------------
		else if((DEPTH == 16384) && (DW == 128)) begin: gen_dpram_16384x128
			dpram_16384x128 u_dpram_16384x128 (
				.clka    (clk),
				.ena     (ena),
				.wea     (wea),
				.addra   (addra),
				.dina    (dia),
				.clkb    (clk),
				.enb     (enb),
				.addrb   (addrb),
				.doutb   (dob)
			);
		end
		// -------------------------------------------------------------
		// 강의자료 경로 line buffer / OFM 버퍼 케이스
		//   - dpram_2048x128 : IFM line buffer (4-col × 4-ch packed = 16 byte/entry)
		//                      4 인스턴스 사용 (4-row sliding window).
		//   - dpram_8192x32  : OFM 버퍼 (4-pixel packed = 32 bit/entry)
		//                      전체 OFM 의 quarter (한 filter 의 모든 spatial) 보관.
		// -------------------------------------------------------------
		else if((DEPTH == 2048) && (DW == 128)) begin: gen_dpram_2048x128
			dpram_2048x128 u_dpram_2048x128 (
				.clka    (clk),
				.ena     (ena),
				.wea     (wea),
				.addra   (addra),
				.dina    (dia),
				.clkb    (clk),
				.enb     (enb),
				.addrb   (addrb),
				.doutb   (dob)
			);
		end
		else if((DEPTH == 8192) && (DW == 32)) begin: gen_dpram_8192x32
			dpram_8192x32 u_dpram_8192x32 (
				.clka    (clk),
				.ena     (ena),
				.wea     (wea),
				.addra   (addra),
				.dina    (dia),
				.clkb    (clk),
				.enb     (enb),
				.addrb   (addrb),
				.doutb   (dob)
			);
		end
	endgenerate
`else
	//------------------------------------------------------------------------+
	// Memory modeling
	//------------------------------------------------------------------------+
	reg [DW-1			:	0]		ram[0:DEPTH-1];	// Memory cell
	// Write
	always @(posedge clk) begin
		if(ena) begin
			if(wea)			ram[addra] <= dia;
		end
	end	
	// Read
	generate 
	   if(N_DELAY == 1) begin: delay_1
		  reg [DW-1:0] rdata   ; //Primary Data Output
		  //Read port
		  always @(posedge clk)
		  begin: read
			 if(enb)
				rdata <= ram[addrb];
		  end
		  assign dob = rdata;
	   end
	   else begin: delay_n
		  reg [N_DELAY*DW-1:0] rdata_r;
		  always @(posedge clk)
		  begin: read
			 if(enb)
				rdata_r[0+:DW] <= ram[addrb];
		  end

		  always @(posedge clk) begin: delay
			 integer i;
			 for(i = 0; i < N_DELAY-1; i = i+1)
				if(enb)
				   rdata_r[(i+1)*DW+:DW] <= rdata_r[i*DW+:DW];
		  end
		  assign dob = rdata_r[(N_DELAY-1)*DW+:DW];
	   end
	endgenerate
`endif

endmodule


