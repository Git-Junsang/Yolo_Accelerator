`timescale 1ns / 1ps

//------------------------------------------------------------+
//------------------------------------------------------------+
// Project: Deep Learning Hardware Design Contest
// Module: spram_tb
// Description:
//		Single-port RAM wrapper's testbench
//		The goal of testbench is to understand the read & write operation of initialized spram. 
//      
// History: 2022.02.13 by NXT (truongnx@capp.snu.ac.kr)
//------------------------------------------------------------+

module spram_tb();
    
    // system parameters
    parameter CLK_HALF_CYCLE = 5;  // clock half cycle
    parameter DW = 32;			    // data bit-width per word
    parameter AW = 13;			    // address bit-width
    parameter DEPTH = 6240;		// depth, word length
    parameter N_DELAY = 1;         // delay for spram read operation
    
    // generate clock
    always #CLK_HALF_CYCLE clk = ~clk;
    
    // regs & wires
    reg clk;                        // clock
    reg cs;                         // chip select
    reg we;                         // write enable
    reg [AW-1:0] addr;              // write address
    reg [DW-1:0] wdata;             // write data
    wire [DW-1:0] rdata;            // read out data
    reg [DW-1:0] test_data[15:0];   // test data
    
    integer i;
    
    initial begin
    
        //initial
        clk  = 0;
        
        // test data set; width =  DW , depth = 16
        test_data[0] = 32'h00000000;
        test_data[1] = 32'h11111111;
        test_data[2] = 32'h22222222;
        test_data[3] = 32'h33333333;
        test_data[4] = 32'h44444444;
        test_data[5] = 32'h55555555;
        test_data[6] = 32'h66666666;
        test_data[7] = 32'h77777777;
        test_data[8] = 32'h88888888;
        test_data[9] = 32'h99999999;
        test_data[10] = 32'haaaaaaaa;
        test_data[11] = 32'hbbbbbbbb;
        test_data[12] = 32'hcccccccc;
        test_data[13] = 32'hdddddddd;
        test_data[14] = 32'heeeeeeee;
        test_data[15] = 32'hffffffff;
        
        repeat(1)
            @(posedge clk);
        
        #(CLK_HALF_CYCLE) rstn = 0;
                
        // ---------- read operation ---------- //
        for(i=0;i<DEPTH;i=i+1) begin
            #(8*CLK_HALF_CYCLE) 
            cs = 1'b1;
            addr = i;
            #(4*CLK_HALF_CYCLE) 
            cs = 1'b0;
        end
       
        // ---------- write operation ---------- //
        for(i=0;i<16;i=i+1) begin
            #(8*CLK_HALF_CYCLE) 
            cs = 1'b1; 
            we = 1'b1;
            addr = i;
            wdata = test_data[i];
            #(2*CLK_HALF_CYCLE) 
            cs = 1'b0; 
            we = 1'b0;
        end
        
        
        // ---------- read operation ---------- //
        for(i=0;i<DEPTH;i=i+1) begin
            #(8*CLK_HALF_CYCLE) 
            cs = 1'b1;
            addr = i;
            #(4*CLK_HALF_CYCLE) 
            cs = 1'b0;
        end
        
        #(10*CLK_HALF_CYCLE);
        
        $finish;
    end
    
    // declare spram wrapper
    spram_wrapper #(.DW(DW), .AW(AW), .DEPTH(DEPTH), .N_DELAY(N_DELAY)) 
    spram_wrapper(
        .clk(clk),
        .addr(addr),
        .we(we),
        .cs(cs),
        .wdata(wdata),
        .rdata(rdata)    
    );    
   
endmodule
