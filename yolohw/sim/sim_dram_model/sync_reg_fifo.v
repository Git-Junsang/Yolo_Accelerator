//----------------------------------------------------------------+
//----------------------------------------------------------------+
// Project: Deep Learning Hardware Design Contest
// Module: fifo.v
// Description:
//			AXI slave interface for DSP Mems
//			Current version: support write, read burst up to 16
//			No support: Multiple outstanding, write interleave
//
//----------------------------------------------------------------+

module sync_reg_fifo(   //input signals for write port
   clk,
   resetn,
   en_write,
   in_wdata,
   //input signals for read port
   en_read,
   //output signals of read port
   out_rdata,
   //flags
   empty,
   full,
   almost_empty,
   almost_full,
   fifo_ptr
);
   parameter N_SLOT = 4;
   parameter W_SLOT = 2; // $clog2(N_SLOT)
   parameter W_DATA = 32;
   
   //input signals for write port
   input clk;
   input resetn;
   input en_write;
   input [W_DATA-1:0] in_wdata;
   //input signals for read port
   input en_read;
   //output signals of read port
   output [W_DATA-1:0] out_rdata;
   //flags
   output empty;
   output reg full;
   output almost_empty;
   output almost_full;
    output [W_SLOT-1:0] fifo_ptr;
   
    reg [W_SLOT-1:0] wptr;

    assign fifo_ptr = wptr;
   //regs
   reg [W_DATA-1:0] q_sh_reg[N_SLOT-1:0];
      assign out_rdata = q_sh_reg[0];
   //pointer
   assign empty = !{full, wptr};
   assign almost_empty = !full && (wptr == 1);
   assign almost_full = (wptr == N_SLOT-1);
   //internal control signals
   reg int_en_write, int_en_read;

   always @*
   begin:combi
      //control signals
      int_en_write = en_write & ~full;
      int_en_read = en_read & ~empty;
   end
   //reg [W_SLOT-1:0] i; //Dont use register for for loop index
   integer i;
   always @(posedge clk or negedge resetn)
   begin
      if(~resetn)
      begin
         full <= 1'b0;
         wptr <= 0;

      for(i = 0; i < N_SLOT; i = i + 1)
        q_sh_reg[i] <= {W_DATA{1'b0}};
      end
      else
      begin
         if(int_en_write && int_en_read)
         begin
            for(i=0;i<N_SLOT-1;i=i+1)
               q_sh_reg[i] <= q_sh_reg[i+1];
            q_sh_reg[wptr-1] <= in_wdata;
         end
         else if(int_en_write)
         begin
            q_sh_reg[wptr] <= in_wdata;
            {full, wptr} <= {full, wptr} + 1;
         end
         else if(int_en_read)
         begin
            for(i=0;i<N_SLOT-1;i=i+1)
               q_sh_reg[i] <= q_sh_reg[i+1];
            {full, wptr} <= {full, wptr} - 1;
         end
      end
   end
endmodule
