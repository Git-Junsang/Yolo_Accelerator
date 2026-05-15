// -------------------------------------------------------------
// For debuging 
// -------------------------------------------------------------
// IMPORTANT NOTE**: 
//      1. Correct the directories with your path
//      2. Use directories without blank space
//{{{
// Input Files
parameter IFM_WIDTH         = 256;
parameter IFM_HEIGHT        = 256;
parameter IFM_CHANNEL       = 3;
parameter IFM_DATA_SIZE     = IFM_HEIGHT*IFM_WIDTH*2;    // Layer 00
parameter IFM_WORD_SIZE     = 32/2;
parameter IFM_DATA_SIZE_32  = IFM_HEIGHT*IFM_WIDTH;		 // Layer 00
parameter IFM_WORD_SIZE_32  = 32;
parameter Fx = 3, Fy = 3;
parameter Ni = 3, No = 16; 
parameter WGT_DATA_SIZE     = Fx*Fy*Ni*No;	             // Layer 00
parameter WGT_WORD_SIZE     = 32;


parameter IFM_FILE_32        = "../../../../../../sim/inout_data_sw/log_feamap/CONV00_input_32b.hex";
parameter IFM_FILE           = "../../../../../../sim/inout_data_sw/log_feamap/CONV00_input_16b.hex";
parameter WGT_FILE           = "../../../../../../sim/inout_data_sw/log_param/CONV00_param_weight.hex";

// Output Files
parameter CONV_INPUT_IMG00   = "../../../../../../sim/inout_data_hw/CONV00_input_ch00.bmp";
parameter CONV_INPUT_IMG01   = "../../../../../../sim/inout_data_hw/CONV00_input_ch01.bmp";
parameter CONV_INPUT_IMG02   = "../../../../../../sim/inout_data_hw/CONV00_input_ch02.bmp";
parameter CONV_INPUT_IMG03   = "../../../../../../sim/inout_data_hw/CONV00_input_ch03.bmp";

parameter CONV_OUTPUT_IMG00  = "../../../../../../sim/inout_data_hw/CONV00_output_ch00.bmp";
parameter CONV_OUTPUT_IMG01  = "../../../../../../sim/inout_data_hw/CONV00_output_ch01.bmp";
parameter CONV_OUTPUT_IMG02  = "../../../../../../sim/inout_data_hw/CONV00_output_ch02.bmp";
parameter CONV_OUTPUT_IMG03  = "../../../../../../sim/inout_data_hw/CONV00_output_ch03.bmp"; 

// SRAM Size
parameter DW            = 32;	  // data bit-width per word
parameter AW            = 16;	  // address bit-width
parameter DEPTH         = 65536;   // depth, word length
parameter N_DELAY       = 1;       // delay for spram read operation

parameter BUFF_WIDTH    = 32;
parameter BUFF_DEPTH    = 4096;
parameter BUFF_ADDR_W   = $clog2(BUFF_DEPTH);
//}}}