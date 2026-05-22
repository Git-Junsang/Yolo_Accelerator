`timescale 1ns / 1ps
`include "user_define_h.v"
//----------------------------------------------------------------+
// yolo_engine.v — Clean rewrite v2 (L0 only)
//
// 설계 핵심: conv_top 을 (rb, fi) 단위로 1번씩 호출.
//   - co_total=1, h_half=1, row_start=rb, wgt_base=fi, bias_base=fi
//   - 각 호출 = 128 출력 pixel (한 filter 한 row)
//   - conv_top 내부의 filter 전이 (ST_NEXT) 우회 — 항상 첫 fil
//
// 그 외 설계:
//   - L0 only (layer 표 없음, hardcoded)
//   - 단일 main FSM, 모든 FSM reg 는 한 always 안에서만 갱신
//   - DMA write 카운터는 별도 always (asm_full 기반)
//   - 서브모듈은 검증된 그대로 사용
//
// L0 사양:
//   conv 3×3, Ci=3, Co=16, H=W=256
//   acc_len=1, shift=8, ci_groups=1
//   weight DMA = 16 fi × 16 word/entry = 256 word
//   bias DMA = 16 word (32-bit sign-extended bias)
//   IFM rb=0: 3 row × 256 word = 768 word
//   IFM rb≥1: 2 row × 256 word = 512 word
//   OFM per (rb, fi) = 128 word
//
// DRAM 주소:
//   wgt_base + 0           = weight (256 word)
//   wgt_base + 0x00A00000  = bias (16 word)
//   ifm_base               = L0 input (NHWC 4ch padded, 16-byte entry)
//   ofm_base               = L0 output (16 fi × 128 × 128 packed word)
//
// IFM line buffer 매핑 (cyclic):
//   IFM row r → bank r%4 의 addr 0..63
//   rb=0: load rows {0,1,2} → banks {0,1,2}. Bank 3 = row -1 padding.
//   rb≥1: load rows {2*rb+1, 2*rb+2} → banks {(2*rb+1)%4, (2*rb+2)%4}.
//----------------------------------------------------------------+

module yolo_engine #(
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 4,
    parameter integer AXI_M_WIDTH_AD     = 32,
    parameter integer AXI_M_WIDTH_DA     = 32,
    parameter integer AXI_M_WIDTH_ID     = 4
)(
    input  wire                              clk,
    input  wire                              rstn,

    // AXI4-Lite slave
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

    // AXI4 master
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
    input  wire                              M_RVALID,
    output wire                              M_RREADY,
    input  wire [AXI_M_WIDTH_DA-1:0]         M_RDATA,
    input  wire                              M_RLAST,
    input  wire [AXI_M_WIDTH_ID-1:0]         M_RID,
    input  wire [3:0]                        M_RUSER,
    input  wire [1:0]                        M_RRESP,
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
    output wire                              M_WVALID,
    input  wire                              M_WREADY,
    output wire [AXI_M_WIDTH_DA-1:0]         M_WDATA,
    output wire [(AXI_M_WIDTH_DA/8)-1:0]     M_WSTRB,
    output wire                              M_WLAST,
    output wire [AXI_M_WIDTH_ID-1:0]         M_WID,
    output wire [3:0]                        M_WUSER,
    input  wire                              M_BVALID,
    output wire                              M_BREADY,
    input  wire [1:0]                        M_BRESP,
    input  wire [AXI_M_WIDTH_ID-1:0]         M_BID,
    input  wire                              M_BUSER,
    output wire                              o_network_done,
    output wire                              network_done_led
);

    //----------------------------------------------------------------
    // L0 constants
    //----------------------------------------------------------------
    localparam [11:0] L0_W        = 12'd256;
    localparam [11:0] L0_H        = 12'd256;
    localparam [11:0] L0_W_HALF   = 12'd128;
    localparam [11:0] L0_H_HALF   = 12'd128;
    localparam [11:0] L0_W_BLOCKS = 12'd64;
    localparam [11:0] L0_CO       = 12'd16;
    localparam [7:0]  L0_ACC_LEN  = 8'd1;
    localparam [4:0]  L0_SHIFT    = 5'd8;
    localparam [7:0]  L0_CI_GRPS  = 8'd1;

    localparam [19:0] WGT_DMA_WORDS   = 20'd256;   // 16 fi × 16 word/entry
    localparam [19:0] BIAS_DMA_WORDS  = 20'd16;
    localparam [19:0] IFM_INIT_WORDS  = 20'd768;   // rb=0: 3 rows × 256
    localparam [19:0] IFM_NEXT_WORDS  = 20'd512;   // rb>=1: 2 rows × 256
    localparam [19:0] OFM_FIL_WORDS   = 20'd128;   // 1 fi × 1 rb = W_half words

    //----------------------------------------------------------------
    // L1 constants (POOL_S2, 16ch × 256 → 128, max pool stride 2)
    //
    //   L0 OFM (= L1 IFM) per filter in DRAM:
    //     16,384 word (= 65,536 byte = 128 × 128 × 4 (2×2 packed))
    //   L1 OFM per filter in DRAM:
    //     4,096 word (= 16,384 byte = 128 × 32 (4 horiz packed))
    //
    //   Processing strategy: 한 filter 씩
    //     1) L0 OFM[fi] → OFM dpram[0..16383] (DMA read, 32-bit 직접 적재)
    //     2) max_pool_unit (i_total_in_words = 16,384) — in-place pool
    //        결과: dpram[0..4095]
    //     3) dpram[0..4095] → L1 OFM[fi] (DMA write)
    //
    //   L1 OFM DRAM word offset = 262,144 (= L0 전체 OFM word 수)
    //   per-fi byte stride = 4,096 word × 4 = 16,384 byte = 0x4000
    //----------------------------------------------------------------
    localparam [4:0]  L1_CO              = 5'd16;
    localparam [19:0] L1_IFM_WORDS_PER_FI = 20'd16384;
    localparam [19:0] L1_OFM_WORDS_PER_FI = 20'd4096;
    localparam [31:0] L1_OFM_BYTE_BASE    = 32'd1048576;     // 262,144 × 4 byte
    localparam [31:0] L0_OFM_FI_BYTE      = 32'd65536;       // L0 OFM per-fi byte stride
    localparam [31:0] L1_OFM_FI_BYTE      = 32'd16384;       // L1 OFM per-fi byte stride

    //----------------------------------------------------------------
    // REPACK / L2 IFM constants
    //
    //   L1 OFM (channel-major byte stream) → L2 IFM (NHWC packed)
    //   - L1 OFM per (fi, r, cb_quad) word = 4 horizontal pool pixels of same channel
    //     fi*16384 + r*128 + cb_quad (word) — total 16 × 16,384 word
    //   - L2 IFM 1 entry = 16 byte = 4 col × 4 ch (col-outer, ch-inner)
    //     order per row: ci_g 0..3 outer, col_b 0..31 inner  → 128 entries/row
    //     row-major across 128 rows
    //
    //   REPACK 동작 (per row 1차원 loop, 내부 ci_g loop):
    //     [Phase A]  ci_g 별로 4 channel 의 1 row (= 128 byte = 32 word) 을
    //                DMA-read 하여 OFM dpram scratch_a[ch_l*32 + col_b] 에 적재
    //                (4 burst × 32 word per ci_g)
    //     [Phase B]  scratch_a[ch_l*32 + col_b] 4 word 을 읽어 transpose,
    //                4 packed output word 을 scratch_b[col_b*4 + col_l] 에 기록
    //                (per col_b: 4 cycle read + 4 cycle write — total 256 cycle/ci_g)
    //     [Phase C]  scratch_b[0..127] 을 DMA-write 로 L2 IFM 영역에 dump
    //                (128 word per ci_g — 4 ci_g × 128 = 512 word per row)
    //
    //   DRAM 주소:
    //     L2 IFM byte base = dram_ofm_base + 0x140000 (= L1 OFM end)
    //     per (r, ci_g, col_b) entry byte = base + r*2048 + ci_g*32*16 + col_b*16
    //                                     = base + r*2048 + ci_g*512   + col_b*16
    //----------------------------------------------------------------
    localparam [31:0] L2_IFM_BYTE_BASE       = 32'h00140000;   // L1 OFM end
    localparam [31:0] L1_OFM_ROW_BYTE        = 32'd128;        // 32 word × 4 byte (per ch per row)
    localparam [31:0] L2_IFM_ROW_BYTE        = 32'd2048;       // 128 entry × 16 byte
    localparam [31:0] L2_IFM_CIG_BYTE_PER_R  = 32'd512;        // 32 entry × 16 byte
    localparam [19:0] REPACK_LOAD_WORDS_PER_BURST = 20'd32;    // 1 ch × 1 row = 32 word
    localparam [19:0] REPACK_STORE_WORDS_PER_CIG  = 20'd128;   // 32 entry × 4 word/entry

    // scratch dpram region (OFM dpram, shared time-multiplexed):
    //   scratch_a base addr (32-bit word):   0   (capacity 128 word)
    //   scratch_b base addr (32-bit word): 128   (capacity 128 word)
    localparam [15:0] SCRATCH_A_BASE = 16'd0;
    localparam [15:0] SCRATCH_B_BASE = 16'd128;

    //----------------------------------------------------------------
    // L2 constants  (CONV3x3, Ci=16, Co=32, 128×128 → 128×128)
    //----------------------------------------------------------------
    localparam [11:0] L2_W        = 12'd128;
    localparam [11:0] L2_H        = 12'd128;
    localparam [11:0] L2_W_HALF   = 12'd64;
    localparam [11:0] L2_H_HALF   = 12'd64;
    localparam [11:0] L2_W_BLOCKS = 12'd32;    // ceil(W/4)
    localparam [11:0] L2_CO       = 12'd32;
    localparam [7:0]  L2_ACC_LEN  = 8'd4;      // ci_groups
    localparam [4:0]  L2_SHIFT    = 5'd6;      // scale = 0x40 = 64 = 2^6
    localparam [7:0]  L2_CI_GRPS  = 8'd4;
    // 한 row 의 line_buf 총 entry = W_BLK × ci_groups = 32 × 4 = 128
    localparam [11:0] L2_EIR_PER_ROW = 12'd128;

    // L2 DMA word counts
    //   weight: 32 fi × 4 acc_len × 16 word/entry = 2048 word
    //   bias  : 32 fi
    //   IFM rb=0: 3 rows × (128 entry × 4 word/entry) = 1536 word
    //   IFM rb≥1: 2 rows × 512 = 1024 word
    //   OFM per (rb, fi): W_half = 64 word
    localparam [19:0] L2_WGT_DMA_WORDS  = 20'd2048;
    localparam [19:0] L2_BIAS_DMA_WORDS = 20'd32;
    localparam [19:0] L2_IFM_INIT_WORDS = 20'd1536;
    localparam [19:0] L2_IFM_NEXT_WORDS = 20'd1024;
    localparam [19:0] L2_OFM_FIL_WORDS  = 20'd64;

    // L2 weight 시작 위치: gen_sim_dram.py 의 blk_off=16 (L0 는 blk_off=0)
    //   → byte offset = 16 × 64 = 1024 byte = 256 word
    localparam [31:0] L2_WGT_BYTE_OFF  = 32'd1024;
    // L2 bias 시작 위치: L0 의 16 filter 뒤 → byte offset 16 × 4 = 64
    localparam [31:0] L2_BIAS_BYTE_OFF = 32'd64;
    // L2 OFM DRAM byte base (offset from dram_ofm_base)
    localparam [31:0] L2_OFM_BYTE_BASE = 32'h00180000;
    // L2 wgt entry base
    //   Weight BRAM 비대칭: write 측 72-bit (4096 depth), read 측 288-bit (1024 depth)
    //                       read addr K ↔ write addr {K, 2'b00..11}
    //   L0 wgt = 16 fi × 1 acc_len = 16 READ entry = 64 WRITE entry
    //   L2 의 READ base = 16, WRITE base = 64
    localparam [11:0] L2_WGT_WR_ENTRY_BASE = 12'd64;   // DMA write counter init
    localparam [9:0]  L2_WGT_RD_ENTRY_BASE = 10'd16;   // conv_top i_wgt_base
    // Bias 는 write/read 같은 단위 (32-bit), L2 base = 16
    localparam [11:0] L2_BIAS_ENTRY_BASE = 12'd16;

    //----------------------------------------------------------------
    // AXI slave (control reg)
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

    wire        ap_start      = ctrl_reg0[0];
    wire [31:0] dram_wgt_base = ctrl_reg1;
    wire [31:0] dram_ifm_base = ctrl_reg2;
    wire [31:0] dram_ofm_base = ctrl_reg3;

    //----------------------------------------------------------------
    // Layer counters
    //   0 = L0 active, 1 = L0 done / L1 active, 2 = L1 done / REPACK / L2 active,
    //   3 = L2 done (network end)
    //----------------------------------------------------------------
    reg [4:0] layer_idx;

    //----------------------------------------------------------------
    // FSM 상태
    //   0..11   : conv FSM 공통 (L0, L2 시간 공유 — conv_phase_r 로 구별)
    //   12      : S_CONV_DONE (다음 phase 분기)
    //   13..19  : L1 (POOL_S2) FSM
    //   20..27  : REPACK FSM
    //   28      : S_DONE (network end)
    //----------------------------------------------------------------
    localparam S_IDLE              = 5'd0,
               S_LOAD_WGT          = 5'd1,
               S_LOAD_WGT_WAIT     = 5'd2,
               S_LOAD_BIAS         = 5'd3,
               S_LOAD_BIAS_WAIT    = 5'd4,
               S_RB_DMA_IFM        = 5'd5,
               S_RB_DMA_IFM_WAIT   = 5'd6,
               S_FIL_CONV_START    = 5'd7,
               S_FIL_CONV_WAIT     = 5'd8,
               S_FIL_DMA_STORE     = 5'd9,
               S_FIL_DMA_STORE_WAIT= 5'd10,
               S_RB_NEXT           = 5'd11,
               S_CONV_DONE         = 5'd12,
               S_L1_FI_LOAD        = 5'd13,
               S_L1_FI_LOAD_WAIT   = 5'd14,
               S_L1_FI_POOL        = 5'd15,
               S_L1_FI_POOL_WAIT   = 5'd16,
               S_L1_FI_STORE       = 5'd17,
               S_L1_FI_STORE_WAIT  = 5'd18,
               S_L1_NEXT_FI        = 5'd19,
               S_RP_LOAD           = 5'd20,    // REPACK: DMA-read 1 ch row
               S_RP_LOAD_WAIT      = 5'd21,
               S_RP_GEN            = 5'd22,    // transpose generate
               S_RP_STORE          = 5'd23,    // DMA-write scratch_b
               S_RP_STORE_WAIT     = 5'd24,
               S_RP_NEXT_CIG       = 5'd25,    // ci_g++ or row++
               S_DONE              = 5'd28;

    reg [4:0]  state_r;
    reg [11:0] rb_r;       // 0..127 (L0) / 0..63 (L2)
    reg [4:0]  fi_r;       // 0..31 (L2 max) / 0..15 (L0, L1)

    //----------------------------------------------------------------
    // conv_phase_r — 현재 conv FSM 이 누구를 처리하는지 (L0 / L2)
    //   0 = L0, 2 = L2 — 그 외 값은 conv FSM 진입 안 함
    //----------------------------------------------------------------
    reg [4:0] conv_phase_r;
    wire is_conv_l0 = (conv_phase_r == 5'd0);
    wire is_conv_l2 = (conv_phase_r == 5'd2);

    //----------------------------------------------------------------
    // conv 파라미터 mux (현재 conv 레이어 기준)
    //----------------------------------------------------------------
    wire [11:0] cur_w_blocks   = is_conv_l2 ? L2_W_BLOCKS : L0_W_BLOCKS;
    wire [11:0] cur_w          = is_conv_l2 ? L2_W        : L0_W;
    wire [11:0] cur_h          = is_conv_l2 ? L2_H        : L0_H;
    wire [11:0] cur_w_half     = is_conv_l2 ? L2_W_HALF   : L0_W_HALF;
    wire [11:0] cur_h_half     = is_conv_l2 ? L2_H_HALF   : L0_H_HALF;
    wire [11:0] cur_co         = is_conv_l2 ? L2_CO       : L0_CO;
    wire [7:0]  cur_acc_len    = is_conv_l2 ? L2_ACC_LEN  : L0_ACC_LEN;
    wire [4:0]  cur_shift      = is_conv_l2 ? L2_SHIFT    : L0_SHIFT;
    wire [7:0]  cur_ci_grps    = is_conv_l2 ? L2_CI_GRPS  : L0_CI_GRPS;
    wire [11:0] cur_eir_per_row= is_conv_l2 ? L2_EIR_PER_ROW : L0_W_BLOCKS;

    wire [19:0] cur_wgt_dma    = is_conv_l2 ? L2_WGT_DMA_WORDS  : WGT_DMA_WORDS;
    wire [19:0] cur_bias_dma   = is_conv_l2 ? L2_BIAS_DMA_WORDS : BIAS_DMA_WORDS;
    wire [19:0] cur_ifm_init   = is_conv_l2 ? L2_IFM_INIT_WORDS : IFM_INIT_WORDS;
    wire [19:0] cur_ifm_next   = is_conv_l2 ? L2_IFM_NEXT_WORDS : IFM_NEXT_WORDS;
    wire [19:0] cur_ofm_fil    = is_conv_l2 ? L2_OFM_FIL_WORDS  : OFM_FIL_WORDS;

    // BRAM weight/bias entry base
    //   wgt 는 write/read 단위가 다르므로 분리:
    //     cur_wgt_wr_entry_base = DMA write 카운터 init  (72-bit entry, max 4096)
    //     cur_wgt_rd_entry_base = conv_top i_wgt_base    (288-bit entry, max 1024)
    wire [11:0] cur_wgt_wr_entry_base = is_conv_l2 ? L2_WGT_WR_ENTRY_BASE : 12'd0;
    wire [9:0]  cur_wgt_rd_entry_base = is_conv_l2 ? L2_WGT_RD_ENTRY_BASE : 10'd0;
    wire [11:0] cur_bias_entry_base   = is_conv_l2 ? L2_BIAS_ENTRY_BASE   : 12'd0;

    //----------------------------------------------------------------
    // DMA target enum (for asm/counter decoding)
    //----------------------------------------------------------------
    localparam DMA_TGT_NONE   = 3'd0,
               DMA_TGT_WGT    = 3'd1,
               DMA_TGT_BIAS   = 3'd2,
               DMA_TGT_IFM    = 3'd3,
               DMA_TGT_L1_IFM = 3'd4;   // 32-bit 직접 OFM dpram 적재
    reg [2:0]  dma_target_r;

    //----------------------------------------------------------------
    // DMA controllers (axi_dma_rd / axi_dma_wr)
    //----------------------------------------------------------------
    reg         dma_rd_start;
    reg  [19:0] dma_rd_num_trans;
    reg  [31:0] dma_rd_start_addr;
    wire [31:0] dma_rd_data;
    wire        dma_rd_data_vld;
    wire [19:0] dma_rd_data_cnt;
    wire        dma_rd_done;

    axi_dma_rd #(
        .BITS_TRANS(20),
        .AXI_WIDTH_ID(AXI_M_WIDTH_ID),
        .AXI_WIDTH_AD(AXI_M_WIDTH_AD),
        .AXI_WIDTH_DA(AXI_M_WIDTH_DA)
    ) u_dma_rd (
        .M_ARVALID(M_ARVALID), .M_ARREADY(M_ARREADY), .M_ARADDR(M_ARADDR),
        .M_ARID(M_ARID), .M_ARLEN(M_ARLEN), .M_ARSIZE(M_ARSIZE),
        .M_ARBURST(M_ARBURST), .M_ARLOCK(M_ARLOCK), .M_ARCACHE(M_ARCACHE),
        .M_ARPROT(M_ARPROT), .M_ARQOS(M_ARQOS), .M_ARREGION(M_ARREGION), .M_ARUSER(M_ARUSER),
        .M_RVALID(M_RVALID), .M_RREADY(M_RREADY), .M_RDATA(M_RDATA),
        .M_RLAST(M_RLAST), .M_RID(M_RID), .M_RUSER(M_RUSER), .M_RRESP(M_RRESP),
        .start_dma(dma_rd_start), .num_trans(dma_rd_num_trans), .start_addr(dma_rd_start_addr),
        .data_o(dma_rd_data), .data_vld_o(dma_rd_data_vld),
        .data_cnt_o(dma_rd_data_cnt), .done_o(dma_rd_done),
        .clk(clk), .rstn(rstn)
    );

    reg         dma_wr_start;
    reg  [19:0] dma_wr_num_trans;
    reg  [31:0] dma_wr_start_addr;
    wire [31:0] dma_wr_indata;
    wire        dma_wr_indata_req;
    wire        dma_wr_done;
    wire        dma_wr_fail;

    axi_dma_wr #(
        .BITS_TRANS(20), .OUT_BITS_TRANS(20),
        .AXI_WIDTH_ID(AXI_M_WIDTH_ID),
        .AXI_WIDTH_AD(AXI_M_WIDTH_AD),
        .AXI_WIDTH_DA(AXI_M_WIDTH_DA)
    ) u_dma_wr (
        .M_AWVALID(M_AWVALID), .M_AWREADY(M_AWREADY), .M_AWADDR(M_AWADDR),
        .M_AWID(M_AWID), .M_AWLEN(M_AWLEN), .M_AWSIZE(M_AWSIZE),
        .M_AWBURST(M_AWBURST), .M_AWLOCK(M_AWLOCK), .M_AWCACHE(M_AWCACHE),
        .M_AWPROT(M_AWPROT), .M_AWQOS(M_AWQOS), .M_AWREGION(M_AWREGION), .M_AWUSER(M_AWUSER),
        .M_WVALID(M_WVALID), .M_WREADY(M_WREADY), .M_WDATA(M_WDATA),
        .M_WSTRB(M_WSTRB), .M_WLAST(M_WLAST), .M_WID(M_WID), .M_WUSER(M_WUSER),
        .M_BVALID(M_BVALID), .M_BREADY(M_BREADY), .M_BRESP(M_BRESP),
        .M_BID(M_BID), .M_BUSER(M_BUSER),
        .start_dma(dma_wr_start), .done_o(dma_wr_done),
        .num_trans(dma_wr_num_trans), .start_addr(dma_wr_start_addr),
        .indata(dma_wr_indata), .indata_req_o(dma_wr_indata_req),
        .fail_check(dma_wr_fail),
        .clk(clk), .rstn(rstn)
    );

    /* verilator lint_off UNUSED */
    wire _unused = |dma_rd_data_cnt | dma_wr_fail;
    /* verilator lint_on UNUSED */

    //----------------------------------------------------------------
    // 4-word assembler (32-bit AXI beat → 128-bit entry, for IFM/WGT)
    //----------------------------------------------------------------
    reg  [1:0]   asm_cnt;
    reg  [31:0]  asm_w0, asm_w1, asm_w2;
    reg          asm_full;
    reg  [127:0] asm_data;

    wire asm_active = (dma_target_r == DMA_TGT_WGT) || (dma_target_r == DMA_TGT_IFM);

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            asm_cnt  <= 2'd0;
            asm_w0   <= 32'd0; asm_w1 <= 32'd0; asm_w2 <= 32'd0;
            asm_full <= 1'b0;
            asm_data <= 128'd0;
        end else begin
            asm_full <= 1'b0;
            if (dma_rd_start) begin
                asm_cnt <= 2'd0;
            end else if (dma_rd_data_vld && asm_active) begin
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
    // Weight/Bias/IFM write counters
    //
    //   Weight: incremented per asm_full when DMA_TGT_WGT.
    //   Bias  : incremented per dma_rd_data_vld when DMA_TGT_BIAS (32-bit direct).
    //   IFM   : incremented per asm_full when DMA_TGT_IFM.
    //           dma_ifm_eir_r wraps at L0_W_BLOCKS (=64),
    //           dma_ifm_row_r increments at wrap. Bank = row mod 4.
    //
    //   ifm_first_row 는 main FSM 이 S_RB_DMA_IFM 진입 시 결정. 그 값으로
    //   여기서 dma_ifm_row_r 을 초기화. 단일 always-block 내에서 한 reg
    //   = 단일 writer.
    //----------------------------------------------------------------
    reg [11:0] wgt_entry_addr_r;
    reg [11:0] bias_entry_addr_r;
    reg [11:0] dma_ifm_row_r;
    reg [11:0] dma_ifm_eir_r;

    // main FSM 이 S_RB_DMA_IFM cycle 에 셋업
    reg [11:0] dma_ifm_row_start_r;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            wgt_entry_addr_r  <= 12'd0;
            bias_entry_addr_r <= 12'd0;
            dma_ifm_row_r     <= 12'd0;
            dma_ifm_eir_r     <= 12'd0;
        end else begin
            // DMA 시작 시 카운터 리셋 (또는 IFM 의 경우 row start 설정)
            if (dma_rd_start) begin
                case (dma_target_r)
                    DMA_TGT_WGT:  wgt_entry_addr_r  <= cur_wgt_wr_entry_base;
                    DMA_TGT_BIAS: bias_entry_addr_r <= cur_bias_entry_base;
                    DMA_TGT_IFM:  begin
                        dma_ifm_row_r <= dma_ifm_row_start_r;
                        dma_ifm_eir_r <= 12'd0;
                    end
                    default: ;
                endcase
            end else begin
                if (asm_full && dma_target_r == DMA_TGT_WGT)
                    wgt_entry_addr_r <= wgt_entry_addr_r + 12'd1;
                if (dma_rd_data_vld && dma_target_r == DMA_TGT_BIAS)
                    bias_entry_addr_r <= bias_entry_addr_r + 12'd1;
                if (asm_full && dma_target_r == DMA_TGT_IFM) begin
                    if (dma_ifm_eir_r == cur_eir_per_row - 12'd1) begin
                        dma_ifm_eir_r <= 12'd0;
                        dma_ifm_row_r <= dma_ifm_row_r + 12'd1;
                    end else begin
                        dma_ifm_eir_r <= dma_ifm_eir_r + 12'd1;
                    end
                end
            end
        end
    end

    // Sub-module write signals
    wire        gbuff_wgt_we   = asm_full && (dma_target_r == DMA_TGT_WGT);
    wire [11:0] gbuff_wgt_addr = wgt_entry_addr_r;
    wire [71:0] gbuff_wgt_data = asm_data[71:0];

    wire        gbuff_bias_we   = dma_rd_data_vld && (dma_target_r == DMA_TGT_BIAS);
    wire [11:0] gbuff_bias_addr = bias_entry_addr_r;
    wire [31:0] gbuff_bias_data = dma_rd_data;

    wire         lb_wr_en    = asm_full && (dma_target_r == DMA_TGT_IFM);
    wire [1:0]   lb_wr_line  = dma_ifm_row_r[1:0];     // bank = row mod 4
    wire [10:0]  lb_wr_addr  = dma_ifm_eir_r[10:0];
    wire [127:0] lb_wr_data  = asm_data;

    //----------------------------------------------------------------
    // ifm_line_buf
    //----------------------------------------------------------------
    wire         conv_ifm_re;
    wire [11:0]  conv_ifm_row, conv_ifm_col;
    wire [7:0]   conv_ifm_acc;
    wire [287:0] ifm_00, ifm_01, ifm_10, ifm_11;
    wire         ifm_vld;
    /* verilator lint_off UNUSED */
    wire _unused_ifm_vld = ifm_vld;
    /* verilator lint_on UNUSED */

    ifm_line_buf u_line_buf (
        .clk(clk), .rstn(rstn),
        .i_mode(1'b0),
        .i_w_blocks(cur_w_blocks),
        .i_ci_groups(cur_ci_grps),
        .i_w(cur_w),
        .i_h(cur_h),
        .i_line_valid(4'b1111),
        .i_dma_wr_en(lb_wr_en),
        .i_dma_wr_line(lb_wr_line),
        .i_dma_wr_addr(lb_wr_addr),
        .i_dma_wr_data(lb_wr_data),
        .i_rd_en(conv_ifm_re),
        .i_rb(conv_ifm_row), .i_cb(conv_ifm_col),
        .i_acc_cyc(conv_ifm_acc),
        .o_ifm_00(ifm_00), .o_ifm_01(ifm_01),
        .o_ifm_10(ifm_10), .o_ifm_11(ifm_11),
        .o_vld(ifm_vld)
    );

    //----------------------------------------------------------------
    // conv_top — (rb, fi) 단위 호출
    //
    //   매 호출:
    //     i_ofm_h_half = 1 (한 row 만 처리)
    //     i_co_total   = 1 (한 filter 만)
    //     i_row_start  = rb_r (현재 rb)
    //     i_wgt_base   = fi_r (acc_len=1 이므로 fi 가 곧 BRAM read entry)
    //     i_bias_base  = fi_r
    //   Output: 128 packed pixel → dpram[0..127]
    //----------------------------------------------------------------
    reg         conv_start;
    wire        conv_done;
    wire        conv_fil_done;       /* verilator lint_off UNUSED */ /* verilator lint_on UNUSED */
    wire [31:0] conv_pixel;
    wire        conv_pixel_vld;
    wire [25:0] conv_ofm_addr;
    /* verilator lint_off UNUSED */
    wire _unused_fil = conv_fil_done;
    /* verilator lint_on UNUSED */

    // conv_top 의 i_wgt_base = layer 별 READ entry base + fi × acc_len  (10-bit)
    //   L0: acc_len=1 → fi_r * 1 = fi_r,        base=0
    //   L2: acc_len=4 → fi_r * 4,               base=16
    wire [9:0]  conv_wgt_base  = cur_wgt_rd_entry_base +
                                 ((cur_acc_len == 8'd1) ? {5'd0, fi_r} :
                                  (cur_acc_len == 8'd4) ? {3'd0, fi_r, 2'd0} : 10'd0);
    wire [11:0] conv_bias_base = cur_bias_entry_base + {7'd0, fi_r};

    conv_top u_conv (
        .clk(clk), .rstn(rstn),
        .i_start(conv_start),
        .o_done(conv_done),
        .o_fil_done(conv_fil_done),
        .i_conv_pause(1'b0),
        .i_stream_wgt_mode(1'b0),
        .i_mode(1'b0),
        .i_ofm_w_half(cur_w_half),
        .i_ofm_h_half(12'd1),
        .i_row_start(rb_r),
        .i_co_total(12'd1),
        .i_acc_len(cur_acc_len),
        .i_wgt_base(conv_wgt_base),
        .i_bias_base(conv_bias_base),
        .i_shift(cur_shift),
        .dma_wgt_we(gbuff_wgt_we),     .dma_wgt_addr(gbuff_wgt_addr),     .dma_wgt_data(gbuff_wgt_data),
        .dma_bias_we(gbuff_bias_we),   .dma_bias_addr(gbuff_bias_addr),   .dma_bias_data(gbuff_bias_data),
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
    // OFM dpram — L0 conv 출력 + L1 입력/출력 공용 버퍼
    //
    //   Port A (write) 경로:
    //     - L0 conv: conv_pixel_vld → conv_ofm_addr, conv_pixel
    //     - L1 IFM load: dma_rd_data_vld @ DMA_TGT_L1_IFM → 0..16383 순차 기록
    //     - L1 pool: max_pool_unit 의 o_wr_* → 0..4095 (in-place overwrite)
    //
    //   Port B (read) 경로:
    //     - L0/L1 store: dma_wr_indata_req + dpram_store_addr_r → dma_wr_indata
    //     - L1 pool: max_pool_unit 의 o_rd_* → i_rd_data (1-cycle 지연)
    //----------------------------------------------------------------
    reg  [15:0] dpram_store_addr_r;        // DMA wr 가 dpram 에서 읽는 addr
    reg  [15:0] dpram_store_addr_init_r;   // FSM 이 dma_wr_start 직전에 set

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            dpram_store_addr_r <= 16'd0;
        end else begin
            if (dma_wr_start)              dpram_store_addr_r <= dpram_store_addr_init_r;
            else if (dma_wr_indata_req)    dpram_store_addr_r <= dpram_store_addr_r + 16'd1;
        end
    end

    //--------------------------------------------------------------
    // L1 IFM / REPACK DMA-load 카운터 (DMA rd_data → OFM dpram 직접 기록)
    //
    //   L1 IFM load: scratch_a 가 아닌 dpram[0..16383] 전역 사용 — base=0
    //   REPACK   load: scratch_a 의 ch_l 슬롯 — base = rp_chl_r * 32
    //--------------------------------------------------------------
    reg [15:0] l1_ifm_wr_addr_r;
    reg [15:0] dpram_load_addr_init_r;       // FSM 이 set: DMA 시작 직전
    wire       l1_ifm_we = dma_rd_data_vld && (dma_target_r == DMA_TGT_L1_IFM);

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            l1_ifm_wr_addr_r <= 16'd0;
        end else begin
            if (dma_rd_start && (dma_target_r == DMA_TGT_L1_IFM))
                l1_ifm_wr_addr_r <= dpram_load_addr_init_r;
            else if (l1_ifm_we)
                l1_ifm_wr_addr_r <= l1_ifm_wr_addr_r + 16'd1;
        end
    end

    //--------------------------------------------------------------
    // max_pool_unit (L1 전용)
    //--------------------------------------------------------------
    reg         pool_start_r;
    wire        pool_done;
    wire        pool_rd_en;
    wire [15:0] pool_rd_addr;
    wire        pool_wr_en;
    wire [15:0] pool_wr_addr;
    wire [31:0] pool_wr_data;

    wire [31:0] ofm_rd_data;

    max_pool_unit u_pool (
        .clk              (clk),
        .rstn             (rstn),
        .i_start          (pool_start_r),
        .o_done           (pool_done),
        .i_total_in_words (L1_IFM_WORDS_PER_FI),
        .o_rd_en          (pool_rd_en),
        .o_rd_addr        (pool_rd_addr),
        .i_rd_data        (ofm_rd_data),
        .o_wr_en          (pool_wr_en),
        .o_wr_addr        (pool_wr_addr),
        .o_wr_data        (pool_wr_data)
    );

    //--------------------------------------------------------------
    // REPACK transpose 엔진 (S_RP_GEN 단계 전용)
    //
    //   per col_b (0..31, 9 cycle):
    //     cycle 0: addr_b = scratch_a + 0*32 + col_b, en_b=1
    //     cycle 1: latch dout → ch_word[0], addr_b = +1*32 + col_b
    //     cycle 2: latch → ch_word[1], addr_b = +2*32 + col_b
    //     cycle 3: latch → ch_word[2], addr_b = +3*32 + col_b
    //     cycle 4: latch → ch_word[3]  (이 시점 4 channel word 모두 보유)
    //     cycle 5..8: write transposed out_word[col_l=0..3] → scratch_b[col_b*4 + col_l]
    //
    //   transposed out_word[col_l]: 4 byte = {ch3.byte[col_l], ch2, ch1, ch0}
    //
    //   col_b counter 32 회 → done.
    //--------------------------------------------------------------
    reg [4:0]  rp_gen_cb_r;     // 0..31 col_b
    reg [3:0]  rp_gen_phase_r;  // 0..8
    reg [31:0] ch_word_0_r, ch_word_1_r, ch_word_2_r, ch_word_3_r;
    reg        rp_gen_done_r;   // 1-cycle pulse when all 32 col_b processed

    wire rp_gen_phase = (state_r == S_RP_GEN);

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            rp_gen_cb_r    <= 5'd0;
            rp_gen_phase_r <= 4'd0;
            ch_word_0_r    <= 32'd0;
            ch_word_1_r    <= 32'd0;
            ch_word_2_r    <= 32'd0;
            ch_word_3_r    <= 32'd0;
            rp_gen_done_r  <= 1'b0;
        end else begin
            rp_gen_done_r <= 1'b0;
            if (state_r == S_RP_LOAD_WAIT && dma_rd_done) begin
                // REPACK Phase A 의 마지막 channel 적재 완료 → GEN 진입 준비
                if (rp_chl_r == 3'd3) begin
                    rp_gen_cb_r    <= 5'd0;
                    rp_gen_phase_r <= 4'd0;
                end
            end else if (rp_gen_phase) begin
                // phase 0..3 에서 dpram dout 1-cycle 지연 후 latch
                // ofm_rd_data 는 1 cycle 전 addr_b 의 결과
                case (rp_gen_phase_r)
                    4'd1: ch_word_0_r <= ofm_rd_data;
                    4'd2: ch_word_1_r <= ofm_rd_data;
                    4'd3: ch_word_2_r <= ofm_rd_data;
                    4'd4: ch_word_3_r <= ofm_rd_data;
                    default: ;
                endcase

                if (rp_gen_phase_r == 4'd8) begin
                    rp_gen_phase_r <= 4'd0;
                    if (rp_gen_cb_r == 5'd31) begin
                        rp_gen_done_r <= 1'b1;
                    end else begin
                        rp_gen_cb_r <= rp_gen_cb_r + 5'd1;
                    end
                end else begin
                    rp_gen_phase_r <= rp_gen_phase_r + 4'd1;
                end
            end
        end
    end

    // GEN 의 Port B read addr (phase 0..3) — scratch_a 의 ch_l × 32 + col_b
    //   ch_l = phase[1:0], col_b = cb_r[4:0]
    //   addr = {ch_l, col_b}  (총 7-bit, 16-bit zero-pad)
    wire [15:0] rp_gen_rd_addr = SCRATCH_A_BASE + {9'd0, rp_gen_phase_r[1:0], rp_gen_cb_r[4:0]};
    wire        rp_gen_rd_en   = rp_gen_phase && (rp_gen_phase_r <= 4'd3);

    // GEN 의 Port A write — phase 5..8 에서 transposed word 출력
    //   col_l = phase - 5  (0..3)
    //   addr  = SCRATCH_B_BASE + col_b*4 + col_l
    wire [1:0] rp_gen_col_l =
        (rp_gen_phase_r == 4'd5) ? 2'd0 :
        (rp_gen_phase_r == 4'd6) ? 2'd1 :
        (rp_gen_phase_r == 4'd7) ? 2'd2 :
        (rp_gen_phase_r == 4'd8) ? 2'd3 : 2'd0;

    wire [15:0] rp_gen_wr_addr = SCRATCH_B_BASE + {9'd0, rp_gen_cb_r[4:0], rp_gen_col_l};
    wire [31:0] rp_gen_wr_data = {
        ch_word_3_r[rp_gen_col_l*8 +: 8],
        ch_word_2_r[rp_gen_col_l*8 +: 8],
        ch_word_1_r[rp_gen_col_l*8 +: 8],
        ch_word_0_r[rp_gen_col_l*8 +: 8]
    };
    wire        rp_gen_wr_en   = rp_gen_phase && (rp_gen_phase_r >= 4'd5);

    //--------------------------------------------------------------
    // OFM dpram Port A/B mux
    //--------------------------------------------------------------
    wire pool_phase = (state_r == S_L1_FI_POOL_WAIT);

    wire        ofm_wr_en   = pool_phase    ? pool_wr_en :
                              rp_gen_wr_en  ? 1'b1       :
                              l1_ifm_we     ? 1'b1       :
                                              conv_pixel_vld;
    wire [15:0] ofm_wr_addr = pool_phase    ? pool_wr_addr :
                              rp_gen_wr_en  ? rp_gen_wr_addr :
                              l1_ifm_we     ? l1_ifm_wr_addr_r :
                                              conv_ofm_addr[15:0];
    wire [31:0] ofm_wr_data = pool_phase    ? pool_wr_data :
                              rp_gen_wr_en  ? rp_gen_wr_data :
                              l1_ifm_we     ? dma_rd_data  :
                                              conv_pixel;

    wire        ofm_rd_en   = pool_phase    ? pool_rd_en   :
                              rp_gen_rd_en  ? 1'b1         :
                                              dma_wr_indata_req;
    wire [15:0] ofm_rd_addr = pool_phase    ? pool_rd_addr :
                              rp_gen_rd_en  ? rp_gen_rd_addr :
                                              dpram_store_addr_r;

    assign dma_wr_indata = ofm_rd_data;

    dpram_wrapper #(.DW(32), .AW(16), .DEPTH(65536), .N_DELAY(1)) u_ofm (
        .clk   (clk),
        .ena   (ofm_wr_en),
        .addra (ofm_wr_addr),
        .wea   (ofm_wr_en),
        .dia   (ofm_wr_data),
        .enb   (ofm_rd_en),
        .addrb (ofm_rd_addr),
        .dob   (ofm_rd_data)
    );

    //----------------------------------------------------------------
    // DRAM 주소 계산
    //----------------------------------------------------------------
    // Weight base : L0 → dram_wgt_base, L2 → dram_wgt_base + 1024 byte
    wire [31:0] addr_wgt  = dram_wgt_base + (is_conv_l2 ? L2_WGT_BYTE_OFF : 32'd0);
    // Bias base   : dram_wgt_base + 0x00A00000 (+ L2 offset 64 byte)
    wire [31:0] addr_bias = dram_wgt_base + 32'h00A00000 +
                            (is_conv_l2 ? L2_BIAS_BYTE_OFF : 32'd0);

    // IFM row stride byte: L0=1024 (W*4ch=256*4), L2=2048 (128*16ch)
    //   ifm_first_row 는 ifm_first_row_for_rb 와 row stride 의 곱.
    //   row stride : L0=1024 (<<10), L2=2048 (<<11)
    wire [11:0] ifm_first_row_for_rb = (rb_r == 12'd0) ? 12'd0 : ({rb_r[10:0], 1'b0}) + 12'd1;
    wire [31:0] cur_ifm_base = is_conv_l2 ?
                               (dram_ofm_base + L2_IFM_BYTE_BASE) :
                               dram_ifm_base;
    wire [31:0] addr_ifm_byte = cur_ifm_base +
                                (is_conv_l2 ?
                                   ({20'd0, ifm_first_row_for_rb} << 11) :
                                   ({20'd0, ifm_first_row_for_rb} << 10));

    // OFM per (rb, fi):
    //   L0: ofm_base + fi*65536 + rb*512
    //     fi*16384 word (W_HALF^2=16384) × 4 byte/word = 65536 byte = fi << 16
    //     rb*128  word (W_HALF=128) × 4 = 512 byte = rb << 9
    //   L2: ofm_base + L2_OFM_BYTE_BASE + fi*16384 + rb*256
    //     fi*4096 word (W_HALF^2=4096) × 4 = 16384 byte = fi << 14
    //     rb*64   word (W_HALF=64) × 4 = 256 byte = rb << 8
    wire [31:0] addr_ofm_byte = is_conv_l2 ?
        (dram_ofm_base + L2_OFM_BYTE_BASE + ({13'd0, fi_r, 14'd0}) + ({18'd0, rb_r, 8'd0}))
      : (dram_ofm_base + ({11'd0, fi_r, 16'd0}) + ({16'd0, rb_r, 9'b0}));

    // L1 IFM (= L0 OFM[fi]) : dram_ofm_base + fi × 65536 byte
    wire [31:0] addr_l1_ifm_byte = dram_ofm_base + ({11'd0, fi_r} * L0_OFM_FI_BYTE);
    // L1 OFM[fi]            : dram_ofm_base + 1,048,576 + fi × 16384 byte
    wire [31:0] addr_l1_ofm_byte = dram_ofm_base + L1_OFM_BYTE_BASE + ({11'd0, fi_r} * L1_OFM_FI_BYTE);

    //----------------------------------------------------------------
    // REPACK 주소 (row r, ci_g, ch_l within group)
    //----------------------------------------------------------------
    reg [11:0] rp_row_r;     // 0..127
    reg [2:0]  rp_cig_r;     // 0..3 (ci_group)
    reg [2:0]  rp_chl_r;     // 0..3 (ch within group, Phase A load 시)

    // REPACK Load 주소: L1 OFM 의 (ch_full=cig*4+chl, row=rp_row, col=0..31) 한 row
    //   byte_addr = L1_OFM_BYTE_BASE + ch_full*16384 + rp_row*128
    wire [4:0]  rp_chfull = {rp_cig_r[1:0], rp_chl_r[1:0]};
    wire [31:0] addr_rp_load_byte =
        dram_ofm_base + L1_OFM_BYTE_BASE +
        ({11'd0, rp_chfull} * 32'd16384) +
        ({20'd0, rp_row_r} * L1_OFM_ROW_BYTE);

    // REPACK Store 주소: L2 IFM 의 (row=rp_row, ci_g=rp_cig, col_b=0..31)
    //   byte_addr = L2_IFM_BYTE_BASE + rp_row*2048 + rp_cig*512
    wire [31:0] addr_rp_store_byte =
        dram_ofm_base + L2_IFM_BYTE_BASE +
        ({20'd0, rp_row_r} * L2_IFM_ROW_BYTE) +
        ({29'd0, rp_cig_r} * L2_IFM_CIG_BYTE_PER_R);

    //----------------------------------------------------------------
    // Main FSM
    //
    //   All FSM-controlled registers (state_r, rb_r, fi_r, layer_idx,
    //   dma_target_r, dma_rd_*, dma_wr_*, conv_start, dma_ifm_row_start_r,
    //   network_done_r) updated only here.
    //----------------------------------------------------------------
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state_r                 <= S_IDLE;
            rb_r                    <= 12'd0;
            fi_r                    <= 5'd0;
            layer_idx               <= 5'd0;
            conv_phase_r            <= 5'd0;
            dma_target_r            <= DMA_TGT_NONE;
            dma_rd_start            <= 1'b0;
            dma_rd_num_trans        <= 20'd0;
            dma_rd_start_addr       <= 32'd0;
            dma_wr_start            <= 1'b0;
            dma_wr_num_trans        <= 20'd0;
            dma_wr_start_addr       <= 32'd0;
            dpram_store_addr_init_r <= 16'd0;
            dpram_load_addr_init_r  <= 16'd0;
            conv_start              <= 1'b0;
            pool_start_r            <= 1'b0;
            dma_ifm_row_start_r     <= 12'd0;
            rp_row_r                <= 12'd0;
            rp_cig_r                <= 3'd0;
            rp_chl_r                <= 3'd0;
            network_done_r          <= 1'b0;
        end else begin
            // 1-cycle pulse defaults
            dma_rd_start <= 1'b0;
            dma_wr_start <= 1'b0;
            conv_start   <= 1'b0;
            pool_start_r <= 1'b0;

            case (state_r)
                //------------------------------------------------
                S_IDLE: begin
                    if (ap_start) begin
                        rb_r            <= 12'd0;
                        fi_r            <= 5'd0;
                        layer_idx       <= 5'd0;
                        conv_phase_r    <= 5'd0;
                        network_done_r  <= 1'b0;
                        state_r         <= S_LOAD_WGT;
                    end
                end

                //------------------------------------------------
                S_LOAD_WGT: begin
                    dma_target_r      <= DMA_TGT_WGT;
                    dma_rd_num_trans  <= cur_wgt_dma;
                    dma_rd_start_addr <= addr_wgt;
                    dma_rd_start      <= 1'b1;
                    state_r           <= S_LOAD_WGT_WAIT;
                end
                S_LOAD_WGT_WAIT: begin
                    if (dma_rd_done) state_r <= S_LOAD_BIAS;
                end

                //------------------------------------------------
                S_LOAD_BIAS: begin
                    dma_target_r      <= DMA_TGT_BIAS;
                    dma_rd_num_trans  <= cur_bias_dma;
                    dma_rd_start_addr <= addr_bias;
                    dma_rd_start      <= 1'b1;
                    state_r           <= S_LOAD_BIAS_WAIT;
                end
                S_LOAD_BIAS_WAIT: begin
                    if (dma_rd_done) begin
                        rb_r    <= 12'd0;
                        state_r <= S_RB_DMA_IFM;
                    end
                end

                //------------------------------------------------
                S_RB_DMA_IFM: begin
                    dma_target_r        <= DMA_TGT_IFM;
                    dma_ifm_row_start_r <= ifm_first_row_for_rb;
                    dma_rd_num_trans    <= (rb_r == 12'd0) ? cur_ifm_init : cur_ifm_next;
                    dma_rd_start_addr   <= addr_ifm_byte;
                    dma_rd_start        <= 1'b1;
                    state_r             <= S_RB_DMA_IFM_WAIT;
                end
                S_RB_DMA_IFM_WAIT: begin
                    if (dma_rd_done) begin
                        fi_r    <= 5'd0;
                        state_r <= S_FIL_CONV_START;
                    end
                end

                //------------------------------------------------
                S_FIL_CONV_START: begin
                    conv_start <= 1'b1;
                    state_r    <= S_FIL_CONV_WAIT;
                end
                S_FIL_CONV_WAIT: begin
                    if (conv_done) state_r <= S_FIL_DMA_STORE;
                end

                //------------------------------------------------
                S_FIL_DMA_STORE: begin
                    dma_wr_num_trans        <= cur_ofm_fil;
                    dma_wr_start_addr       <= addr_ofm_byte;
                    dpram_store_addr_init_r <= 16'd0;
                    dma_wr_start            <= 1'b1;
                    state_r                 <= S_FIL_DMA_STORE_WAIT;
                end
                S_FIL_DMA_STORE_WAIT: begin
                    if (dma_wr_done) begin
                        if (fi_r == cur_co[4:0] - 5'd1) begin
                            state_r <= S_RB_NEXT;
                        end else begin
                            fi_r    <= fi_r + 5'd1;
                            state_r <= S_FIL_CONV_START;
                        end
                    end
                end

                //------------------------------------------------
                S_RB_NEXT: begin
                    if (rb_r == cur_h_half - 12'd1) begin
                        state_r <= S_CONV_DONE;
                    end else begin
                        rb_r    <= rb_r + 12'd1;
                        state_r <= S_RB_DMA_IFM;
                    end
                end

                //------------------------------------------------
                // Conv 완료 → 다음 phase 분기
                //   L0 (conv_phase_r=0) 완료 → L1 진입
                //   L2 (conv_phase_r=2) 완료 → 최종 종료
                //------------------------------------------------
                S_CONV_DONE: begin
                    if (conv_phase_r == 5'd0) begin
                        layer_idx    <= 5'd1;
                        fi_r         <= 5'd0;
                        dma_target_r <= DMA_TGT_NONE;
                        state_r      <= S_L1_FI_LOAD;
                    end else begin
                        // conv_phase_r == 5'd2 → L2 완료
                        layer_idx      <= 5'd3;
                        network_done_r <= 1'b1;
                        state_r        <= S_DONE;
                    end
                end

                //------------------------------------------------
                // L1 : POOL_S2 — fi 별 (load → pool → store)
                //------------------------------------------------
                S_L1_FI_LOAD: begin
                    dma_target_r           <= DMA_TGT_L1_IFM;
                    dpram_load_addr_init_r <= 16'd0;
                    dma_rd_num_trans       <= L1_IFM_WORDS_PER_FI;     // 16,384 word
                    dma_rd_start_addr      <= addr_l1_ifm_byte;
                    dma_rd_start           <= 1'b1;
                    state_r                <= S_L1_FI_LOAD_WAIT;
                end
                S_L1_FI_LOAD_WAIT: begin
                    if (dma_rd_done) state_r <= S_L1_FI_POOL;
                end

                S_L1_FI_POOL: begin
                    pool_start_r <= 1'b1;
                    state_r      <= S_L1_FI_POOL_WAIT;
                end
                S_L1_FI_POOL_WAIT: begin
                    if (pool_done) state_r <= S_L1_FI_STORE;
                end

                S_L1_FI_STORE: begin
                    dma_wr_num_trans        <= L1_OFM_WORDS_PER_FI;     // 4,096 word
                    dma_wr_start_addr       <= addr_l1_ofm_byte;
                    dpram_store_addr_init_r <= 16'd0;
                    dma_wr_start            <= 1'b1;
                    state_r                 <= S_L1_FI_STORE_WAIT;
                end
                S_L1_FI_STORE_WAIT: begin
                    if (dma_wr_done) state_r <= S_L1_NEXT_FI;
                end

                S_L1_NEXT_FI: begin
                    if (fi_r == L1_CO - 5'd1) begin
                        // L1 완료 → REPACK 진입
                        layer_idx <= 5'd2;
                        rp_row_r  <= 12'd0;
                        rp_cig_r  <= 3'd0;
                        rp_chl_r  <= 3'd0;
                        state_r   <= S_RP_LOAD;
                    end else begin
                        fi_r    <= fi_r + 5'd1;
                        state_r <= S_L1_FI_LOAD;
                    end
                end

                //------------------------------------------------
                // REPACK : per (row, ci_g, ch_l) channel row → scratch_a
                //   ch_l 0..3 적재 후 GEN → STORE → 다음 ci_g
                //   ci_g 0..3 처리 후 → 다음 row
                //------------------------------------------------
                S_RP_LOAD: begin
                    dma_target_r           <= DMA_TGT_L1_IFM;
                    dpram_load_addr_init_r <= ({11'd0, rp_chl_r[1:0]} << 5);   // ch_l*32
                    dma_rd_num_trans       <= REPACK_LOAD_WORDS_PER_BURST;
                    dma_rd_start_addr      <= addr_rp_load_byte;
                    dma_rd_start           <= 1'b1;
                    state_r                <= S_RP_LOAD_WAIT;
                end
                S_RP_LOAD_WAIT: begin
                    if (dma_rd_done) begin
                        if (rp_chl_r == 3'd3) begin
                            // 4 channel 적재 완료 → GEN
                            rp_chl_r <= 3'd0;
                            state_r  <= S_RP_GEN;
                        end else begin
                            rp_chl_r <= rp_chl_r + 3'd1;
                            state_r  <= S_RP_LOAD;
                        end
                    end
                end

                S_RP_GEN: begin
                    // GEN 카운터 자동 진행. 완료 신호 rp_gen_done_r 를 대기.
                    if (rp_gen_done_r) state_r <= S_RP_STORE;
                end

                S_RP_STORE: begin
                    dma_wr_num_trans        <= REPACK_STORE_WORDS_PER_CIG;   // 128 word
                    dma_wr_start_addr       <= addr_rp_store_byte;
                    dpram_store_addr_init_r <= SCRATCH_B_BASE;
                    dma_wr_start            <= 1'b1;
                    state_r                 <= S_RP_STORE_WAIT;
                end
                S_RP_STORE_WAIT: begin
                    if (dma_wr_done) state_r <= S_RP_NEXT_CIG;
                end

                S_RP_NEXT_CIG: begin
                    if (rp_cig_r == 3'd3) begin
                        rp_cig_r <= 3'd0;
                        if (rp_row_r == 12'd127) begin
                            // REPACK 완료 → L2 진입
                            conv_phase_r <= 5'd2;
                            rb_r         <= 12'd0;
                            fi_r         <= 5'd0;
                            state_r      <= S_LOAD_WGT;
                        end else begin
                            rp_row_r <= rp_row_r + 12'd1;
                            state_r  <= S_RP_LOAD;
                        end
                    end else begin
                        rp_cig_r <= rp_cig_r + 3'd1;
                        state_r  <= S_RP_LOAD;
                    end
                end

                //------------------------------------------------
                S_DONE: begin
                    network_done_r <= 1'b1;
                    if (!ap_start) state_r <= S_IDLE;
                end

                default: state_r <= S_IDLE;
            endcase
        end
    end

    //----------------------------------------------------------------
    // gbuff_param
    //----------------------------------------------------------------
    // conv_top 이 자체적으로 인스턴스화하므로 여기서 별도 필요 없음.
    // (conv_top.v 내부에 gbuff_param u_gbuff 인스턴스 있음)

endmodule
