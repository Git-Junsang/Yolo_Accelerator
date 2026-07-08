//----------------------------------------------------------------+
//----------------------------------------------------------------+
// Project: Deep Learning Hardware Design Contest
// Module: sram.v
// Description:
//				Translate AXI commands to access native SRAMs
//				Bug!!! when there is rdfifo_full
//
//----------------------------------------------------------------+

module sram_ctrl #(
      parameter   A   = 32,
      parameter   I   = 4,
      parameter   L   = 4,
      parameter   D   = 512,
      parameter   M   = D/8,
      parameter   W_AWFIFO = I+A+L+3+2,
      parameter   W_WDFIFO = I+D+1+M,
      parameter   W_BFIFO = I+2,
      parameter   W_ARFIFO = I+A+L+3+2,
      parameter   W_RDFIFO = I+D+1+2,
      parameter W_MEM = 256, 
      parameter W_ADDR = 22
) (

   //dsp clk and resetn
   input clk,
   input rstn,

   //Fifo interface
   //Write address fifo
   output reg              awfifo_pop,
   input [W_AWFIFO-1:0]    awfifo_do,
   input                   awfifo_empty,
   //Write data fifo
   output                  wdfifo_pop,
   //output reg              wdfifo_pop,
   input [W_WDFIFO-1:0]    wdfifo_do,
   input                   wdfifo_empty,
   //Write response fifo
   output reg              bfifo_push,
   output [W_BFIFO-1:0]    bfifo_di,
   input                   bfifo_full,
   //Read address fifo
   output reg              arfifo_pop,
   input [W_ARFIFO-1:0]    arfifo_do,
   input                   arfifo_empty,
   //Read data
   output                  rdfifo_push,
   output [W_RDFIFO-1:0]   rdfifo_di,
   input                   rdfifo_full,

   //MEM native ports
   output [W_ADDR-1:0]     mem_addr,   // DSP's mems address
   output                  mem_we,    // Write enable to Imem
   output [W_MEM-1:0]      mem_di,    // Write data to Imem
   input  [W_MEM-1:0]      mem_do    // Read data from Imem
);
   
	function integer clog2(input integer num);
	begin
		if(num > 0)
		begin
			clog2 = 0;
			for(num = num - 1; num>0; clog2=clog2+1)
				num = num >> 1;
		end
		else
			clog2 = 1;
	end
	endfunction
   
   parameter NB_MEM = W_MEM/8;
   parameter WB_MEM = clog2(NB_MEM);

// Internal logics
// -----------------------------------------------------------------------------

// Logic for write
// -----------------------------------------------------------------------------
   wire [I-1:0] awid;
   wire [A-1:0] awaddr;
   wire [L-1:0] awlen;
   wire [2:0] awsize;
   wire [1:0] awburst;
      assign {awid, awlen, awsize, awburst, awaddr} = awfifo_do;
   
   wire [I-1:0] wid;
   wire [D-1:0] wdata;
   wire [M-1:0] wstrb;
   wire wlast;
      assign {wid, wstrb, wlast, wdata} = wdfifo_do;
   
   //Regs Fifo for write
   //---------------------------------------------------------------------------
   reg wrburst_start;
   reg [W_MEM:0] buf0, buf1;
   reg raddr;
   reg [1:0] cnt;
   reg rden;

   wire wrdy = (cnt == 0);
   wire rrdy = |cnt || (cnt == 0 && !wdfifo_empty);
   wire wren = !wdfifo_empty && wrdy && !wrburst_start;
   
   always @(posedge clk or negedge rstn)
   begin
      if(!rstn) begin
         raddr <= 1'b0;
         cnt <= 2'd0;

         buf0 <= 0;
         buf1 <= 0;
      end
      else begin

         raddr <= raddr ^ rden;
         cnt <= cnt + {wren, 1'b0} - rden;

         if(wren) begin
            buf0 <= {wlast, wdata[W_MEM-1:0]};
            buf1 <= {wlast, wdata[D-1:W_MEM]};
         end
      end
   end

   reg [W_MEM-1:0] f_rdata;
   always @* begin
      f_rdata = 0;
      case(raddr)
         1'b0: f_rdata = wdata[W_MEM-1:0];
         //1'b0: f_rdata = buf0[W_MEM-1:0];
         1'b1: f_rdata = buf1[W_MEM-1:0];
      endcase
   end  

   assign mem_di = f_rdata;
   assign mem_we = rden;

   //State machine
   localparam WR_IDLE = 0, WR_START = 1, WR_RESP = 2;
   reg [1:0] st_wr, nst_wr;

   always @(posedge clk or negedge rstn)
      if(!rstn)      st_wr <= WR_IDLE;
      else           st_wr <= nst_wr;

   reg [L:0] q_bcnt, d_bcnt;
   always @(posedge clk or negedge rstn)
      if(!rstn)      q_bcnt <= 0;
      else           q_bcnt <= d_bcnt;


   always @* begin
      nst_wr = st_wr;
      d_bcnt = q_bcnt;

      rden = 1'b0;
      awfifo_pop = 1'b0;
      bfifo_push = 1'b0;
      wrburst_start = 1'b0;

      case(st_wr)
         WR_IDLE: begin
            if(!awfifo_empty && !wdfifo_empty && (wid == awid))
            begin
               wrburst_start = 1'b1;
               nst_wr = WR_START;
            end
         end
         WR_START: begin
            if(rrdy) begin
               rden = 1'b1;
               d_bcnt = q_bcnt + 1;
               //if(wlast == 1'b1)    //wlast
               if(q_bcnt == {awlen, 1'b0}+1)    //wlast
                  nst_wr = WR_RESP;
            end
         end
         WR_RESP: begin
            d_bcnt = 0;

            if(!bfifo_full) begin
               awfifo_pop = 1'b1;   
               bfifo_push = 1'b1;
               nst_wr = WR_IDLE;
            end
         end
         default: nst_wr = WR_IDLE;
      endcase
   end

   assign wdfifo_pop = wren; 
   
   //Address generation to SRAM //increment mode
   reg [W_ADDR-1:0] addrw;
   always @(posedge clk or negedge rstn) begin
      if(!rstn)
         addrw <=  0;
      else if(wrburst_start)
         addrw <= awaddr[WB_MEM+:W_ADDR];
      else if(mem_we)
         addrw <= addrw + 1;
   end

   //Generate response signal
   wire wr_ok = buf1[W_MEM] && (q_bcnt == {awlen, 1'b0}+1) && rrdy;
   reg [1:0] bresp;
   always @(posedge clk or negedge rstn)
      if(!rstn)
         bresp <= 2'b00;
      else if(wr_ok)
         bresp <= 2'b00;   //OKAY
      else
         bresp <= 2'b10;   //SLVERR
   
   assign bfifo_di = {awid, bresp};

// Logics for Read from SRAM   
// -----------------------------------------------------------------------------
   wire [I-1:0] arid;
   wire [A-1:0] araddr;
   wire [L-1:0] arlen;
   wire [2:0] arsize;
   wire [1:0] arburst;
      assign {arid, arlen, arsize, arburst, araddr} = arfifo_do;

   //Reg Fifo for Read
   //---------------------------------------------------------------------------
   reg [W_MEM-1:0] rd_buf0, rd_buf1;
   reg rd_wren;

   reg rd_waddr;
   reg [1:0] rd_cnt;

   wire rd_wrdy = (rd_cnt < 2);
   wire rd_rrdy = (rd_cnt == 1) && !rdfifo_full ; 
   wire rd_rden = rd_rrdy;

   always @(posedge clk or negedge rstn)
   begin
      if(!rstn) begin
         rd_waddr <= 1'b0;
         rd_cnt <= 0;

         rd_buf0 <= 0;
         rd_buf1 <= 0;
      end
      else begin
         rd_waddr <= rd_waddr ^ rd_wren;
         rd_cnt <= rd_cnt + rd_wren - {rd_rden, 1'b0};

         if(rd_wren) begin
            case(rd_waddr)
               1'b0  :  rd_buf0 <= mem_do;
               1'b1  :  rd_buf1 <= mem_do;
            endcase
         end
      end
   end

   wire [D-1:0] rd_rdata = {mem_do, rd_buf0};
   //---------------------------------------------------------------------------
   //FSM for read SRAM
   localparam RD_IDLE = 0, RD_START = 1, RD_RESP = 2;
   reg [1:0] st_rd, nst_rd;

   always @(posedge clk or negedge rstn)
      if(!rstn)      st_rd <= RD_IDLE;
      else           st_rd <= nst_rd;

   reg [L:0] q_rdbcnt, d_rdbcnt; 
   always @(posedge clk or negedge rstn)
      if(!rstn)   q_rdbcnt <= 0;
      else        q_rdbcnt <= d_rdbcnt;

   //reg arfifo_pop;
   reg rdburst_start;
   reg sram_rden;

   always @* begin
      nst_rd = st_rd;
      d_rdbcnt = q_rdbcnt;

      sram_rden = 1'b0;
      arfifo_pop = 1'b0;
      rdburst_start = 1'b0;

      case(st_rd)
         RD_IDLE: begin
            if(!arfifo_empty)
            begin
               rdburst_start = 1'b1;
               nst_rd = RD_START; 
            end
         end
         RD_START: begin
            if(rd_wrdy) begin
               sram_rden = 1'b1;
               d_rdbcnt = q_rdbcnt + 1;
            end

            if(q_rdbcnt == {arlen, 1'b0}+1) 
               nst_rd = RD_RESP;
         end
         RD_RESP: begin
            d_rdbcnt = 0;
            arfifo_pop = 1'b1;   
            nst_rd = RD_IDLE;
         end
         default: nst_rd = RD_IDLE;
      endcase
   end

   //Address generation to SRAM //increment mode
   reg [W_ADDR-1:0] addrr;
   always @(posedge clk or negedge rstn) begin
      if(!rstn)
         addrr <=  0;
      else if(rdburst_start)
         addrr <= araddr[WB_MEM+:W_ADDR]; // [22+5:5]?
      else if(sram_rden == 1'b1)
         addrr <= addrr + 1;
   end

   always @(posedge clk or negedge rstn)
      if(!rstn)      rd_wren <= 1'b0;
      else           rd_wren <= sram_rden;

   reg [L:0] rd_bcnt_d;
   always @(posedge clk or negedge rstn)
      if(!rstn)      rd_bcnt_d <= 0;
      else if(rd_rden) begin
         if(rd_bcnt_d < arlen)
            rd_bcnt_d <= rd_bcnt_d + 1;
         else
            rd_bcnt_d <= 0;
      end

   wire rlast = (rd_bcnt_d == arlen) & rd_rden;

   assign rdfifo_di = {arid, rlast, 2'b00/*rresp*/, rd_rdata};
   assign rdfifo_push = rd_rden; 

   //Muxs
   assign mem_addr = mem_we ? addrw : addrr;

   
endmodule

