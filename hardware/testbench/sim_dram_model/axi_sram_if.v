//----------------------------------------------------------------+
//----------------------------------------------------------------+
// Project: Deep Learning Hardware Design Contest
// Module: axi_sram_if.v
// Description:
//		AXI slave interface for DSP Mems
//		Current version: support write, read burst up to 16
//		No support: Multiple outstanding, write interleave
//
//----------------------------------------------------------------+

module axi_sram_if #(
      parameter   A   = 32,
      parameter   I   = 4,
      parameter   L   = 8,
      parameter   D   = 512,
      parameter   M   = D/8,
      parameter   MEM_ADDRW = 22, //number of address bit in sram
      parameter   MEM_DW  = 256 //data width

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

      //MEM
      output [MEM_ADDRW-1:0] mem_addr,   // DSP's mems address
      output              mem_we,    // Write enable to Imem
      output [MEM_DW-1:0] mem_di,    // Write data to Imem
      input  [MEM_DW-1:0] mem_do    // Read data from Imem
   );

      parameter   W_AWFIFO = I+A+L+3+2;
      parameter   W_WDFIFO = I+D+1+M;
      parameter   W_BFIFO = I+2;
      parameter   W_ARFIFO = I+A+L+3+2;
      parameter   W_RDFIFO = I+D+1+2;

// Internal signal declarations
// -----------------------------------------------------------------------------
   //Fifo interface
   //Write address fifo
   wire                   awfifo_pop;
   wire [W_AWFIFO-1:0]    awfifo_do;
   wire                   awfifo_empty;
   //Write data fifo
   wire                   wdfifo_pop;
   wire [W_WDFIFO-1:0]    wdfifo_do;
   wire                   wdfifo_empty;
   //Write response fifo
   wire                   bfifo_push;
   wire [W_BFIFO-1:0]     bfifo_di;
   wire                   bfifo_full;
   //Read address fifo
   wire                   arfifo_pop;
   wire [W_ARFIFO-1:0]    arfifo_do;
   wire                   arfifo_empty;
   //Read data
   wire                   rdfifo_push;
   wire [W_RDFIFO-1:0]    rdfifo_di;
   wire                   rdfifo_full;

// AXI slave interface with async fifos
// -----------------------------------------------------------------------------
   //axi_slave_if_async #(
   axi_slave_if_sync #(
      .A(A), .I(I), .L(L), .D(D), .M(M))
   u_axi_slave_if (
      .ACLK(ACLK), .ARESETn(ARESETn),

      //AXI Slave IF
      //Write address channel
      .AWID    (AWID),       // Address ID
      .AWADDR  (AWADDR),     // Address Write
      .AWLEN   (AWLEN),      // Transfer length
      .AWSIZE  (AWSIZE),    // Transfer width
      .AWBURST (AWBURST),   // Burst type
      .AWLOCK  (AWLOCK),   // Atomic access information
      .AWCACHE (AWCACHE),   // Cachable/bufferable infor
      .AWPROT  (AWPROT),   // Protection info
      .AWVALID (AWVALID),   // address/control valid handshake
      .AWREADY (AWREADY),
      //Write data channel
      .WID     (WID),   // Write ID
      .WDATA   (WDATA),   // Write Data bus
      .WSTRB   (WSTRB),   // Write Data byte lane strobes
      .WLAST   (WLAST),   // Last beat of a burst transfer
      .WVALID  (WVALID),   // Write data valid
      .WREADY  (WREADY),    // Write data ready
      //write response channel
      .BID     (BID),   // buffered response ID
      .BRESP   (BRESP),   // Buffered write response
      .BVALID  (BVALID),   // Response info valid
      .BREADY  (BREADY),   // Response info ready (to slave)
      //Read address channel
      .ARID    (ARID),   // Read addr ID
      .ARADDR  (ARADDR),   // Address Read 
      .ARLEN   (ARLEN),   // Transfer length
      .ARSIZE  (ARSIZE),   // Transfer width
      .ARBURST (ARBURST),   // Burst type
      .ARLOCK  (ARLOCK),   // Atomic access information
      .ARCACHE (ARCACHE),   // Cachable/bufferable infor
      .ARPROT  (ARPROT),   // Protection info
      .ARVALID (ARVALID),   // address/control valid handshake
      .ARREADY (ARREADY),
      //Read data channel
      .RID     (RID),   // Read ID
      .RDATA   (RDATA),   // Read data bus
      .RRESP   (RRESP),   // Read response
      .RLAST   (RLAST),   // Last beat of a burst transfer
      .RVALID  (RVALID),   // Read data valid 
      .RREADY  (RREADY),   // Read data ready (to Slave)

      //Fifo interface
      .awfifo_pop     (awfifo_pop),
      .awfifo_do      (awfifo_do),
      .awfifo_empty   (awfifo_empty),

      .wdfifo_pop     (wdfifo_pop),
      .wdfifo_do      (wdfifo_do),
      .wdfifo_empty   (wdfifo_empty),

      .bfifo_push     (bfifo_push),
      .bfifo_di       (bfifo_di),
      .bfifo_full     (bfifo_full),

      .arfifo_pop     (arfifo_pop),
      .arfifo_do      (arfifo_do),
      .arfifo_empty   (arfifo_empty),

      .rdfifo_push    (rdfifo_push),
      .rdfifo_di      (rdfifo_di),
      .rdfifo_full    (rdfifo_full)
);

// Mem_ctrl for sram 
// -----------------------------------------------------------------------------
   sram_ctrl #(
      .W_MEM(MEM_DW), .W_ADDR(MEM_ADDRW),
      .A(A), .I(I), .L(L), .D(D), .M(M))
   u_sram_ctrl (
      .clk        (ACLK),
      .rstn       (ARESETn),

      //Fifo interface
      .awfifo_pop     (awfifo_pop),
      .awfifo_do      (awfifo_do),
      .awfifo_empty   (awfifo_empty),

      .wdfifo_pop     (wdfifo_pop),
      .wdfifo_do      (wdfifo_do),
      .wdfifo_empty   (wdfifo_empty),

      .bfifo_push     (bfifo_push),
      .bfifo_di       (bfifo_di),
      .bfifo_full     (bfifo_full),

      .arfifo_pop     (arfifo_pop),
      .arfifo_do      (arfifo_do),
      .arfifo_empty   (arfifo_empty),

      .rdfifo_push    (rdfifo_push),
      .rdfifo_di      (rdfifo_di),
      .rdfifo_full    (rdfifo_full),

      //Mem native ports
      .mem_addr      (mem_addr),
      .mem_we        (mem_we),
      .mem_di        (mem_di),
      .mem_do        (mem_do)
   );
endmodule

