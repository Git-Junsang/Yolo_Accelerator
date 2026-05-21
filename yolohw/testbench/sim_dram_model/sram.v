//----------------------------------------------------------------+
//----------------------------------------------------------------+
// Project: Deep Learning Hardware Design Contest
// Module: sram.v
// Description:
//		Translate AXI commands to access native SRAMs
//
//----------------------------------------------------------------+

module sram (
    clk,
    rst,
    // combined port 0;
    addr,
    wdata,
    rdata,
    ena
);

  //----------------------------------------------------------------
  // I/O declarations:
  //----------------------------------------------------------------
  parameter FILE_NAME  = "undefined.mmap";
  parameter INST_NAME  = "SimmemSync_rp0_wp0_cp1";
  parameter SIZE       = 32'd256;
  parameter WL_ADDR    = 32'd8;
  parameter WL_DATA    = 32'd32;
  parameter RESET_POL  = 1'b0;        // 0: active low, 1: active high

  input                clk;   // main clock
  input                rst;   // reset, act.low by default

  input  [WL_ADDR-1:0] addr;  // read/write address port 0
  input  [WL_DATA-1:0] wdata; // write data port 0
  output [WL_DATA-1:0] rdata; // read data port 0
  input                ena;   // write enable port 0

  // controls for synthesis tools:
  // synthesis translate_off
  // cadence translate_off
  `ifdef SYNTHESIS
  `else

  //----------------------------------------------------------------
  // internal declarations:
  //----------------------------------------------------------------
  reg  [WL_DATA-1:0] mem[0:SIZE-1];   // This is the main memory
  wire               intrst;          // internal reset, depending on polarity

  wire [WL_DATA-1:0] tmp_rdata;
  reg  [WL_DATA-1:0] rdata;

//-----------------------------------------------------------------------------

  assign intrst = (RESET_POL == 1'b0) ? rst : ~rst;

  // load memory from file
  initial
  begin: PROC_SimmemLoad
    integer i;
      $display ("Initializing memory '%s'..", INST_NAME);
      for (i = 0; i< SIZE; i=i+1)
      begin
        mem[i] = 0;
      end
      $display ("Loading memory '%s' from file: %s", INST_NAME, FILE_NAME);
      $readmemh(FILE_NAME, mem);
  end


  // synchr. write of memory:
  always @(posedge clk)
  begin: PROC_SimmemWrite
    if (ena == 1'b1)
    begin
      mem[addr] <= wdata;
    end
  end

  // ouput assignments:
  assign  tmp_rdata = mem[addr];

  //for synchronous memory output
  always  @(posedge clk)
  begin
     rdata = tmp_rdata;
  end

  //asynchronous reset 
  always @(intrst)
  begin
   if (intrst == 1'b0)
    begin
     rdata = 0;
    end
  end

  `endif
  // controls for synthesis tools:
  // cadence translate_on
  // synthesis translate_on

endmodule 

