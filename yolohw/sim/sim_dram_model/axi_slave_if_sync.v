//----------------------------------------------------------------+
//----------------------------------------------------------------+
// Project: Deep Learning Hardware Design Contest
// Module: axi_slave_if_sync.v
// Description:
//			AXI slave interface for DSP Mems
//			Current version: support write, read burst up to 16
//			No support: Multiple outstanding, write interleave
//
//----------------------------------------------------------------+

module axi_slave_if_sync #(
      parameter   A   = 32,
      parameter   I   = 4,
      parameter   L   = 4,
      parameter   D   = 64,
      parameter   M   = D/8,
      parameter   W_AWFIFO = I+A+L+3+2,
      parameter   W_WDFIFO = I+D+1+M,
      parameter   W_BFIFO = I+2,
      parameter   W_ARFIFO = I+A+L+3+2,
      parameter   W_RDFIFO = I+D+1+2
) (
      //Global signals
      input ACLK,
      input ARESETn,

      //Write address channel
      input   [I-1:0]     AWID,       // Address ID
      input   [A-1:0]     AWADDR,     // Address Write
      input   [L-1:0]     AWLEN,      // Transfer length
      input   [2:0]       AWSIZE,     // Transfer width
      input   [1:0]       AWBURST,    // Burst type
      input   [1:0]       AWLOCK,     // Atomic access information
      input   [3:0]       AWCACHE,    // Cachable/bufferable infor
      input   [2:0]       AWPROT,     // Protection info
      input               AWVALID,    // address/control valid handshake
      output              AWREADY,
      //Write data channel
      input   [I-1:0]     WID,        // Write ID
      input   [D-1:0]     WDATA,      // Write Data bus
      input   [M-1:0]     WSTRB,      // Write Data byte lane strobes
      input               WLAST,      // Last beat of a burst transfer
      input               WVALID,     // Write data valid
      output              WREADY,     // Write data ready
      //Write response channel
      output  [I-1:0]     BID,        // buffered response ID
      output  [1:0]       BRESP,      // Buffered write response
      output              BVALID,     // Response info valid
      input               BREADY,     // Response info ready (from Master)
      //Read address channel
      input   [I-1:0]     ARID,       // Read addr ID
      input   [A-1:0]     ARADDR,     // Address Read 
      input   [L-1:0]     ARLEN,      // Transfer length
      input   [2:0]       ARSIZE,     // Transfer width
      input   [1:0]       ARBURST,    // Burst type
      input   [1:0]       ARLOCK,     // Atomic access information
      input   [3:0]       ARCACHE,    // Cachable/bufferable infor
      input   [2:0]       ARPROT,     // Protection info
      input               ARVALID,    // address/control valid handshake
      output              ARREADY,
      //Read data channel
      output  [I-1:0]     RID,        // Read ID
      output  [D-1:0]     RDATA,      // Read data bus
      output  [1:0]       RRESP,      // Read response
      output              RLAST,      // Last beat of a burst transfer
      output              RVALID,     // Read data valid 
      input               RREADY,     // Read data ready (from Master) 

      //Fifo interface with IMEM/DMEM
      //Write address fifo
      input                   awfifo_pop,
      output [W_AWFIFO-1:0]   awfifo_do,
      output                  awfifo_empty,
      //Write data fifo
      input                   wdfifo_pop,
      output [W_WDFIFO-1:0]   wdfifo_do,
      output                  wdfifo_empty,
      //Write response fifo
      input                   bfifo_push,
      input [W_BFIFO-1:0]     bfifo_di,
      output                  bfifo_full,
      //Read address fifo
      input                   arfifo_pop,
      output [W_ARFIFO-1:0]   arfifo_do,
      output                  arfifo_empty,
      //Read data
      input                   rdfifo_push,
      input [W_RDFIFO-1:0]    rdfifo_di,
      output                  rdfifo_full
   );

//Asynchronous FIFO based design

//-----------------------------------------------------------------------------------
//Write address logic 
wire awfifo_full;
assign AWREADY = !awfifo_full; 

wire [W_AWFIFO-1:0] awfifo_di;
   assign awfifo_di = {AWID, AWLEN, AWSIZE, AWBURST, AWADDR};

wire awfifo_push = (!awfifo_full) & AWVALID;

//Write address fifo
sync_reg_fifo
   #(.N_SLOT(16), .W_SLOT(4), .W_DATA(W_AWFIFO))
   aw_fifo (
      .clk(ACLK), .resetn(ARESETn), 
      .en_write(awfifo_push), .in_wdata(awfifo_di),
      .en_read(awfifo_pop), .out_rdata(awfifo_do), .empty(awfifo_empty), .full(awfifo_full),
      .almost_empty (),
      .almost_full (),
      .fifo_ptr()      
   );
//------------------------------------------------------------------------------------
//Write data channel
//wire [W_WDFIFO-1:0] wdfifo_di = {WID, WSTRB, WLAST, WDATA};
wire [W_WDFIFO-1:0] wdfifo_di = {AWID, WSTRB, WLAST, WDATA};
wire wdfifo_full;
assign WREADY = !wdfifo_full;
wire wdfifo_push =  (!wdfifo_full) & WVALID;

sync_reg_fifo
   #(.N_SLOT(256), .W_SLOT(8), .W_DATA(W_WDFIFO))
   wd_fifo (
      .clk(ACLK), .resetn(ARESETn), 
      .en_write(wdfifo_push), .in_wdata(wdfifo_di),
      .en_read(wdfifo_pop), .out_rdata(wdfifo_do), .empty(wdfifo_empty), .full(wdfifo_full),
      .almost_empty (),
      .almost_full (),
      .fifo_ptr()
   );
//-------------------------------------------------------------------------------------
//Write response channel
wire [I+2-1:0] bfifo_do;
wire bfifo_empty;
wire bfifo_pop = ~bfifo_empty && BREADY;

assign BVALID = ~bfifo_empty;
assign {BID, BRESP} = bfifo_do;

//remove FIFO sync_reg_fifo
//remove FIFO    #(.N_SLOT(2), .W_SLOT(1), .W_DATA(W_BFIFO))
//remove FIFO    b_fifo (
//remove FIFO       .clk(ACLK), .resetn(ARESETn),
//remove FIFO       .en_write(bfifo_push), .in_wdata(bfifo_di),
//remove FIFO       .en_read(bfifo_pop), .out_rdata(bfifo_do), .empty(bfifo_empty), .full(bfifo_full)
//remove FIFO    );

assign bfifo_do = bfifo_di;
assign bfifo_full = 1'b0;
assign bfifo_empty = !bfifo_push;

//Read address channel
//------------------------------------------------------------------------------

wire arfifo_full;
assign ARREADY = !arfifo_full; 

wire [W_ARFIFO-1:0] arfifo_di;
   assign arfifo_di = {ARID, ARLEN, ARSIZE, ARBURST, ARADDR};

wire arfifo_push = (!arfifo_full) & ARVALID;

//Read address FIFO
sync_reg_fifo
   #(.N_SLOT(16), .W_SLOT(4), .W_DATA(W_ARFIFO))
   ar_fifo (
      .clk(ACLK), .resetn(ARESETn),
      .en_write(arfifo_push), .in_wdata(arfifo_di),
      .en_read(arfifo_pop), .out_rdata(arfifo_do), .empty(arfifo_empty), .full(arfifo_full),
      .almost_empty (),
      .almost_full (),
      .fifo_ptr()      
   );
//------------------------------------------------------------------------------------
//READ data channel
//Logic in ACLK domain
wire [W_RDFIFO-1:0] rdfifo_do;
   assign {RID, RLAST, RRESP, RDATA} = rdfifo_do;
wire rdfifo_empty;
assign RVALID = !rdfifo_empty;
wire rdfifo_pop =  (!rdfifo_empty) & RREADY;

sync_reg_fifo
   #(.N_SLOT(256), .W_SLOT(8), .W_DATA(W_RDFIFO))
   rd_fifo (
      .clk(ACLK), .resetn(ARESETn),
      .en_write(rdfifo_push), .in_wdata(rdfifo_di),
      .en_read(rdfifo_pop), .out_rdata(rdfifo_do), .empty(rdfifo_empty), .full(rdfifo_full),
      .almost_empty (),
      .almost_full (),
      .fifo_ptr()      
   );
endmodule

