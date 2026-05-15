//`define PRELOAD
//`define DEBUG
`define NUM_BRAMS   16
`define BRAM_WIDTH  128
`define BRAM_DELAY  3



// -------------------------------------------------------------
// Working with FPGA
//	1. Uncomment this line
//  2. Generate IPs 
//		+ DSP for multipliers(check mul.v)
//		+ Single-port RAM (spram_wrapper.v)
//		+ Double-port RAM (dpram_wrapper.v)
// -------------------------------------------------------------

//`define FPGA	1

// -------------------------------------------------------------
// For debuging 
// -------------------------------------------------------------

// Uncomment to visualize the data from DMA write
//`define CHECK_DMA_WRITE 1

//}}}