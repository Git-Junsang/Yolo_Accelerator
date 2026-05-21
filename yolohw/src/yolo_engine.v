`timescale 1ns / 1ps
//----------------------------------------------------------------+
// yolo_engine.v — Top module Phase 5 (22-layer 완성, MicroBlaze 제외)
//
// Phase 4 → Phase 5 변경:
//   + max_pool_s1_unit 인스턴스 — Layer 11 stride-1 maxpool
//   + upsample_unit 인스턴스 — Layer 18 2× nearest neighbor
//   + Route layer 처리 — L16/L19 는 compute/DMA 없이 skip (alias 처리)
//   + Per-layer DRAM offset 테이블 (lyr_ifm_offset_w, lyr_ofm_offset_w)
//   + DMA num_trans 폭 18 → 20 bit 확장 (L10 weight 등 큰 layer 대응)
//   + Top FSM 확장 — s1_pool/upsample/route 분기 추가
//   + OFM dpram port mux 확장 (conv/pool/s1_pool/upsample 동시 지원)
//
// Phase 5 기준 22-layer 분류:
//   conv 3×3   : 0, 2, 4, 6, 8, 10, 13
//   conv 1×1   : 12, 14, 17, 20
//   maxpool s2 : 1, 3, 5, 7, 9        → max_pool_unit
//   maxpool s1 : 11                   → max_pool_s1_unit
//   upsample   : 18                   → upsample_unit
//   route      : 16, 19               → no-op (software 가 DRAM 사전 배치)
//   yolo out   : 15, 21               → no-op
//
// AXI DRAM 메모리 맵 (software 약속):
//   ctrl_reg1 = dram_wgt_base  : weights + bias 영역 base
//   ctrl_reg2 = dram_ifm_base  : input image (L0 IFM)
//   ctrl_reg3 = dram_ofm_base  : 모든 layer OFM 영역 (per-layer offset 적용)
//
//   bias_offset (weight base 기준)         : +0x00A0_0000 (weight ~10 MB 이후 안전 위치)
//   software 가 weight/IFM 을 16-byte entry 단위로 padding 하여 적재.
//
// MicroBlaze 통합:
//   - 본 RTL 은 MicroBlaze 없이도 ap_start (ctrl_reg0[0]) 만 받으면
//     전체 22-layer 추론을 자동 진행. AXI master 가 DDR2 와 직결됨.
//   - MicroBlaze 는 ctrl_reg1/2/3 설정 + ap_start trigger + 결과 후처리만 담당.
//----------------------------------------------------------------+
`include "user_define_h.v"

module yolo_engine #(
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 4,
    parameter integer AXI_M_WIDTH_AD     = 32,
    parameter integer AXI_M_WIDTH_DA     = 32,
    parameter integer AXI_M_WIDTH_ID     = 4
)(
    input  wire                              clk,
    input  wire                              rstn,

    // ===== AXI4-Lite slave (control) =====
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]     S_AXI_AWADDR,
    input  wire [2:0]                        S_AXI_AWPROT,
    input  wire                              S_AXI_AWVALID,
    output wire                              S_AXI_AWREADY,
    input  wire [C_S_AXI_DATA_WIDTH-1:0]     S_AXI_WDATA,
    input  wire [(C_S_AXI_DATA_WIDTH/8)-1:0] S_AXI_WSTRB,
    input  wire                              S_AXI_WVALID,
    output wire                              S_AXI_WREADY,
    output wire [1:0]                        S_AXI_BRESP,
    output wire                              S_AXI_BVALID,
    input  wire                              S_AXI_BREADY,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]     S_AXI_ARADDR,
    input  wire [2:0]                        S_AXI_ARPROT,
    input  wire                              S_AXI_ARVALID,
    output wire                              S_AXI_ARREADY,
    output wire [C_S_AXI_DATA_WIDTH-1:0]     S_AXI_RDATA,
    output wire [1:0]                        S_AXI_RRESP,
    output wire                              S_AXI_RVALID,
    input  wire                              S_AXI_RREADY,

    // ===== AXI4 master (data path to DRAM) =====
    // Read address
    output wire                              M_ARVALID,
    input  wire                              M_ARREADY,
    output wire [AXI_M_WIDTH_AD-1:0]         M_ARADDR,
    output wire [AXI_M_WIDTH_ID-1:0]         M_ARID,
    output wire [7:0]                        M_ARLEN,
    output wire [2:0]                        M_ARSIZE,
    output wire [1:0]                        M_ARBURST,
    output wire [1:0]                        M_ARLOCK,
    output wire [3:0]                        M_ARCACHE,
    output wire [2:0]                        M_ARPROT,
    output wire [3:0]                        M_ARQOS,
    output wire [3:0]                        M_ARREGION,
    output wire [3:0]                        M_ARUSER,
    
    // Read data
    input  wire                              M_RVALID,
    output wire                              M_RREADY,
    input  wire [AXI_M_WIDTH_DA-1:0]         M_RDATA,
    input  wire                              M_RLAST,
    input  wire [AXI_M_WIDTH_ID-1:0]         M_RID,
    input  wire [3:0]                        M_RUSER,
    input  wire [1:0]                        M_RRESP,
    // Write address
    output wire                              M_AWVALID,
    input  wire                              M_AWREADY,
    output wire [AXI_M_WIDTH_AD-1:0]         M_AWADDR,
    output wire [AXI_M_WIDTH_ID-1:0]         M_AWID,
    output wire [7:0]                        M_AWLEN,
    output wire [2:0]                        M_AWSIZE,
    output wire [1:0]                        M_AWBURST,
    output wire [1:0]                        M_AWLOCK,
    output wire [3:0]                        M_AWCACHE,
    output wire [2:0]                        M_AWPROT,
    output wire [3:0]                        M_AWQOS,
    output wire [3:0]                        M_AWREGION,
    output wire [3:0]                        M_AWUSER,
    // Write data
    output wire                              M_WVALID,
    input  wire                              M_WREADY,
    output wire [AXI_M_WIDTH_DA-1:0]         M_WDATA,
    output wire [(AXI_M_WIDTH_DA/8)-1:0]     M_WSTRB,
    output wire                              M_WLAST,
    output wire [AXI_M_WIDTH_ID-1:0]         M_WID,
    output wire [3:0]                        M_WUSER,
    // Write response
    input  wire                              M_BVALID,
    output wire                              M_BREADY,
    input  wire [1:0]                        M_BRESP,
    input  wire [AXI_M_WIDTH_ID-1:0]         M_BID,
    input  wire                              M_BUSER,

    output wire                              o_network_done,
    output wire                              network_done_led
);

    //----------------------------------------------------------------
    // AXI Slave (control)
    //----------------------------------------------------------------
    wire [31:0] ctrl_reg0, ctrl_reg1, ctrl_reg2, ctrl_reg3;
    reg         network_done_r;

    assign o_network_done = network_done_r;

    yolo_engine_axi #(
        .C_S_AXI_DATA_WIDTH (C_S_AXI_DATA_WIDTH),
        .C_S_AXI_ADDR_WIDTH (C_S_AXI_ADDR_WIDTH)
    ) u_axi (
        .ctrl_reg0(ctrl_reg0), .ctrl_reg1(ctrl_reg1),
        .ctrl_reg2(ctrl_reg2), .ctrl_reg3(ctrl_reg3),
        .network_done(network_done_r),
        .network_done_led(network_done_led),
        .S_AXI_ACLK(clk), .S_AXI_ARESETN(rstn),
        .S_AXI_AWADDR(S_AXI_AWADDR), .S_AXI_AWPROT(S_AXI_AWPROT),
        .S_AXI_AWVALID(S_AXI_AWVALID), .S_AXI_AWREADY(S_AXI_AWREADY),
        .S_AXI_WDATA(S_AXI_WDATA), .S_AXI_WSTRB(S_AXI_WSTRB),
        .S_AXI_WVALID(S_AXI_WVALID), .S_AXI_WREADY(S_AXI_WREADY),
        .S_AXI_BRESP(S_AXI_BRESP), .S_AXI_BVALID(S_AXI_BVALID),
        .S_AXI_BREADY(S_AXI_BREADY),
        .S_AXI_ARADDR(S_AXI_ARADDR), .S_AXI_ARPROT(S_AXI_ARPROT),
        .S_AXI_ARVALID(S_AXI_ARVALID), .S_AXI_ARREADY(S_AXI_ARREADY),
        .S_AXI_RDATA(S_AXI_RDATA), .S_AXI_RRESP(S_AXI_RRESP),
        .S_AXI_RVALID(S_AXI_RVALID), .S_AXI_RREADY(S_AXI_RREADY)
    );

    wire        ap_start = ctrl_reg0[0];
    wire [31:0] dram_wgt_base  = ctrl_reg1;
    wire [31:0] dram_ifm_base  = ctrl_reg2;
    wire [31:0] dram_ofm_base  = ctrl_reg3;
    /* verilator lint_off UNUSED */
    wire _unused_ctrl = |ctrl_reg1 | |ctrl_reg2 | |ctrl_reg3;
    /* verilator lint_on UNUSED */

    //----------------------------------------------------------------
    // 22-layer parameter table (Phase 3 와 동일)
    //----------------------------------------------------------------
    reg  [4:0]  layer_idx;
    reg  [11:0] lyr_ofm_w,  lyr_ofm_h;
    reg  [11:0] lyr_ci,     lyr_co_total;
    reg  [7:0]  lyr_acc_len;
    reg  [4:0]  lyr_shift;
    reg         lyr_mode;
    reg         lyr_conv_en;
    reg         lyr_pool_en;
    reg         lyr_pool_stride;
    reg  [9:0]  lyr_wgt_base;
    reg  [11:0] lyr_bias_base;
    reg  [17:0] lyr_wgt_dram_blk;  // 누적 Co×acc_len (16-word 블록 단위)
    reg  [7:0]  lyr_ci_groups_r;

    always @(*) begin
        lyr_ofm_w       = 12'd0; lyr_ofm_h       = 12'd0;
        lyr_ci          = 12'd0; lyr_co_total    = 12'd0;
        lyr_acc_len     = 8'd0;  lyr_shift       = 5'd13;
        lyr_mode        = 1'b0;  lyr_conv_en     = 1'b0;
        lyr_pool_en     = 1'b0;  lyr_pool_stride = 1'b0;
        lyr_wgt_base    = 10'd0; lyr_bias_base   = 12'd0; lyr_wgt_dram_blk = 18'd0;
        lyr_ci_groups_r = 8'd1;
        // lyr_wgt_dram_blk: 이전 conv layer 들의 Co×acc_len 누적합 (16-word 블록 단위).
        //   addr_wgt_base(byte) = dram_wgt_base + lyr_wgt_dram_blk × 64
        case (layer_idx)
            5'd0:  begin lyr_ofm_w=12'd256; lyr_ofm_h=12'd256; lyr_ci=12'd3;   lyr_co_total=12'd16;  lyr_mode=1'b0; lyr_acc_len=8'd1;   lyr_shift=5'd8;  lyr_wgt_base=10'd0;   lyr_bias_base=12'd0;    lyr_wgt_dram_blk=18'd0;      lyr_conv_en=1'b1; lyr_ci_groups_r=8'd1;   end
            5'd1:  begin lyr_ofm_w=12'd128; lyr_ofm_h=12'd128; lyr_ci=12'd16;  lyr_co_total=12'd16;  lyr_pool_en=1'b1; lyr_pool_stride=1'b0; lyr_ci_groups_r=8'd4;   end
            5'd2:  begin lyr_ofm_w=12'd128; lyr_ofm_h=12'd128; lyr_ci=12'd16;  lyr_co_total=12'd32;  lyr_mode=1'b0; lyr_acc_len=8'd4;   lyr_shift=5'd6;  lyr_wgt_base=10'd16;  lyr_bias_base=12'd16;   lyr_wgt_dram_blk=18'd16;     lyr_conv_en=1'b1; lyr_ci_groups_r=8'd4;   end
            5'd3:  begin lyr_ofm_w=12'd64;  lyr_ofm_h=12'd64;  lyr_ci=12'd32;  lyr_co_total=12'd32;  lyr_pool_en=1'b1; lyr_pool_stride=1'b0; lyr_ci_groups_r=8'd8;   end
            5'd4:  begin lyr_ofm_w=12'd64;  lyr_ofm_h=12'd64;  lyr_ci=12'd32;  lyr_co_total=12'd64;  lyr_mode=1'b0; lyr_acc_len=8'd8;   lyr_shift=5'd6;  lyr_wgt_base=10'd144; lyr_bias_base=12'd48;   lyr_wgt_dram_blk=18'd144;    lyr_conv_en=1'b1; lyr_ci_groups_r=8'd8;   end
            5'd5:  begin lyr_ofm_w=12'd32;  lyr_ofm_h=12'd32;  lyr_ci=12'd64;  lyr_co_total=12'd64;  lyr_pool_en=1'b1; lyr_pool_stride=1'b0; lyr_ci_groups_r=8'd16;  end
            5'd6:  begin lyr_ofm_w=12'd32;  lyr_ofm_h=12'd32;  lyr_ci=12'd64;  lyr_co_total=12'd128; lyr_mode=1'b0; lyr_acc_len=8'd16;  lyr_shift=5'd6;  lyr_wgt_base=10'd0;   lyr_bias_base=12'd112;  lyr_wgt_dram_blk=18'd656;    lyr_conv_en=1'b1; lyr_ci_groups_r=8'd16;  end
            5'd7:  begin lyr_ofm_w=12'd16;  lyr_ofm_h=12'd16;  lyr_ci=12'd128; lyr_co_total=12'd128; lyr_pool_en=1'b1; lyr_pool_stride=1'b0; lyr_ci_groups_r=8'd32;  end
            5'd8:  begin lyr_ofm_w=12'd16;  lyr_ofm_h=12'd16;  lyr_ci=12'd128; lyr_co_total=12'd256; lyr_mode=1'b0; lyr_acc_len=8'd32;  lyr_shift=5'd6;  lyr_wgt_base=10'd0;   lyr_bias_base=12'd240;  lyr_wgt_dram_blk=18'd2704;   lyr_conv_en=1'b1; lyr_ci_groups_r=8'd32;  end
            5'd9:  begin lyr_ofm_w=12'd8;   lyr_ofm_h=12'd8;   lyr_ci=12'd256; lyr_co_total=12'd256; lyr_pool_en=1'b1; lyr_pool_stride=1'b0; lyr_ci_groups_r=8'd64;  end
            5'd10: begin lyr_ofm_w=12'd8;   lyr_ofm_h=12'd8;   lyr_ci=12'd256; lyr_co_total=12'd512; lyr_mode=1'b0; lyr_acc_len=8'd64;  lyr_shift=5'd6;  lyr_wgt_base=10'd0;   lyr_bias_base=12'd496;  lyr_wgt_dram_blk=18'd10896;  lyr_conv_en=1'b1; lyr_ci_groups_r=8'd64;  end
            5'd11: begin lyr_ofm_w=12'd8;   lyr_ofm_h=12'd8;   lyr_ci=12'd512; lyr_co_total=12'd512; lyr_pool_en=1'b1; lyr_pool_stride=1'b1; lyr_ci_groups_r=8'd128; end
            5'd12: begin lyr_ofm_w=12'd8;   lyr_ofm_h=12'd8;   lyr_ci=12'd512; lyr_co_total=12'd256; lyr_mode=1'b1; lyr_acc_len=8'd128; lyr_shift=5'd6;  lyr_wgt_base=10'd0;   lyr_bias_base=12'd1008; lyr_wgt_dram_blk=18'd43664;  lyr_conv_en=1'b1; lyr_ci_groups_r=8'd128; end
            5'd13: begin lyr_ofm_w=12'd8;   lyr_ofm_h=12'd8;   lyr_ci=12'd256; lyr_co_total=12'd512; lyr_mode=1'b0; lyr_acc_len=8'd64;  lyr_shift=5'd6;  lyr_wgt_base=10'd0;   lyr_bias_base=12'd1264; lyr_wgt_dram_blk=18'd76432;  lyr_conv_en=1'b1; lyr_ci_groups_r=8'd64;  end
            5'd14: begin lyr_ofm_w=12'd8;   lyr_ofm_h=12'd8;   lyr_ci=12'd512; lyr_co_total=12'd195; lyr_mode=1'b1; lyr_acc_len=8'd128; lyr_shift=5'd6;  lyr_wgt_base=10'd0;   lyr_bias_base=12'd1776; lyr_wgt_dram_blk=18'd109200; lyr_conv_en=1'b1; lyr_ci_groups_r=8'd128; end
            5'd15: begin                                                                                                                                                                                                end
            5'd16: begin                                                                                                                                                                                                end
            5'd17: begin lyr_ofm_w=12'd8;   lyr_ofm_h=12'd8;   lyr_ci=12'd256; lyr_co_total=12'd128; lyr_mode=1'b1; lyr_acc_len=8'd64;  lyr_shift=5'd6;  lyr_wgt_base=10'd0;   lyr_bias_base=12'd1971; lyr_wgt_dram_blk=18'd134160; lyr_conv_en=1'b1; lyr_ci_groups_r=8'd64;  end
            5'd18: begin lyr_ofm_w=12'd16;  lyr_ofm_h=12'd16;  lyr_ci=12'd128; lyr_co_total=12'd128;                                                                                                                    end
            5'd19: begin lyr_ofm_w=12'd16;  lyr_ofm_h=12'd16;  lyr_ci=12'd384; lyr_co_total=12'd384;                                                                                                                    end
            5'd20: begin lyr_ofm_w=12'd16;  lyr_ofm_h=12'd16;  lyr_ci=12'd384; lyr_co_total=12'd195; lyr_mode=1'b1; lyr_acc_len=8'd96;  lyr_shift=5'd6;  lyr_wgt_base=10'd0;   lyr_bias_base=12'd2099; lyr_wgt_dram_blk=18'd142352; lyr_conv_en=1'b1; lyr_ci_groups_r=8'd96;  end
            5'd21: begin                                                                                                                                                                                                end
            default: ;
        endcase
    end

    wire [11:0] lyr_ofm_w_half = {1'b0, lyr_ofm_w[11:1]};
    wire [11:0] lyr_ofm_h_half = {1'b0, lyr_ofm_h[11:1]};
    wire [11:0] lyr_w_blocks   = (lyr_ofm_w + 12'd3) >> 2;

    //----------------------------------------------------------------
    // Phase 5: 추가 layer operation flag + DRAM 주소 offset
    //
    //   lyr_s1_pool_en : L11 (stride-1 maxpool)
    //   lyr_upsample_en: L18 (2× nearest neighbor)
    //   lyr_route_en   : L16, L19 (no compute, software 가 concat 처리)
    //   lyr_use_input  : L0 만 dram_ifm_base 사용. 나머지는 dram_ofm_base+offset.
    //
    //   lyr_ifm_offset_w / lyr_ofm_offset_w (20-bit, 32-bit word 단위):
    //     각 layer 의 IFM/OFM DRAM word offset. Software DRAM layout 과 매칭.
    //----------------------------------------------------------------
    reg [19:0] lyr_ifm_offset_w;
    reg [19:0] lyr_ofm_offset_w;
    reg        lyr_use_input;
    reg        lyr_s1_pool_en;
    reg        lyr_upsample_en;
    reg        lyr_route_en;

    always @(*) begin
        lyr_ifm_offset_w = 20'd0;
        lyr_ofm_offset_w = 20'd0;
        lyr_use_input    = 1'b0;
        lyr_s1_pool_en   = 1'b0;
        lyr_upsample_en  = 1'b0;
        lyr_route_en     = 1'b0;
        case (layer_idx)
            5'd0:  begin lyr_use_input=1'b1;                                 lyr_ofm_offset_w=20'd0;       end
            5'd1:  begin                       lyr_ifm_offset_w=20'd0;       lyr_ofm_offset_w=20'd262144;  end
            5'd2:  begin                       lyr_ifm_offset_w=20'd262144;  lyr_ofm_offset_w=20'd327680;  end
            5'd3:  begin                       lyr_ifm_offset_w=20'd327680;  lyr_ofm_offset_w=20'd458752;  end
            5'd4:  begin                       lyr_ifm_offset_w=20'd458752;  lyr_ofm_offset_w=20'd491520;  end
            5'd5:  begin                       lyr_ifm_offset_w=20'd491520;  lyr_ofm_offset_w=20'd557056;  end
            5'd6:  begin                       lyr_ifm_offset_w=20'd557056;  lyr_ofm_offset_w=20'd573440;  end
            5'd7:  begin                       lyr_ifm_offset_w=20'd573440;  lyr_ofm_offset_w=20'd606208;  end
            5'd8:  begin                       lyr_ifm_offset_w=20'd606208;  lyr_ofm_offset_w=20'd614400;  end
            5'd9:  begin                       lyr_ifm_offset_w=20'd614400;  lyr_ofm_offset_w=20'd630784;  end
            5'd10: begin                       lyr_ifm_offset_w=20'd630784;  lyr_ofm_offset_w=20'd634880;  end
            5'd11: begin lyr_s1_pool_en=1'b1;  lyr_ifm_offset_w=20'd634880;  lyr_ofm_offset_w=20'd643072;  end
            5'd12: begin                       lyr_ifm_offset_w=20'd643072;  lyr_ofm_offset_w=20'd651264;  end
            5'd13: begin                       lyr_ifm_offset_w=20'd651264;  lyr_ofm_offset_w=20'd655360;  end
            5'd14: begin                       lyr_ifm_offset_w=20'd655360;  lyr_ofm_offset_w=20'd663552;  end
            5'd15: begin                       lyr_ifm_offset_w=20'd663552;  lyr_ofm_offset_w=20'd663552;  end  // YOLO out
            5'd16: begin lyr_route_en=1'b1;    lyr_ifm_offset_w=20'd651264;  lyr_ofm_offset_w=20'd651264;  end  // alias L12
            5'd17: begin                       lyr_ifm_offset_w=20'd651264;  lyr_ofm_offset_w=20'd666672;  end  // IFM from L12 (route)
            5'd18: begin lyr_upsample_en=1'b1; lyr_ifm_offset_w=20'd666672;  lyr_ofm_offset_w=20'd668720;  end
            5'd19: begin lyr_route_en=1'b1;    lyr_ifm_offset_w=20'd668720;  lyr_ofm_offset_w=20'd668720;  end  // L18 + L8 concat (sw)
            5'd20: begin                       lyr_ifm_offset_w=20'd668720;  lyr_ofm_offset_w=20'd693296;  end  // IFM = L19 concat
            5'd21: begin                       lyr_ifm_offset_w=20'd693296;  lyr_ofm_offset_w=20'd693296;  end  // YOLO out
            default: ;
        endcase
    end

    //----------------------------------------------------------------
    // Top FSM
    //----------------------------------------------------------------
    localparam ST_IDLE             = 4'd0,
               ST_INIT             = 4'd1,
               ST_DMA_WGT          = 4'd2,
               ST_DMA_WGT_WAIT     = 4'd3,
               ST_DMA_BIAS         = 4'd4,
               ST_DMA_BIAS_WAIT    = 4'd5,
               ST_DMA_IFM          = 4'd6,
               ST_DMA_IFM_WAIT     = 4'd7,
               ST_RUN_CONV         = 4'd8,
               ST_RUN_POOL         = 4'd9,
               ST_DMA_OFM          = 4'd10,
               ST_DMA_OFM_WAIT     = 4'd11,
               ST_NEXT             = 4'd12,
               ST_DONE             = 4'd13,
               ST_DMA_IFM_ROW_WAIT = 4'd14;  // rb_stream: 다음 rb IFM 로딩 대기
    // L19 Route concat (L8→L18+) 은 firmware (MicroBlaze memcpy) 가 담당 — RTL no-op
    reg [3:0] top_state;

    // DMA target (read demux)
    localparam DMA_TGT_IFM  = 2'd0,
               DMA_TGT_WGT  = 2'd1,
               DMA_TGT_BIAS = 2'd2;
    reg [1:0] dma_target_r;

    reg conv_start, pool_start;
    wire conv_done;
    wire pool_done;

    //----------------------------------------------------------------
    // AXI master DMA Read 인스턴스 (32-bit data)
    //----------------------------------------------------------------
    reg          dma_rd_start;
    reg  [19:0]  dma_rd_num_trans;
    reg  [31:0]  dma_rd_start_addr;
    wire [31:0]  dma_rd_data;
    wire         dma_rd_data_vld;
    wire [19:0]  dma_rd_data_cnt;
    wire         dma_rd_done;

    axi_dma_rd #(
        .BITS_TRANS     (20),
        .AXI_WIDTH_ID   (AXI_M_WIDTH_ID),
        .AXI_WIDTH_AD   (AXI_M_WIDTH_AD),
        .AXI_WIDTH_DA   (AXI_M_WIDTH_DA)
    ) u_dma_rd (
        .M_ARVALID(M_ARVALID), .M_ARREADY(M_ARREADY), .M_ARADDR(M_ARADDR),
        .M_ARID(M_ARID), .M_ARLEN(M_ARLEN), .M_ARSIZE(M_ARSIZE),
        .M_ARBURST(M_ARBURST), .M_ARLOCK(M_ARLOCK), .M_ARCACHE(M_ARCACHE),
        .M_ARPROT(M_ARPROT), .M_ARQOS(M_ARQOS), .M_ARREGION(M_ARREGION), .M_ARUSER(M_ARUSER),
        .M_RVALID(M_RVALID), .M_RREADY(M_RREADY), .M_RDATA(M_RDATA),
        .M_RLAST(M_RLAST), .M_RID(M_RID), .M_RUSER(M_RUSER), .M_RRESP(M_RRESP),
        .start_dma  (dma_rd_start),
        .num_trans  (dma_rd_num_trans),
        .start_addr (dma_rd_start_addr),
        .data_o     (dma_rd_data),
        .data_vld_o (dma_rd_data_vld),
        .data_cnt_o (dma_rd_data_cnt),
        .done_o     (dma_rd_done),
        .clk(clk), .rstn(rstn)
    );

    //----------------------------------------------------------------
    // AXI master DMA Write 인스턴스 (32-bit data)
    //----------------------------------------------------------------
    reg          dma_wr_start;
    reg  [19:0]  dma_wr_num_trans;
    reg  [31:0]  dma_wr_start_addr;
    wire [31:0]  dma_wr_indata;
    wire         dma_wr_indata_req;
    wire         dma_wr_done;
    wire         dma_wr_fail;

    axi_dma_wr #(
        .BITS_TRANS     (20),
        .OUT_BITS_TRANS (20),
        .AXI_WIDTH_ID   (AXI_M_WIDTH_ID),
        .AXI_WIDTH_AD   (AXI_M_WIDTH_AD),
        .AXI_WIDTH_DA   (AXI_M_WIDTH_DA)
    ) u_dma_wr (
        .M_AWVALID(M_AWVALID), .M_AWREADY(M_AWREADY), .M_AWADDR(M_AWADDR),
        .M_AWID(M_AWID), .M_AWLEN(M_AWLEN), .M_AWSIZE(M_AWSIZE),
        .M_AWBURST(M_AWBURST), .M_AWLOCK(M_AWLOCK), .M_AWCACHE(M_AWCACHE),
        .M_AWPROT(M_AWPROT), .M_AWQOS(M_AWQOS), .M_AWREGION(M_AWREGION), .M_AWUSER(M_AWUSER),
        .M_WVALID(M_WVALID), .M_WREADY(M_WREADY), .M_WDATA(M_WDATA),
        .M_WSTRB(M_WSTRB), .M_WLAST(M_WLAST), .M_WID(M_WID), .M_WUSER(M_WUSER),
        .M_BVALID(M_BVALID), .M_BREADY(M_BREADY), .M_BRESP(M_BRESP),
        .M_BID(M_BID), .M_BUSER(M_BUSER),
        .start_dma  (dma_wr_start),
        .done_o     (dma_wr_done),
        .num_trans  (dma_wr_num_trans),
        .start_addr (dma_wr_start_addr),
        .indata     (dma_wr_indata),
        .indata_req_o(dma_wr_indata_req),
        .fail_check (dma_wr_fail),
        .clk(clk), .rstn(rstn)
    );

    /* verilator lint_off UNUSED */
    wire _unused_wr = dma_wr_fail | |dma_rd_data_cnt;
    /* verilator lint_on UNUSED */

    // DMA busy tracking (done 은 1-cycle pulse → 레벨 신호로 변환)
    reg dma_wr_busy;
    reg dma_rd_busy;
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            dma_wr_busy <= 1'b0;
            dma_rd_busy <= 1'b0;
        end else begin
            if (dma_wr_start) dma_wr_busy <= 1'b1;
            else if (dma_wr_done) dma_wr_busy <= 1'b0;
            if (dma_rd_start) dma_rd_busy <= 1'b1;
            else if (dma_rd_done) dma_rd_busy <= 1'b0;
        end
    end

    // ----------------------------------------------------------------
    // OFM Streaming DMA + Weight Streaming 레지스터
    //   stream_mode     : OFM 이 dpram(65536 word) 초과 → 필터별 OFM DMA (L0, L2)
    //   stream_wgt_mode : weight 이 BRAM(1024 read entry) 초과 → 필터별 weight 로딩 (L6+)
    //   stream_fil_cnt  : OFM streaming 에서 지금까지 DMA 개시한 필터 수
    //   wgt_fil_cnt     : 다음에 로딩할 weight 필터 인덱스
    //   stream_dma_addr : 다음 OFM streaming DMA 의 DRAM byte 시작 주소
    //   addr_wgt_base   : 현재 layer 의 weight DRAM base 주소
    //   conv_pause_r    : conv_top 의 ST_NEXT 에서 대기 요청 (레벨 신호)
    // ----------------------------------------------------------------
    reg        stream_mode;
    reg [11:0] stream_fil_cnt;
    reg [11:0] wgt_fil_cnt;
    reg [31:0] stream_dma_addr;
    wire [19:0] stream_q_total   = {8'd0, lyr_ofm_w_half} * {8'd0, lyr_ofm_h_half};

    // ----------------------------------------------------------------
    // Row-block IFM Streaming (rb_stream) — L0/L2 처럼 line_buf 초과 layer
    //   lb_addr_calc = eir 방식에서 은 bank r%4 에 순환 덮어씀.
    //   올바른 데이터 보존을 위해 rb 단위(h_half=1) 로 conv_top 을 반복 구동.
    //   각 rb 처리 전: 2 개 IFM 행 DMA 로드 → conv_top i_start → 완료 후 다음 rb.
    // ----------------------------------------------------------------
    reg         rb_stream_mode_r;        // rb streaming 활성 (L0/L2)
    reg [11:0]  rb_stream_rb_r;          // 현재 처리 중인 rb (row_idx, 0..H_half-1)
    reg [11:0]  conv_h_half_r;           // conv_top i_ofm_h_half: rb_stream=1, 일반=H_half
    reg [11:0]  rb_stream_ifm_first_r;   // 다음 IFM DMA 의 첫 번째 IFM row 번호

    // rb_stream 조건: 3×3 conv AND H×entries_per_row > 8192
    wire [19:0] ifm_total_entries = {8'd0, lyr_ofm_h} * {8'd0, entries_per_row[11:0]};
    wire        ifm_rb_stream_needed = lyr_conv_en && !lyr_mode && (ifm_total_entries > 20'd8192);

    // IFM DMA 워드 수 계산
    wire [19:0] req_ifm_rb_init_trans = ({4'd0, entries_per_row} * 12'd3) << 2;  // 초기 3행
    wire [19:0] req_ifm_rb_row_trans  = ({4'd0, entries_per_row} * 12'd2) << 2;  // 이후 2행
    wire [19:0] req_ifm_rb_1row_trans = {4'd0, entries_per_row} << 2;             // 마지막 1행
    // weight BRAM 은 1024 × 288-bit read entry. Co×acc_len 이 1024 초과 시 streaming
    wire        stream_wgt_mode  = (({10'd0, lyr_co_total} * {12'd0, lyr_acc_len}) > 20'd1024);
    // 필터 1개 분 weight DMA word 수 (= acc_len × 16)
    wire [19:0] req_wgt_fil_trans = {12'd0, lyr_acc_len} << 4;
    // 현재 layer weight DRAM byte base
    wire [31:0] addr_wgt_base    = dram_wgt_base + ({14'd0, lyr_wgt_dram_blk} << 6);

    //----------------------------------------------------------------
    // DMA Read demux + width adapter
    //   - Bias: 32-bit → 32-bit gbuff bias (직접)
    //   - Weight: 4 × 32-bit assemble → 128-bit → lower 72 bit → gbuff weight
    //     (software 가 weight 를 16-byte entry 단위로 padding)
    //   - IFM: 4 × 32-bit assemble → 128-bit → line_buf
    //     (software 가 IFM 을 16-byte entry 단위로 packed: 4 col × 4 ch)
    //----------------------------------------------------------------
    reg [1:0]  asm_cnt;      // 4-word assembler counter
    reg [31:0] asm_w0, asm_w1, asm_w2;
    reg        asm_full;
    reg [127:0] asm_data;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            asm_cnt  <= 2'd0;
            asm_w0   <= 32'd0;
            asm_w1   <= 32'd0;
            asm_w2   <= 32'd0;
            asm_full <= 1'b0;
            asm_data <= 128'd0;
        end else begin
            asm_full <= 1'b0;
            if (dma_rd_start) asm_cnt <= 2'd0;
            else if (dma_rd_data_vld && (dma_target_r != DMA_TGT_BIAS)) begin
                case (asm_cnt)
                    2'd0: asm_w0 <= dma_rd_data;
                    2'd1: asm_w1 <= dma_rd_data;
                    2'd2: asm_w2 <= dma_rd_data;
                    2'd3: begin
                        asm_data <= {dma_rd_data, asm_w2, asm_w1, asm_w0};
                        asm_full <= 1'b1;
                    end
                endcase
                asm_cnt <= asm_cnt + 2'd1;
            end
        end
    end

    //----------------------------------------------------------------
    // IFM DMA write — cyclic line mapping
    //   IFM row r → physical line (r mod 4)
    //   row offset in line = (r / 4) × entries_per_row
    //   entry-in-row counter tracks col_block × ci_group position
    //----------------------------------------------------------------
    reg  [11:0] dma_ifm_row_r;            // 현재 적재 중인 IFM row (0..H-1)
    reg  [11:0] dma_ifm_eir_r;            // entry-in-row (0..entries_per_row-1)
    reg  [11:0] wgt_entry_addr_r;
    reg  [11:0] bias_entry_addr_r;

    wire [11:0] entries_per_row = lyr_w_blocks * {4'd0, lyr_ci_groups_r};

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            dma_ifm_row_r     <= 12'd0;
            dma_ifm_eir_r     <= 12'd0;
            wgt_entry_addr_r  <= 12'd0;
            bias_entry_addr_r <= 12'd0;
        end else begin
            if (dma_rd_start) begin
                case (dma_target_r)
                    // rb_stream: 연속 IFM 로드 시 실제 첫 row 번호 (bank 선택). 일반: row 0.
                    DMA_TGT_IFM:  begin dma_ifm_row_r <= rb_stream_mode_r ? rb_stream_ifm_first_r : 12'd0;
                                        dma_ifm_eir_r <= 12'd0; end
                    // weight: lyr_wgt_base(10-bit read entry) × 4 = write entry base
                    DMA_TGT_WGT:  wgt_entry_addr_r  <= {lyr_wgt_base, 2'b00};
                    // bias: 모든 layer 의 bias 를 lyr_bias_base 위치부터 BRAM 에 누적
                    DMA_TGT_BIAS: bias_entry_addr_r <= lyr_bias_base;
                    default: ;
                endcase
            end
            if (asm_full && (dma_target_r == DMA_TGT_IFM)) begin
                if (dma_ifm_eir_r == entries_per_row - 12'd1) begin
                    dma_ifm_eir_r <= 12'd0;
                    dma_ifm_row_r <= dma_ifm_row_r + 12'd1;
                end else begin
                    dma_ifm_eir_r <= dma_ifm_eir_r + 12'd1;
                end
            end
            if (asm_full && (dma_target_r == DMA_TGT_WGT)) begin
                wgt_entry_addr_r <= wgt_entry_addr_r + 12'd1;
            end
            if (dma_rd_data_vld && (dma_target_r == DMA_TGT_BIAS)) begin
                bias_entry_addr_r <= bias_entry_addr_r + 12'd1;
            end
        end
    end

    //----------------------------------------------------------------
    // IFM physical line / addr 계산
    //   row r 의 physical_line = r mod 4
    //   addr in line          = (r/4) × entries_per_row + entry_in_row
    //----------------------------------------------------------------
    wire [1:0]  lb_phys_line = dma_ifm_row_r[1:0];
    // Fix: eir 만 사용 — row_grp_idx 제거로 오버플로우 방지.
    // 각 행 r 은 bank r%4 의 addr eir(0..entries_per_row-1) 에 저장.
    // MAC 은 항상 addr 0..entries_per_row-1 만 읽으므로 정확히 대응.
    wire [23:0] lb_addr_calc = {12'd0, dma_ifm_eir_r};
    wire [10:0] lb_phys_addr = lb_addr_calc[10:0];

    wire        dma_lb_wr_en   = asm_full && (dma_target_r == DMA_TGT_IFM);
    wire [1:0]  dma_lb_wr_line = lb_phys_line;
    wire [10:0] dma_lb_wr_addr = lb_phys_addr;
    wire [127:0] dma_lb_wr_data = asm_data;

    // Weight DMA write 신호 (gbuff_param: 72-bit 입력, 4 × 72-bit slot 으로 분할되어 저장)
    //   software 가 16-byte entry 단위 padding 했다고 가정 → 하위 72 bit 사용
    wire        dma_wgt_we   = asm_full && (dma_target_r == DMA_TGT_WGT);
    wire [11:0] dma_wgt_addr = wgt_entry_addr_r;
    wire [71:0] dma_wgt_data = asm_data[71:0];

    // Bias DMA write 신호
    wire        dma_bias_we   = dma_rd_data_vld && (dma_target_r == DMA_TGT_BIAS);
    wire [11:0] dma_bias_addr = bias_entry_addr_r;
    wire [31:0] dma_bias_data = dma_rd_data;

    //----------------------------------------------------------------
    // ifm_line_buf 결선
    //----------------------------------------------------------------
    wire         conv_ifm_re;
    wire [11:0]  conv_ifm_row, conv_ifm_col;
    wire [7:0]   conv_ifm_acc;
    wire [287:0] ifm_00, ifm_01, ifm_10, ifm_11;
    wire         ifm_vld;

    wire [3:0] lyr_line_valid = 4'b1111;

    ifm_line_buf u_line_buf (
        .clk(clk), .rstn(rstn),
        .i_mode(lyr_mode),
        .i_w_blocks(lyr_w_blocks),
        .i_ci_groups(lyr_ci_groups_r),
        .i_w(lyr_ofm_w),
        .i_h(lyr_ofm_h),
        .i_line_valid(lyr_line_valid),
        .i_dma_wr_en(dma_lb_wr_en),
        .i_dma_wr_line(dma_lb_wr_line),
        .i_dma_wr_addr(dma_lb_wr_addr),
        .i_dma_wr_data(dma_lb_wr_data),
        .i_rd_en(conv_ifm_re),
        .i_rb(conv_ifm_row), .i_cb(conv_ifm_col),
        .i_acc_cyc(conv_ifm_acc),
        .o_ifm_00(ifm_00), .o_ifm_01(ifm_01),
        .o_ifm_10(ifm_10), .o_ifm_11(ifm_11),
        .o_vld(ifm_vld)
    );

    /* verilator lint_off UNUSED */
    wire _unused_ifm_vld = ifm_vld;
    /* verilator lint_on UNUSED */

    //----------------------------------------------------------------
    // conv_top
    //----------------------------------------------------------------
    wire [31:0] conv_pixel;
    wire        conv_pixel_vld;
    wire [25:0] conv_ofm_addr;
    wire        conv_fil_done;
    reg         conv_pause_r;

    conv_top u_conv (
        .clk(clk), .rstn(rstn),
        .i_start(conv_start),
        .o_done(conv_done),
        .o_fil_done(conv_fil_done),
        .i_conv_pause(conv_pause_r),
        .i_stream_wgt_mode(stream_wgt_mode),
        .i_mode(lyr_mode),
        .i_ofm_w_half(lyr_ofm_w_half),
        .i_ofm_h_half(conv_h_half_r),   // rb_stream=1, 일반=lyr_ofm_h_half
        .i_row_start(rb_stream_rb_r),    // rb_stream=rb 인덱스, 일반=0
        .i_co_total(lyr_co_total),
        .i_acc_len(lyr_acc_len),
        .i_wgt_base(lyr_wgt_base),
        .i_bias_base(lyr_bias_base),
        .i_shift(lyr_shift),
        .dma_wgt_we(dma_wgt_we),     .dma_wgt_addr(dma_wgt_addr),     .dma_wgt_data(dma_wgt_data),
        .dma_bias_we(dma_bias_we),   .dma_bias_addr(dma_bias_addr),   .dma_bias_data(dma_bias_data),
        .o_ifm_re(conv_ifm_re),
        .o_ifm_row(conv_ifm_row),
        .o_ifm_col(conv_ifm_col),
        .o_ifm_acc(conv_ifm_acc),
        .i_ifm_00(ifm_00), .i_ifm_01(ifm_01),
        .i_ifm_10(ifm_10), .i_ifm_11(ifm_11),
        .o_pixel(conv_pixel),
        .o_pixel_vld(conv_pixel_vld),
        .o_ofm_addr(conv_ofm_addr)
    );

    //----------------------------------------------------------------
    // max_pool_unit 인스턴스
    //----------------------------------------------------------------
    wire        pool_rd_en;
    wire [15:0] pool_rd_addr;
    wire [31:0] pool_rd_data;
    wire        pool_wr_en;
    wire [15:0] pool_wr_addr;
    wire [31:0] pool_wr_data;

    //----------------------------------------------------------------
    // pool 입력 word count = prev conv OFM packed = Co × pool_out_W × pool_out_H
    //   (prev conv 의 W_half = pool out W, H_half = pool out H)
    //   ST_INIT 에서 한 번 계산.
    //----------------------------------------------------------------
    reg [19:0] pool_total_in_r;
    always @(posedge clk or negedge rstn) begin
        if (!rstn)                       pool_total_in_r <= 20'd0;
        else if (top_state == ST_INIT)   pool_total_in_r <=
            ({8'd0, lyr_co_total} * {8'd0, lyr_ofm_w} * {8'd0, lyr_ofm_h});
    end

    max_pool_unit u_pool (
        .clk(clk), .rstn(rstn),
        .i_start(pool_start),
        .o_done(pool_done),
        .i_total_in_words(pool_total_in_r),
        .o_rd_en(pool_rd_en), .o_rd_addr(pool_rd_addr), .i_rd_data(pool_rd_data),
        .o_wr_en(pool_wr_en), .o_wr_addr(pool_wr_addr), .o_wr_data(pool_wr_data)
    );

    //----------------------------------------------------------------
    // max_pool_s1_unit (Layer 11 stride-1 maxpool)
    //   OFM dpram 의 같은 영역을 in/out 으로 사용 — input base 0,
    //   output base = Co × H_b × W_b (input 끝 + 1).
    //----------------------------------------------------------------
    reg         s1_pool_start;
    wire        s1_pool_done;
    wire        s1_pool_rd_en;
    wire [15:0] s1_pool_rd_addr;
    wire        s1_pool_wr_en;
    wire [15:0] s1_pool_wr_addr;
    wire [31:0] s1_pool_wr_data;
    wire [15:0] s1_pool_out_base = {4'd0, lyr_co_total} * {1'b0, lyr_ofm_h_half[10:0]} *
                                   {1'b0, lyr_ofm_w_half[10:0]};

    max_pool_s1_unit u_s1_pool (
        .clk(clk), .rstn(rstn),
        .i_start(s1_pool_start),
        .o_done(s1_pool_done),
        .i_co_total(lyr_co_total),
        .i_h_blocks(lyr_ofm_h_half),
        .i_w_blocks(lyr_ofm_w_half),
        .i_in_base(16'd0),
        .i_out_base(s1_pool_out_base),
        .o_rd_en(s1_pool_rd_en),   .o_rd_addr(s1_pool_rd_addr),
        .i_rd_data(pool_rd_data),
        .o_wr_en(s1_pool_wr_en),   .o_wr_addr(s1_pool_wr_addr), .o_wr_data(s1_pool_wr_data)
    );

    //----------------------------------------------------------------
    // upsample_unit (Layer 18)
    //   in_base 0, out_base = Co × in_H_b × in_W_b (in 끝)
    //----------------------------------------------------------------
    reg         up_start;
    wire        up_done;
    wire        up_rd_en;
    wire [15:0] up_rd_addr;
    wire        up_wr_en;
    wire [15:0] up_wr_addr;
    wire [31:0] up_wr_data;

    // L18: input 크기는 OFM 의 절반 (8×8). 즉 in H_b = lyr_ofm_h_half / 2.
    //   ※ lyr_ofm_w/h 는 OUTPUT 크기 (16×16). input = OUTPUT/2.
    wire [11:0] up_in_h_blocks = {1'b0, lyr_ofm_h_half[11:1]};   // = ofm_h / 4 = in_H / 2
    wire [11:0] up_in_w_blocks = {1'b0, lyr_ofm_w_half[11:1]};
    wire [15:0] up_out_base    = {4'd0, lyr_co_total} * {1'b0, up_in_h_blocks[10:0]} *
                                 {1'b0, up_in_w_blocks[10:0]};

    upsample_unit u_upsample (
        .clk(clk), .rstn(rstn),
        .i_start(up_start),
        .o_done(up_done),
        .i_co_total(lyr_co_total),
        .i_h_blocks(up_in_h_blocks),
        .i_w_blocks(up_in_w_blocks),
        .i_in_base(16'd0),
        .i_out_base(up_out_base),
        .o_rd_en(up_rd_en),   .o_rd_addr(up_rd_addr),
        .i_rd_data(pool_rd_data),
        .o_wr_en(up_wr_en),   .o_wr_addr(up_wr_addr), .o_wr_data(up_wr_data)
    );


    //----------------------------------------------------------------
    // OFM dpram port mux — conv / pool stride-2 / pool stride-1 / upsample / DMA store
    //   Port A (write): one of conv_pixel, pool_wr, s1_pool_wr, up_wr
    //   Port B (read) : one of pool_rd, s1_pool_rd, up_rd, DMA store read
    //   priority order (mutually exclusive in FSM): conv → pool → s1_pool → upsample → DMA
    //----------------------------------------------------------------
    wire        ofm_wr_en   = conv_pixel_vld | pool_wr_en | s1_pool_wr_en | up_wr_en;
    wire [15:0] ofm_wr_addr =
                  conv_pixel_vld ? conv_ofm_addr[15:0] :
                  pool_wr_en     ? pool_wr_addr       :
                  s1_pool_wr_en  ? s1_pool_wr_addr    :
                                   up_wr_addr;
    wire [31:0] ofm_wr_data =
                  conv_pixel_vld ? conv_pixel  :
                  pool_wr_en     ? pool_wr_data:
                  s1_pool_wr_en  ? s1_pool_wr_data :
                                   up_wr_data;

    reg [15:0] ofm_store_rd_addr_r;
    wire        ofm_rd_en = pool_rd_en | s1_pool_rd_en | up_rd_en
                          | (top_state == ST_DMA_OFM) | (top_state == ST_DMA_OFM_WAIT);
    wire [15:0] ofm_rd_addr_mux =
                  pool_rd_en    ? pool_rd_addr    :
                  s1_pool_rd_en ? s1_pool_rd_addr :
                  up_rd_en      ? up_rd_addr      :
                                  ofm_store_rd_addr_r;
    wire [31:0] ofm_rd_data;

    assign pool_rd_data = ofm_rd_data;     // s1_pool / upsample 도 동일 source 사용

    dpram_wrapper #(.DW(32), .AW(16), .DEPTH(65536), .N_DELAY(1)) u_ofm (
        .clk   (clk),
        .ena   (ofm_wr_en),
        .addra (ofm_wr_addr),
        .wea   (ofm_wr_en),
        .dia   (ofm_wr_data),
        .enb   (ofm_rd_en),
        .addrb (ofm_rd_addr_mux),
        .dob   (ofm_rd_data)
    );

    //----------------------------------------------------------------
    // OFM → DMA write 결선
    //   axi_dma_wr 는 indata_req_o 가 HIGH 일 때 indata 를 sample.
    //   본 module 은 OFM dpram 의 read result 를 indata 로 공급.
    //   indata_req_o pulse 마다 ofm_store_rd_addr_r 를 증가.
    //----------------------------------------------------------------
    assign dma_wr_indata = ofm_rd_data;

    //----------------------------------------------------------------
    // OFM store read 주소 — DMA wr 가 indata_req 할 때마다 +1.
    //   초기값: s1_pool 또는 upsample 의 경우 해당 out_base 부터 시작
    //          (conv / stride-2 pool 은 dpram addr 0 부터).
    //----------------------------------------------------------------
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            ofm_store_rd_addr_r <= 16'd0;
        end else if (dma_wr_start) begin
            if (stream_mode)
                // streaming: 필터 k 의 dpram base 계산
                //   일반 stream_mode : k × stream_q_total (H_half×W_half 간격)
                //   rb_stream 모드   : k × W_half         (1행=W_half 간격)
                // dma_wr_start 가 HIGH 인 cycle 에 stream_fil_cnt 는 이미 k+1.
                ofm_store_rd_addr_r <= rb_stream_mode_r ?
                    ((stream_fil_cnt[7:0] - 8'd1) * lyr_ofm_w_half[15:0]) :
                    ((stream_fil_cnt[7:0] - 8'd1) * stream_q_total[15:0]);
            else
                ofm_store_rd_addr_r <= lyr_s1_pool_en  ? s1_pool_out_base :
                                       lyr_upsample_en ? up_out_base      :
                                                         16'd0;
        end else if (dma_wr_indata_req) begin
            ofm_store_rd_addr_r <= ofm_store_rd_addr_r + 16'd1;
        end
    end

    //----------------------------------------------------------------
    // DMA num_trans / start_addr 계산
    //   - Weight: 16-byte entry × (Co × acc_len). 32-bit word count = 4 × Co × acc_len.
    //   - Bias  : 32-bit × Co. word count = Co.
    //   - IFM   : 16-byte entry × (H × W_blocks × ci_groups). word count = 4 × ....
    //   - OFM store: pool 출력의 packed word 수 또는 conv 출력의 packed word 수.
    //
    //   ※ 본 phase 단순화: layer 의 입력 전체를 한 번에 DMA load.
    //     큰 layer (L0/L2/L4) 의 IFM 은 line_buf 용량 (4 line × 2048 entry = 8192 entry)
    //     초과 시 일부만 load → row sliding 미구현. 추후 phase.
    //----------------------------------------------------------------
    //----------------------------------------------------------------
    // DMA num_trans (32-bit word count)
    //
    //   Weight  : 288-bit entry 1 개 = 4 × 72-bit slot. 각 slot 은 software 가
    //             16-byte padding (= 4 × 32-bit word) 으로 DRAM 에 저장.
    //             → 1 entry = 4 slot × 4 word = 16 word.
    //             → total = Co × acc_len × 16
    //   Bias    : 32-bit × Co
    //   IFM     : 128-bit entry × (H × W_blocks × ci_groups). 1 entry = 4 word.
    //             → total = H × W_blocks × ci_groups × 4
    //             ★ 본 phase 는 ENTIRE IFM 을 한 번에 load.
    //               line_buf 가 4 × 2048 entry. 큰 layer (L0..L4) 는
    //               wraparound 발생 → 첫 row OFM 만 유효 (TB 검증 범위).
    //----------------------------------------------------------------
    wire [19:0] req_wgt_trans  = ({8'd0, lyr_co_total} * {12'd0, lyr_acc_len}) << 4;
    wire [19:0] req_bias_trans = {8'd0, lyr_co_total};
    wire [19:0] req_ifm_trans  = ({8'd0, lyr_ofm_h} *
                                  {8'd0, lyr_w_blocks} *
                                  {12'd0, lyr_ci_groups_r}) << 2;

    // OFM store transactional count (32-bit word):
    //   - conv layer        : Co × W_half × H_half
    //   - pool stride-2 layer: pool input / 4 (= conv input / 4)
    //   - pool stride-1 (L11): Co × H_b × W_b (same size as input)
    //   - upsample (L18)    : 4 × Co × in_H_b × in_W_b = Co × ofm_H_h × ofm_W_h
    //   - route/yolo (L15/16/19/21): 0 (no DMA store)
    wire [23:0] conv_ofm_words_24 = {12'd0, lyr_co_total} * {12'd0, lyr_ofm_w_half} * {12'd0, lyr_ofm_h_half};
    wire [19:0] req_ofm_trans     =
                  lyr_route_en                 ? 20'd0 :
                  lyr_upsample_en              ? {1'b0, conv_ofm_words_24[18:0]} :
                  lyr_s1_pool_en               ? {1'b0, conv_ofm_words_24[18:0]} :
                  lyr_pool_en                  ? {2'd0, pool_total_in_r[19:2]} :  // pool out = pool in / 4
                                                 {1'b0, conv_ofm_words_24[18:0]};

    //----------------------------------------------------------------
    // 32-bit byte addr 계산 — offset_w (word) × 4 = byte addr
    //----------------------------------------------------------------
    wire [31:0] addr_wgt  = addr_wgt_base;  // 레이어별 DRAM weight base
    // bias: dram_wgt_base+0x00A0_0000 (weight 최대 ~10MB, 안전 마진 후)
    //   layer k 의 bias DRAM offset = lyr_bias_base × 4 bytes
    wire [31:0] addr_bias = dram_wgt_base + 32'h00A0_0000 + ({20'd0, lyr_bias_base} << 2);
    wire [31:0] addr_ifm  = lyr_use_input
                          ? dram_ifm_base
                          : (dram_ofm_base + ({12'd0, lyr_ifm_offset_w} << 2));
    wire [31:0] addr_ofm  = dram_ofm_base + ({12'd0, lyr_ofm_offset_w} << 2);

    /* verilator lint_off UNUSED */
    wire _unused_req = |req_wgt_trans | |req_bias_trans | |req_ifm_trans | |req_ofm_trans
                       | |addr_wgt | |addr_bias | |addr_ifm | |addr_ofm;
    /* verilator lint_on UNUSED */

    //----------------------------------------------------------------
    // Top FSM (orchestration)
    //----------------------------------------------------------------
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            top_state         <= ST_IDLE;
            layer_idx         <= 5'd0;
            conv_start        <= 1'b0;
            pool_start        <= 1'b0;
            s1_pool_start     <= 1'b0;
            up_start          <= 1'b0;
            dma_target_r      <= DMA_TGT_IFM;
            dma_rd_start      <= 1'b0;
            dma_rd_num_trans  <= 20'd0;
            dma_rd_start_addr <= 32'd0;
            dma_wr_start      <= 1'b0;
            dma_wr_num_trans  <= 20'd0;
            dma_wr_start_addr <= 32'd0;
            network_done_r    <= 1'b0;
            conv_pause_r      <= 1'b0;
            stream_mode       <= 1'b0;
            stream_fil_cnt    <= 12'd0;
            wgt_fil_cnt       <= 12'd0;
            stream_dma_addr   <= 32'd0;
            rb_stream_mode_r      <= 1'b0;
            rb_stream_rb_r        <= 12'd0;
            conv_h_half_r         <= 12'd1;
            rb_stream_ifm_first_r <= 12'd0;
        end else begin
            conv_start    <= 1'b0;
            pool_start    <= 1'b0;
            s1_pool_start <= 1'b0;
            up_start      <= 1'b0;
            dma_rd_start  <= 1'b0;
            dma_wr_start  <= 1'b0;
            // conv_pause_r 는 레벨 신호 — 여기서 매 cycle 초기화하지 않음
            // dma_wr_done / dma_rd_done 시점에 ST_DMA_OFM 내에서 명시적으로 해제

            case (top_state)
                ST_IDLE: begin
                    if (ap_start) begin
                        layer_idx      <= 5'd0;
                        network_done_r <= 1'b0;
                        top_state      <= ST_INIT;
                    end
                end

                ST_INIT: begin
                    // layer 파라미터 안정화 1 cycle
                    // Route 또는 YOLO 출력 (compute 없음, DMA 없음) → 바로 ST_NEXT
                    if (lyr_route_en ||
                        (!lyr_conv_en && !lyr_pool_en && !lyr_upsample_en)) begin
                        top_state <= ST_NEXT;
                    end else begin
                        top_state <= ST_DMA_WGT;
                    end
                end

                // ---------- Weight DMA load ----------
                ST_DMA_WGT: begin
                    if (lyr_conv_en) begin
                        dma_target_r      <= DMA_TGT_WGT;
                        // stream_wgt_mode: 1개 필터 분량만 로딩 (BRAM 초과 방지)
                        // 아닌 경우: 전체 layer 가중치 한 번에 로딩
                        dma_rd_num_trans  <= stream_wgt_mode ? req_wgt_fil_trans : req_wgt_trans;
                        dma_rd_start_addr <= addr_wgt;  // filter 0 base
                        dma_rd_start      <= 1'b1;
                        wgt_fil_cnt       <= 12'd1;     // 다음 로딩 대상 = filter 1
                        top_state         <= ST_DMA_WGT_WAIT;
                    end else begin
                        top_state <= ST_DMA_IFM;
                    end
                end
                ST_DMA_WGT_WAIT: begin
                    if (dma_rd_done) top_state <= ST_DMA_BIAS;
                end

                // ---------- Bias DMA load ----------
                ST_DMA_BIAS: begin
                    if (lyr_conv_en) begin
                        dma_target_r      <= DMA_TGT_BIAS;
                        dma_rd_num_trans  <= req_bias_trans;
                        dma_rd_start_addr <= addr_bias;
                        dma_rd_start      <= 1'b1;
                        top_state         <= ST_DMA_BIAS_WAIT;
                    end else begin
                        top_state <= ST_DMA_IFM;
                    end
                end
                ST_DMA_BIAS_WAIT: begin
                    if (dma_rd_done) top_state <= ST_DMA_IFM;
                end

                // ---------- IFM DMA load ----------
                //   conv / pool stride-1 / upsample 모두 DRAM 에서 IFM 적재 필요.
                //   pool stride-2 는 OFM dpram 에 이미 있는 직전 conv 결과 사용 → DMA skip.
                //   ※ pool/upsample 의 경우 OFM dpram 에 input 적재 후 처리.
                //   ※ rb_stream 모드 (L0/L2): 초기 3행만 로드.
                ST_DMA_IFM: begin
                    if (lyr_conv_en) begin
                        dma_target_r  <= DMA_TGT_IFM;
                        if (ifm_rb_stream_needed) begin
                            // rb_stream 초기화: 처음 3행만 로드 (rb=0은 rows -1,0,1,2 필요)
                            rb_stream_mode_r      <= 1'b1;
                            rb_stream_rb_r        <= 12'd0;
                            rb_stream_ifm_first_r <= 12'd0;  // 첫 IFM DMA: row 0부터 시작
                            dma_rd_num_trans  <= req_ifm_rb_init_trans;
                            dma_rd_start_addr <= addr_ifm;
                        end else begin
                            rb_stream_mode_r  <= 1'b0;
                            dma_rd_num_trans  <= req_ifm_trans;
                            dma_rd_start_addr <= addr_ifm;
                        end
                        dma_rd_start <= 1'b1;
                        top_state    <= ST_DMA_IFM_WAIT;
                    end else if (lyr_pool_en && !lyr_s1_pool_en) begin
                        // stride-2 pool: input 이 직전 conv 의 OFM (dpram 에 이미 있음)
                        top_state <= ST_RUN_POOL;
                    end else if (lyr_s1_pool_en) begin
                        // L11 stride-1: input 도 직전 conv 의 OFM (dpram 에 있음)
                        top_state <= ST_RUN_POOL;
                    end else if (lyr_upsample_en) begin
                        // L18: input 은 L17 OFM (dpram 에 있음)
                        top_state <= ST_RUN_POOL;
                    end else begin
                        top_state <= ST_NEXT;
                    end
                end
                ST_DMA_IFM_WAIT: begin
                    if (dma_rd_done) top_state <= ST_RUN_CONV;
                end

                // ---------- conv 실행 ----------
                ST_RUN_CONV: begin
                    conv_start    <= 1'b1;
                    stream_mode   <= (conv_ofm_words_24 > 24'd65536);
                    stream_fil_cnt <= 12'd0;
                    conv_pause_r  <= 1'b0;
                    // rb_stream: conv_top 에 h_half=1 + 현재 rb 인덱스 전달
                    conv_h_half_r <= rb_stream_mode_r ? 12'd1 : lyr_ofm_h_half;
                    // rb_stream: DRAM 시작 = addr_ofm + rb × W_half × 4 bytes
                    //   (필터 간 stride = stream_q_total × 4 바이트, 이후 동일)
                    if (rb_stream_mode_r)
                        stream_dma_addr <= addr_ofm +
                            (({20'd0, rb_stream_rb_r} * {20'd0, lyr_ofm_w_half}) << 2);
                    else
                        stream_dma_addr <= addr_ofm;
                    top_state <= ST_DMA_OFM;
                end

                // ---------- pool / s1_pool / upsample 실행 ----------
                ST_RUN_POOL: begin
                    if (lyr_s1_pool_en)         s1_pool_start <= 1'b1;
                    else if (lyr_upsample_en)   up_start      <= 1'b1;
                    else                        pool_start    <= 1'b1;
                    top_state <= ST_DMA_OFM;
                end

                // ---------- compute 완료 대기 + OFM store DMA ----------
                ST_DMA_OFM: begin
                    if (lyr_conv_en && stream_mode) begin
                        // ── OFM Streaming 모드 (L0, L2: OFM > 65536 word) ────────────
                        // 필터 완료 → pause → OFM DMA write → pause 해제 순환
                        // rb_stream 모드: OFM 워드 수 = W_half (1행 분), DRAM stride = stream_q_total
                        if (conv_fil_done) begin
                            conv_pause_r <= 1'b1;
                        end
                        if (conv_pause_r && !dma_wr_busy && !dma_wr_start) begin
                            dma_wr_start      <= 1'b1;
                            // rb_stream: 1행 분(W_half) 만 DMA, 일반: 전체 filter 분
                            dma_wr_num_trans  <= rb_stream_mode_r ?
                                {8'd0, lyr_ofm_w_half} : stream_q_total;
                            dma_wr_start_addr <= stream_dma_addr;
                            // 다음 필터 DRAM 위치 = 현재 + H_half×W_half×4 bytes (filter-major stride)
                            stream_dma_addr   <= stream_dma_addr + {10'd0, stream_q_total, 2'b00};
                            stream_fil_cnt    <= stream_fil_cnt + 12'd1;
                            // conv_pause_r 는 dma_wr_done 후에 해제
                        end
                        if (dma_wr_done && conv_pause_r) begin
                            conv_pause_r <= 1'b0;  // OFM DMA 완료 후 pause 해제
                        end
                        if (conv_done) begin
                            // rb_stream: 아직 처리할 rb 가 있으면 → 다음 rb IFM 로딩
                            if (rb_stream_mode_r && rb_stream_rb_r < lyr_ofm_h_half - 12'd1) begin
                                // 다음 rb 를 위한 2 행 IFM 로드
                                // 로드할 행 번호: 2*(rb_r)+3, 2*(rb_r)+4
                                // (rb+1 은 rows 2(rb+1)-1..2(rb+1)+2 = 2rb+1..2rb+4 필요;
                                //  이미 2rb+1, 2rb+2 는 이전 rb 로드 시 적재됨)
                                rb_stream_rb_r <= rb_stream_rb_r + 12'd1;
                                dma_target_r   <= DMA_TGT_IFM;
                                // next_row_first = 2*rb_current + 3 (rb_r still = old value here)
                                // rows_left = H - next_row_first
                                // 2행 로드 vs 1행 로드 결정
                                dma_rd_num_trans <= (({1'b0,lyr_ofm_h} - ({rb_stream_rb_r[10:0],1'b0} + 12'd3)) >= 12'd2) ?
                                    req_ifm_rb_row_trans : req_ifm_rb_1row_trans;
                                dma_rd_start_addr <= addr_ifm +
                                    ((({1'b0,rb_stream_rb_r[10:0],1'b0} + 13'd3) * {1'b0, entries_per_row}) << 2);
                                // dma_ifm_row_r 초기값: 다음 rb 의 첫 IFM row (= 2*rb_r_old + 3)
                                // bank = first_row mod 4 → 올바른 순환 bank 에 적재
                                rb_stream_ifm_first_r <= {rb_stream_rb_r[10:0], 1'b0} + 12'd3;
                                dma_rd_start   <= 1'b1;
                                stream_fil_cnt <= 12'd0;
                                top_state      <= ST_DMA_IFM_ROW_WAIT;
                            end else begin
                                // 모든 rb 처리 완료 (또는 비-rb_stream) → ST_NEXT
                                top_state <= ST_NEXT;
                            end
                        end
                    end else if (lyr_conv_en && stream_wgt_mode) begin
                        // ── Weight Streaming 모드 (L6+: weight BRAM 초과) ─────────────
                        // 필터 완료 → pause → 다음 필터 weight DMA → pause 해제 순환
                        // OFM 은 dpram 에 다 들어가므로 conv_done 후 일괄 DMA
                        if (conv_fil_done) begin
                            conv_pause_r <= 1'b1;
                        end
                        if (conv_pause_r && !dma_rd_busy && !dma_rd_start) begin
                            if (wgt_fil_cnt < {4'd0, lyr_co_total}) begin
                                // 다음 필터의 weight 를 BRAM 에 로딩
                                dma_target_r      <= DMA_TGT_WGT;
                                dma_rd_num_trans  <= req_wgt_fil_trans;
                                // addr = addr_wgt_base + wgt_fil_cnt × acc_len × 64 bytes
                                dma_rd_start_addr <= addr_wgt_base
                                    + (({20'd0, wgt_fil_cnt[11:0]} * {24'd0, lyr_acc_len[7:0]}) << 6);
                                dma_rd_start      <= 1'b1;
                                wgt_fil_cnt       <= wgt_fil_cnt + 12'd1;
                            end else begin
                                // 마지막 필터 완료 (no next weight) → 즉시 pause 해제
                                conv_pause_r <= 1'b0;
                            end
                        end
                        if (dma_rd_done && conv_pause_r) begin
                            conv_pause_r <= 1'b0;  // weight DMA 완료 → conv 재개
                        end
                        if (conv_done) begin
                            // 일괄 OFM DMA (dpram → DRAM)
                            dma_wr_num_trans  <= req_ofm_trans;
                            dma_wr_start_addr <= addr_ofm;
                            dma_wr_start      <= 1'b1;
                            top_state         <= ST_DMA_OFM_WAIT;
                        end
                    end else begin
                        // ── 일반 모드 (OFM dpram 내 수용, weight 한 번에 로딩) ────────
                        if (   (lyr_conv_en     && conv_done)
                            || (lyr_s1_pool_en  && s1_pool_done)
                            || (lyr_upsample_en && up_done)
                            || (lyr_pool_en && !lyr_s1_pool_en && pool_done)) begin
                            dma_wr_num_trans  <= req_ofm_trans;
                            dma_wr_start_addr <= addr_ofm;
                            dma_wr_start      <= 1'b1;
                            top_state         <= ST_DMA_OFM_WAIT;
                        end
                    end
                end
                ST_DMA_OFM_WAIT: begin
                    if (dma_wr_done) top_state <= ST_NEXT;
                end

                // ---------- rb_stream: 다음 rb IFM 로딩 후 conv 재시작 ----------
                ST_DMA_IFM_ROW_WAIT: begin
                    if (dma_rd_done) begin
                        // 다음 rb 에 대해 conv_top 재시작
                        conv_start    <= 1'b1;
                        // conv_h_half_r 는 이미 1 (rb_stream 초기화 시 설정)
                        // stream_dma_addr = addr_ofm + rb_r × W_half × 4 (updated rb_r)
                        stream_dma_addr <= addr_ofm +
                            (({20'd0, rb_stream_rb_r} * {20'd0, lyr_ofm_w_half}) << 2);
                        conv_pause_r  <= 1'b0;
                        top_state     <= ST_DMA_OFM;
                    end
                end

                ST_NEXT: begin
                    if (layer_idx == 5'd21) top_state <= ST_DONE;
                    else begin
                        layer_idx <= layer_idx + 5'd1;
                        top_state <= ST_INIT;
                    end
                end

                ST_DONE: begin
                    network_done_r <= 1'b1;
                    top_state      <= ST_IDLE;
                end

                default: top_state <= ST_IDLE;
            endcase
        end
    end

    /* verilator lint_off UNUSED */
    wire _unused_misc = lyr_pool_stride | |lyr_ci;
    /* verilator lint_on UNUSED */

endmodule
