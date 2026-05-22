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

    // ── Streaming weight 모드 (L0/L2 공용) ──────────────────────────
    //   weight 는 layer 시작에 한번 적재하지 않고, 매 filter 마다 fresh DMA.
    //   - per-filter DMA 양: acc_len × 16 word (acc_len blocks × 4 word/slot × 4 slot/block)
    //     L0 (acc_len=1): 16 word
    //     L2 (acc_len=4): 64 word
    //   - BRAM 의 wgt write 시작 entry: 항상 0 (모든 layer/filter 공유)
    //   - conv_top.i_wgt_base = 0 (stream 모드)
    //   - conv_top.i_stream_wgt_mode = 1 (filter 전환 시 wgt_base 동결)
    //
    //   L2 bias / IFM / OFM DMA 사이즈는 non-streaming 시와 동일.
    localparam [19:0] L2_BIAS_DMA_WORDS = 20'd32;
    localparam [19:0] L2_IFM_INIT_WORDS = 20'd1536;
    localparam [19:0] L2_IFM_NEXT_WORDS = 20'd1024;
    localparam [19:0] L2_OFM_FIL_WORDS  = 20'd64;

    // L2 weight 시작 위치 (DRAM 기준): gen_sim_dram.py 의 blk_off=16
    //   byte offset = 16 × 64 = 1024
    localparam [31:0] L2_WGT_BYTE_OFF  = 32'd1024;
    // L2 bias 시작 위치 (L0 의 16 filter 뒤): byte 16 × 4 = 64
    localparam [31:0] L2_BIAS_BYTE_OFF = 32'd64;
    // L2 OFM DRAM byte base (offset from dram_ofm_base)
    localparam [31:0] L2_OFM_BYTE_BASE = 32'h00180000;
    // L2 bias BRAM entry base (L0 의 16 filter 뒤)
    localparam [11:0] L2_BIAS_ENTRY_BASE = 12'd16;

    // 공통: per-filter weight DMA word count = acc_len × 16
    //   acc_len=1 → 16 word, acc_len=4 → 64 word
    // 공통: per-filter weight 바이트 stride = acc_len × 64
    localparam [19:0] L0_WGT_PER_FI_WORDS = 20'd16;    // = 1 × 16
    localparam [19:0] L2_WGT_PER_FI_WORDS = 20'd64;    // = 4 × 16
    localparam [19:0] L4_WGT_PER_FI_WORDS = 20'd128;   // = 8 × 16
    localparam [31:0] L0_WGT_PER_FI_BYTES = 32'd64;    // = 16 × 4
    localparam [31:0] L2_WGT_PER_FI_BYTES = 32'd256;   // = 64 × 4
    localparam [31:0] L4_WGT_PER_FI_BYTES = 32'd512;   // = 128 × 4

    //----------------------------------------------------------------
    // L3 constants (POOL_S2, 32ch, 128 → 64)
    //----------------------------------------------------------------
    localparam [5:0]  L3_CO              = 6'd32;
    localparam [19:0] L3_IFM_WORDS_PER_FI = 20'd4096;   // 128×128/4 word per fi
    localparam [19:0] L3_OFM_WORDS_PER_FI = 20'd1024;   // 64×64/4 word per fi
    localparam [31:0] L3_OFM_BYTE_BASE    = 32'h00200000;
    localparam [31:0] L2_OFM_FI_BYTE      = 32'd16384;   // L2 OFM per-fi byte stride (= 4096 word × 4)
    localparam [31:0] L3_OFM_FI_BYTE      = 32'd4096;    // L3 OFM per-fi byte stride

    //----------------------------------------------------------------
    // L4 constants (CONV3x3, Ci=32, Co=64, 64×64 → 64×64)
    //----------------------------------------------------------------
    localparam [11:0] L4_W        = 12'd64;
    localparam [11:0] L4_H        = 12'd64;
    localparam [11:0] L4_W_HALF   = 12'd32;
    localparam [11:0] L4_H_HALF   = 12'd32;
    localparam [11:0] L4_W_BLOCKS = 12'd16;
    localparam [11:0] L4_CO       = 12'd64;
    localparam [7:0]  L4_ACC_LEN  = 8'd8;
    localparam [4:0]  L4_SHIFT    = 5'd6;       // scale 0x40 = 64
    localparam [7:0]  L4_CI_GRPS  = 8'd8;
    localparam [11:0] L4_EIR_PER_ROW = 12'd128; // 16 × 8 = same as L2!

    localparam [19:0] L4_BIAS_DMA_WORDS = 20'd64;
    localparam [19:0] L4_IFM_INIT_WORDS = 20'd1536;     // 3 × 16 × 8 × 4 (= same 형식)
    localparam [19:0] L4_IFM_NEXT_WORDS = 20'd1024;
    localparam [19:0] L4_OFM_FIL_WORDS  = 20'd32;       // W_HALF = 32

    // L4 weight 시작 위치: blk_off=144 (gen_sim_dram.py) → byte = 144 × 64 = 9216
    localparam [31:0] L4_WGT_BYTE_OFF  = 32'd9216;
    // L4 bias 시작 위치: L0(16) + L2(32) = 48 → byte 48 × 4 = 192
    localparam [31:0] L4_BIAS_BYTE_OFF = 32'd192;
    localparam [31:0] L4_OFM_BYTE_BASE = 32'h00240000;
    localparam [11:0] L4_BIAS_ENTRY_BASE = 12'd48;
    localparam [31:0] L4_IFM_BYTE_BASE = 32'h00220000;   // REPACK 결과

    //----------------------------------------------------------------
    // L5 constants (POOL_S2, 64ch, 64 → 32)
    //----------------------------------------------------------------
    localparam [6:0]  L5_CO              = 7'd64;
    localparam [19:0] L5_IFM_WORDS_PER_FI = 20'd1024;   // 64×64/4
    localparam [19:0] L5_OFM_WORDS_PER_FI = 20'd256;    // 32×32/4
    localparam [31:0] L5_OFM_BYTE_BASE    = 32'h00280000;
    localparam [31:0] L4_OFM_FI_BYTE      = 32'd4096;    // L4 OFM per-fi byte stride
    localparam [31:0] L5_OFM_FI_BYTE      = 32'd1024;    // L5 OFM per-fi byte stride

    //----------------------------------------------------------------
    // REPACK L3→L4 constants
    //   L3 OFM (chan-major) → L4 IFM (NHWC packed)
    //   - per ch per row: 16 word = 64 byte
    //   - per row total entries: 16 col_b × 8 ci_g = 128 (same as L2!)
    //   - per row total bytes: 2048 (same as L2)
    //   - per ci_g entry bytes: 16 col_b × 16 byte = 256
    //----------------------------------------------------------------
    localparam [31:0] L3_OFM_ROW_BYTE        = 32'd64;     // 16 word × 4 byte (per ch per row)
    localparam [31:0] L4_IFM_ROW_BYTE        = 32'd2048;
    localparam [31:0] L4_IFM_CIG_BYTE_PER_R  = 32'd256;    // 16 entry × 16 byte
    localparam [19:0] L4_RP_LOAD_WORDS_PER_BURST = 20'd16; // 1 ch × 1 row = 16 word
    localparam [19:0] L4_RP_STORE_WORDS_PER_CIG  = 20'd64; // 16 entry × 4 word

    //----------------------------------------------------------------
    // L6, L7, L8, L9, L10 constants (라우팅 이전, 같은 패턴 반복)
    //
    //   per-row IFM byte = W × Ci  → 모두 2048 byte/row (W*Ci 가 상수)
    //   per-row line_buf entries = W_BLK × ci_groups = 128 (역시 상수)
    //   conv shift = 6 (scale 0x40 = 64) — L2 이후 모든 layer 동일
    //----------------------------------------------------------------

    // L6 (CONV3x3, Ci=64, Co=128, 32×32)
    localparam [11:0] L6_W = 12'd32, L6_H = 12'd32;
    localparam [11:0] L6_W_HALF = 12'd16, L6_H_HALF = 12'd16;
    localparam [11:0] L6_W_BLOCKS = 12'd8;
    localparam [11:0] L6_CO = 12'd128;
    localparam [7:0]  L6_ACC_LEN = 8'd16;
    localparam [4:0]  L6_SHIFT = 5'd6;
    localparam [7:0]  L6_CI_GRPS = 8'd16;
    localparam [11:0] L6_EIR_PER_ROW = 12'd128;
    localparam [19:0] L6_BIAS_DMA_WORDS = 20'd128;
    localparam [19:0] L6_IFM_INIT_WORDS = 20'd1536;
    localparam [19:0] L6_IFM_NEXT_WORDS = 20'd1024;
    localparam [19:0] L6_OFM_FIL_WORDS  = 20'd16;
    localparam [31:0] L6_WGT_BYTE_OFF  = 32'd41984;     // blk_off=656 × 64
    localparam [31:0] L6_BIAS_BYTE_OFF = 32'd448;       // bias_off=112 × 4
    localparam [31:0] L6_OFM_BYTE_BASE = 32'h002A0000;
    localparam [31:0] L6_IFM_BYTE_BASE = 32'h00290000;
    localparam [11:0] L6_BIAS_ENTRY_BASE = 12'd112;
    localparam [19:0] L6_WGT_PER_FI_WORDS = 20'd256;    // = 16 × 16
    localparam [31:0] L6_WGT_PER_FI_BYTES = 32'd1024;

    // L7 (POOL_S2, 128ch, 32 → 16)
    localparam [7:0]  L7_CO              = 8'd128;
    localparam [19:0] L7_IFM_WORDS_PER_FI = 20'd256;    // 32×32/4
    localparam [19:0] L7_OFM_WORDS_PER_FI = 20'd64;     // 16×16/4
    localparam [31:0] L7_OFM_BYTE_BASE    = 32'h002C0000;
    localparam [31:0] L6_OFM_FI_BYTE      = 32'd1024;   // 32×32
    localparam [31:0] L7_OFM_FI_BYTE      = 32'd256;    // 16×16

    // L8 (CONV3x3, Ci=128, Co=256, 16×16)
    localparam [11:0] L8_W = 12'd16, L8_H = 12'd16;
    localparam [11:0] L8_W_HALF = 12'd8, L8_H_HALF = 12'd8;
    localparam [11:0] L8_W_BLOCKS = 12'd4;
    localparam [11:0] L8_CO = 12'd256;
    localparam [7:0]  L8_ACC_LEN = 8'd32;
    localparam [4:0]  L8_SHIFT = 5'd6;
    localparam [7:0]  L8_CI_GRPS = 8'd32;
    localparam [11:0] L8_EIR_PER_ROW = 12'd128;
    localparam [19:0] L8_BIAS_DMA_WORDS = 20'd256;
    localparam [19:0] L8_IFM_INIT_WORDS = 20'd1536;
    localparam [19:0] L8_IFM_NEXT_WORDS = 20'd1024;
    localparam [19:0] L8_OFM_FIL_WORDS  = 20'd8;
    localparam [31:0] L8_WGT_BYTE_OFF  = 32'd173056;    // blk_off=2704 × 64
    localparam [31:0] L8_BIAS_BYTE_OFF = 32'd960;       // bias_off=240 × 4
    localparam [31:0] L8_OFM_BYTE_BASE = 32'h002D0000;
    localparam [31:0] L8_IFM_BYTE_BASE = 32'h002C8000;
    localparam [11:0] L8_BIAS_ENTRY_BASE = 12'd240;
    localparam [19:0] L8_WGT_PER_FI_WORDS = 20'd512;    // = 32 × 16
    localparam [31:0] L8_WGT_PER_FI_BYTES = 32'd2048;

    // L9 (POOL_S2, 256ch, 16 → 8)
    localparam [8:0]  L9_CO              = 9'd256;
    localparam [19:0] L9_IFM_WORDS_PER_FI = 20'd64;     // 16×16/4
    localparam [19:0] L9_OFM_WORDS_PER_FI = 20'd16;     // 8×8/4
    localparam [31:0] L9_OFM_BYTE_BASE    = 32'h002E0000;
    localparam [31:0] L8_OFM_FI_BYTE      = 32'd256;    // 16×16
    localparam [31:0] L9_OFM_FI_BYTE      = 32'd64;     // 8×8

    // L10 (CONV3x3, Ci=256, Co=512, 8×8)
    localparam [11:0] L10_W = 12'd8, L10_H = 12'd8;
    localparam [11:0] L10_W_HALF = 12'd4, L10_H_HALF = 12'd4;
    localparam [11:0] L10_W_BLOCKS = 12'd2;
    localparam [11:0] L10_CO = 12'd512;
    localparam [7:0]  L10_ACC_LEN = 8'd64;
    localparam [4:0]  L10_SHIFT = 5'd6;
    localparam [7:0]  L10_CI_GRPS = 8'd64;
    localparam [11:0] L10_EIR_PER_ROW = 12'd128;
    localparam [19:0] L10_BIAS_DMA_WORDS = 20'd512;
    localparam [19:0] L10_IFM_INIT_WORDS = 20'd1536;
    localparam [19:0] L10_IFM_NEXT_WORDS = 20'd1024;
    localparam [19:0] L10_OFM_FIL_WORDS  = 20'd4;
    localparam [31:0] L10_WGT_BYTE_OFF  = 32'd697344;   // blk_off=10896 × 64
    localparam [31:0] L10_BIAS_BYTE_OFF = 32'd1984;     // bias_off=496 × 4
    localparam [31:0] L10_OFM_BYTE_BASE = 32'h002E8000;
    localparam [31:0] L10_IFM_BYTE_BASE = 32'h002E4000;
    localparam [11:0] L10_BIAS_ENTRY_BASE = 12'd496;
    localparam [19:0] L10_WGT_PER_FI_WORDS = 20'd1024;  // = 64 × 16
    localparam [31:0] L10_WGT_PER_FI_BYTES = 32'd4096;

    //----------------------------------------------------------------
    // REPACK L5→L6, L7→L8, L9→L10 constants
    //----------------------------------------------------------------
    // L5→L6: W_BLK=8, ci_g=16, per ch row = 32 byte (8 word × 4)
    localparam [31:0] L5_OFM_ROW_BYTE        = 32'd32;
    localparam [31:0] L6_IFM_ROW_BYTE        = 32'd2048;
    localparam [31:0] L6_IFM_CIG_BYTE_PER_R  = 32'd128;    // 8 entry × 16 byte
    localparam [19:0] L6_RP_LOAD_WORDS_PER_BURST = 20'd8;
    localparam [19:0] L6_RP_STORE_WORDS_PER_CIG  = 20'd32; // 8 entry × 4 word

    // L7→L8: W_BLK=4, ci_g=32, per ch row = 16 byte
    localparam [31:0] L7_OFM_ROW_BYTE        = 32'd16;
    localparam [31:0] L8_IFM_ROW_BYTE        = 32'd2048;
    localparam [31:0] L8_IFM_CIG_BYTE_PER_R  = 32'd64;     // 4 entry × 16 byte
    localparam [19:0] L8_RP_LOAD_WORDS_PER_BURST = 20'd4;
    localparam [19:0] L8_RP_STORE_WORDS_PER_CIG  = 20'd16; // 4 entry × 4 word

    // L9→L10: W_BLK=2, ci_g=64, per ch row = 8 byte
    localparam [31:0] L9_OFM_ROW_BYTE        = 32'd8;
    localparam [31:0] L10_IFM_ROW_BYTE       = 32'd2048;
    localparam [31:0] L10_IFM_CIG_BYTE_PER_R = 32'd32;     // 2 entry × 16 byte
    localparam [19:0] L10_RP_LOAD_WORDS_PER_BURST = 20'd2;
    localparam [19:0] L10_RP_STORE_WORDS_PER_CIG  = 20'd8; // 2 entry × 4 word

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
    //   0 = L0 (conv) active
    //   1 = L0 done / L1 (pool) active
    //   2 = L1 done / REPACK L1→L2 / L2 (conv) active
    //   3 = L2 done / L3 (pool) active
    //   4 = L3 done / REPACK L3→L4 / L4 (conv) active
    //   5 = L4 done / L5 (pool) active
    //   6 = L5 done (network end for this batch)
    //----------------------------------------------------------------
    reg [4:0] layer_idx;

    //----------------------------------------------------------------
    // FSM 상태 (streaming weight 모드)
    //   weight 는 매 filter 직전에 per-fi DMA. bias 만 layer 시작 시 일괄.
    //
    //   0       : S_IDLE
    //   1..2    : S_LOAD_BIAS / WAIT  (layer 시작 시 한 번)
    //   3..4    : S_RB_DMA_IFM / WAIT (per rb)
    //   5..6    : S_FI_LOAD_WGT / WAIT (per fi — streaming)
    //   7..8    : S_FIL_CONV_START / WAIT
    //   9..10   : S_FIL_DMA_STORE / WAIT
    //   11      : S_RB_NEXT  (fi loop 끝 후 rb++)
    //   12      : S_CONV_DONE
    //   13..19  : L1 (POOL_S2)
    //   20..25  : REPACK
    //   28      : S_DONE
    //----------------------------------------------------------------
    localparam S_IDLE              = 5'd0,
               S_LOAD_BIAS         = 5'd1,
               S_LOAD_BIAS_WAIT    = 5'd2,
               S_RB_DMA_IFM        = 5'd3,
               S_RB_DMA_IFM_WAIT   = 5'd4,
               S_FI_LOAD_WGT       = 5'd5,    // per-fi weight DMA
               S_FI_LOAD_WGT_WAIT  = 5'd6,
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
               S_RP_LOAD           = 5'd20,
               S_RP_LOAD_WAIT      = 5'd21,
               S_RP_GEN            = 5'd22,
               S_RP_STORE          = 5'd23,
               S_RP_STORE_WAIT     = 5'd24,
               S_RP_NEXT_CIG       = 5'd25,
               S_DONE              = 5'd28;

    reg [4:0]  state_r;
    reg [11:0] rb_r;       // 0..127 (L0) / 0..63 (L2/L4) / ...
    reg [11:0] fi_r;       // 0..63 (L5) / 0..255 (L8) / ... — full width

    //----------------------------------------------------------------
    // conv_phase_r — 현재 conv FSM 이 누구를 처리하는지 (L0/L2/L4/L6/L8/L10)
    //----------------------------------------------------------------
    reg [4:0] conv_phase_r;
    wire is_conv_l0  = (conv_phase_r == 5'd0);
    wire is_conv_l2  = (conv_phase_r == 5'd2);
    wire is_conv_l4  = (conv_phase_r == 5'd4);
    wire is_conv_l6  = (conv_phase_r == 5'd6);
    wire is_conv_l8  = (conv_phase_r == 5'd8);
    wire is_conv_l10 = (conv_phase_r == 5'd10);

    //----------------------------------------------------------------
    // pool_phase_r — 현재 pool FSM (L1/L3/L5/L7/L9)
    //----------------------------------------------------------------
    reg [4:0] pool_phase_r;
    wire is_pool_l1 = (pool_phase_r == 5'd1);
    wire is_pool_l3 = (pool_phase_r == 5'd3);
    wire is_pool_l5 = (pool_phase_r == 5'd5);
    wire is_pool_l7 = (pool_phase_r == 5'd7);
    wire is_pool_l9 = (pool_phase_r == 5'd9);

    //----------------------------------------------------------------
    // conv 파라미터 mux
    //----------------------------------------------------------------
    wire [11:0] cur_w_blocks   = is_conv_l10 ? L10_W_BLOCKS : is_conv_l8 ? L8_W_BLOCKS : is_conv_l6 ? L6_W_BLOCKS : is_conv_l4 ? L4_W_BLOCKS : is_conv_l2 ? L2_W_BLOCKS : L0_W_BLOCKS;
    wire [11:0] cur_w          = is_conv_l10 ? L10_W       : is_conv_l8 ? L8_W       : is_conv_l6 ? L6_W       : is_conv_l4 ? L4_W       : is_conv_l2 ? L2_W       : L0_W;
    wire [11:0] cur_h          = is_conv_l10 ? L10_H       : is_conv_l8 ? L8_H       : is_conv_l6 ? L6_H       : is_conv_l4 ? L4_H       : is_conv_l2 ? L2_H       : L0_H;
    wire [11:0] cur_w_half     = is_conv_l10 ? L10_W_HALF  : is_conv_l8 ? L8_W_HALF  : is_conv_l6 ? L6_W_HALF  : is_conv_l4 ? L4_W_HALF  : is_conv_l2 ? L2_W_HALF  : L0_W_HALF;
    wire [11:0] cur_h_half     = is_conv_l10 ? L10_H_HALF  : is_conv_l8 ? L8_H_HALF  : is_conv_l6 ? L6_H_HALF  : is_conv_l4 ? L4_H_HALF  : is_conv_l2 ? L2_H_HALF  : L0_H_HALF;
    wire [11:0] cur_co         = is_conv_l10 ? L10_CO      : is_conv_l8 ? L8_CO      : is_conv_l6 ? L6_CO      : is_conv_l4 ? L4_CO      : is_conv_l2 ? L2_CO      : L0_CO;
    wire [7:0]  cur_acc_len    = is_conv_l10 ? L10_ACC_LEN : is_conv_l8 ? L8_ACC_LEN : is_conv_l6 ? L6_ACC_LEN : is_conv_l4 ? L4_ACC_LEN : is_conv_l2 ? L2_ACC_LEN : L0_ACC_LEN;
    wire [4:0]  cur_shift      = is_conv_l10 ? L10_SHIFT   : is_conv_l8 ? L8_SHIFT   : is_conv_l6 ? L6_SHIFT   : is_conv_l4 ? L4_SHIFT   : is_conv_l2 ? L2_SHIFT   : L0_SHIFT;
    wire [7:0]  cur_ci_grps    = is_conv_l10 ? L10_CI_GRPS : is_conv_l8 ? L8_CI_GRPS : is_conv_l6 ? L6_CI_GRPS : is_conv_l4 ? L4_CI_GRPS : is_conv_l2 ? L2_CI_GRPS : L0_CI_GRPS;
    wire [11:0] cur_eir_per_row= is_conv_l10 ? L10_EIR_PER_ROW : is_conv_l8 ? L8_EIR_PER_ROW : is_conv_l6 ? L6_EIR_PER_ROW : is_conv_l4 ? L4_EIR_PER_ROW : is_conv_l2 ? L2_EIR_PER_ROW : L0_W_BLOCKS;

    // per-filter weight DMA size (streaming): acc_len 에 의존
    wire [19:0] cur_wgt_per_fi_words = is_conv_l10 ? L10_WGT_PER_FI_WORDS : is_conv_l8 ? L8_WGT_PER_FI_WORDS : is_conv_l6 ? L6_WGT_PER_FI_WORDS : is_conv_l4 ? L4_WGT_PER_FI_WORDS : is_conv_l2 ? L2_WGT_PER_FI_WORDS : L0_WGT_PER_FI_WORDS;
    wire [31:0] cur_wgt_per_fi_bytes = is_conv_l10 ? L10_WGT_PER_FI_BYTES : is_conv_l8 ? L8_WGT_PER_FI_BYTES : is_conv_l6 ? L6_WGT_PER_FI_BYTES : is_conv_l4 ? L4_WGT_PER_FI_BYTES : is_conv_l2 ? L2_WGT_PER_FI_BYTES : L0_WGT_PER_FI_BYTES;
    // 다른 DMA word count (per layer, 1 회)
    wire [19:0] cur_bias_dma   = is_conv_l10 ? L10_BIAS_DMA_WORDS : is_conv_l8 ? L8_BIAS_DMA_WORDS : is_conv_l6 ? L6_BIAS_DMA_WORDS : is_conv_l4 ? L4_BIAS_DMA_WORDS : is_conv_l2 ? L2_BIAS_DMA_WORDS : BIAS_DMA_WORDS;
    wire [19:0] cur_ifm_init   = is_conv_l10 ? L10_IFM_INIT_WORDS : is_conv_l8 ? L8_IFM_INIT_WORDS : is_conv_l6 ? L6_IFM_INIT_WORDS : is_conv_l4 ? L4_IFM_INIT_WORDS : is_conv_l2 ? L2_IFM_INIT_WORDS : IFM_INIT_WORDS;
    wire [19:0] cur_ifm_next   = is_conv_l10 ? L10_IFM_NEXT_WORDS : is_conv_l8 ? L8_IFM_NEXT_WORDS : is_conv_l6 ? L6_IFM_NEXT_WORDS : is_conv_l4 ? L4_IFM_NEXT_WORDS : is_conv_l2 ? L2_IFM_NEXT_WORDS : IFM_NEXT_WORDS;
    wire [19:0] cur_ofm_fil    = is_conv_l10 ? L10_OFM_FIL_WORDS  : is_conv_l8 ? L8_OFM_FIL_WORDS  : is_conv_l6 ? L6_OFM_FIL_WORDS  : is_conv_l4 ? L4_OFM_FIL_WORDS  : is_conv_l2 ? L2_OFM_FIL_WORDS  : OFM_FIL_WORDS;

    // BRAM bias entry base (wgt 는 streaming 으로 항상 0 사용)
    wire [11:0] cur_bias_entry_base = is_conv_l10 ? L10_BIAS_ENTRY_BASE :
                                      is_conv_l8  ? L8_BIAS_ENTRY_BASE  :
                                      is_conv_l6  ? L6_BIAS_ENTRY_BASE  :
                                      is_conv_l4  ? L4_BIAS_ENTRY_BASE  :
                                      is_conv_l2  ? L2_BIAS_ENTRY_BASE  : 12'd0;

    //----------------------------------------------------------------
    // pool 파라미터 mux
    //----------------------------------------------------------------
    wire [9:0]  cur_pool_co            = is_pool_l9 ? L9_CO :
                                         is_pool_l7 ? {2'd0, L7_CO} :
                                         is_pool_l5 ? {3'd0, L5_CO} :
                                         is_pool_l3 ? {4'd0, L3_CO} : {5'd0, L1_CO};
    wire [19:0] cur_pool_ifm_per_fi    = is_pool_l9 ? L9_IFM_WORDS_PER_FI :
                                         is_pool_l7 ? L7_IFM_WORDS_PER_FI :
                                         is_pool_l5 ? L5_IFM_WORDS_PER_FI :
                                         is_pool_l3 ? L3_IFM_WORDS_PER_FI : L1_IFM_WORDS_PER_FI;
    wire [19:0] cur_pool_ofm_per_fi    = is_pool_l9 ? L9_OFM_WORDS_PER_FI :
                                         is_pool_l7 ? L7_OFM_WORDS_PER_FI :
                                         is_pool_l5 ? L5_OFM_WORDS_PER_FI :
                                         is_pool_l3 ? L3_OFM_WORDS_PER_FI : L1_OFM_WORDS_PER_FI;
    wire [31:0] cur_pool_ifm_base_byte = is_pool_l9 ? L8_OFM_BYTE_BASE :
                                         is_pool_l7 ? L6_OFM_BYTE_BASE :
                                         is_pool_l5 ? L4_OFM_BYTE_BASE :
                                         is_pool_l3 ? L2_OFM_BYTE_BASE : 32'd0;
    wire [31:0] cur_pool_ofm_base_byte = is_pool_l9 ? L9_OFM_BYTE_BASE :
                                         is_pool_l7 ? L7_OFM_BYTE_BASE :
                                         is_pool_l5 ? L5_OFM_BYTE_BASE :
                                         is_pool_l3 ? L3_OFM_BYTE_BASE : L1_OFM_BYTE_BASE;
    wire [31:0] cur_pool_ifm_fi_byte   = is_pool_l9 ? L8_OFM_FI_BYTE :
                                         is_pool_l7 ? L6_OFM_FI_BYTE :
                                         is_pool_l5 ? L4_OFM_FI_BYTE :
                                         is_pool_l3 ? L2_OFM_FI_BYTE : L0_OFM_FI_BYTE;
    wire [31:0] cur_pool_ofm_fi_byte   = is_pool_l9 ? L9_OFM_FI_BYTE :
                                         is_pool_l7 ? L7_OFM_FI_BYTE :
                                         is_pool_l5 ? L5_OFM_FI_BYTE :
                                         is_pool_l3 ? L3_OFM_FI_BYTE : L1_OFM_FI_BYTE;

    //----------------------------------------------------------------
    // REPACK 파라미터 mux (conv_phase_r 기준)
    //----------------------------------------------------------------
    wire [31:0] cur_rp_src_base_byte   = is_conv_l10 ? L9_OFM_BYTE_BASE :
                                         is_conv_l8  ? L7_OFM_BYTE_BASE :
                                         is_conv_l6  ? L5_OFM_BYTE_BASE :
                                         is_conv_l4  ? L3_OFM_BYTE_BASE : L1_OFM_BYTE_BASE;
    wire [31:0] cur_rp_dst_base_byte   = is_conv_l10 ? L10_IFM_BYTE_BASE :
                                         is_conv_l8  ? L8_IFM_BYTE_BASE  :
                                         is_conv_l6  ? L6_IFM_BYTE_BASE  :
                                         is_conv_l4  ? L4_IFM_BYTE_BASE  : L2_IFM_BYTE_BASE;
    wire [31:0] cur_rp_src_row_byte    = is_conv_l10 ? L9_OFM_ROW_BYTE :
                                         is_conv_l8  ? L7_OFM_ROW_BYTE :
                                         is_conv_l6  ? L5_OFM_ROW_BYTE :
                                         is_conv_l4  ? L3_OFM_ROW_BYTE : L1_OFM_ROW_BYTE;
    wire [31:0] cur_rp_src_ch_byte     = is_conv_l10 ? L9_OFM_FI_BYTE :
                                         is_conv_l8  ? L7_OFM_FI_BYTE :
                                         is_conv_l6  ? L5_OFM_FI_BYTE :
                                         is_conv_l4  ? L3_OFM_FI_BYTE : L1_OFM_FI_BYTE;
    wire [31:0] cur_rp_dst_row_byte    = is_conv_l10 ? L10_IFM_ROW_BYTE :
                                         is_conv_l8  ? L8_IFM_ROW_BYTE  :
                                         is_conv_l6  ? L6_IFM_ROW_BYTE  :
                                         is_conv_l4  ? L4_IFM_ROW_BYTE  : L2_IFM_ROW_BYTE;
    wire [31:0] cur_rp_dst_cig_byte    = is_conv_l10 ? L10_IFM_CIG_BYTE_PER_R :
                                         is_conv_l8  ? L8_IFM_CIG_BYTE_PER_R  :
                                         is_conv_l6  ? L6_IFM_CIG_BYTE_PER_R  :
                                         is_conv_l4  ? L4_IFM_CIG_BYTE_PER_R  : L2_IFM_CIG_BYTE_PER_R;
    wire [19:0] cur_rp_load_words      = is_conv_l10 ? L10_RP_LOAD_WORDS_PER_BURST :
                                         is_conv_l8  ? L8_RP_LOAD_WORDS_PER_BURST  :
                                         is_conv_l6  ? L6_RP_LOAD_WORDS_PER_BURST  :
                                         is_conv_l4  ? L4_RP_LOAD_WORDS_PER_BURST  : REPACK_LOAD_WORDS_PER_BURST;
    wire [19:0] cur_rp_store_words     = is_conv_l10 ? L10_RP_STORE_WORDS_PER_CIG :
                                         is_conv_l8  ? L8_RP_STORE_WORDS_PER_CIG  :
                                         is_conv_l6  ? L6_RP_STORE_WORDS_PER_CIG  :
                                         is_conv_l4  ? L4_RP_STORE_WORDS_PER_CIG  : REPACK_STORE_WORDS_PER_CIG;
    // 다음 conv 의 H = REPACK 처리할 row 수
    wire [11:0] cur_rp_total_rows      = is_conv_l10 ? L10_H : is_conv_l8 ? L8_H : is_conv_l6 ? L6_H : is_conv_l4 ? L4_H : L2_H;
    // ci_groups - 1   (L2:3, L4:7, L6:15, L8:31, L10:63)
    wire [5:0]  cur_rp_total_cig_minus1= is_conv_l10 ? 6'd63 : is_conv_l8 ? 6'd31 : is_conv_l6 ? 6'd15 : is_conv_l4 ? 6'd7 : 6'd3;
    // W_BLK - 1   (L2:31, L4:15, L6:7, L8:3, L10:1)
    wire [4:0]  cur_rp_w_blocks_minus1 = is_conv_l10 ? 5'd1 : is_conv_l8 ? 5'd3 : is_conv_l6 ? 5'd7 : is_conv_l4 ? 5'd15 : 5'd31;

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
                    // streaming: per-fi DMA 마다 BRAM[0] 부터 덮어쓰기
                    DMA_TGT_WGT:  wgt_entry_addr_r  <= 12'd0;
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

    // conv_top streaming 모드: i_wgt_base = 0
    //   매 filter 의 weight 가 BRAM[0..acc_len-1] (read entry 기준) 에 fresh 적재됨.
    //   conv_top.i_stream_wgt_mode = 1 (filter 전환 시 wgt_base 동결)
    wire [9:0]  conv_wgt_base  = 10'd0;
    wire [11:0] conv_bias_base = cur_bias_entry_base + fi_r;

    conv_top u_conv (
        .clk(clk), .rstn(rstn),
        .i_start(conv_start),
        .o_done(conv_done),
        .o_fil_done(conv_fil_done),
        .i_conv_pause(1'b0),
        .i_stream_wgt_mode(1'b1),    // streaming: filter 전환 시 wgt_base 동결
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
        .i_total_in_words (cur_pool_ifm_per_fi),
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
                    if (rp_gen_cb_r == cur_rp_w_blocks_minus1) begin
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

    // GEN 의 Port B read addr — scratch_a 의 ch_l × W_BLK + col_b
    //   ch_l = phase[1:0], W_BLK 은 layer 별 (= cur_rp_load_words)
    wire [15:0] rp_gen_rd_addr = SCRATCH_A_BASE +
        ({14'd0, rp_gen_phase_r[1:0]} * cur_rp_load_words[15:0]) +
        {11'd0, rp_gen_cb_r[4:0]};
    wire        rp_gen_rd_en   = rp_gen_phase && (rp_gen_phase_r <= 4'd3);

    // GEN 의 Port A write — col_b × 4 + col_l (= {col_b, col_l})
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
    // 현재 layer 의 weight base byte (DRAM)
    wire [31:0] cur_wgt_layer_base = dram_wgt_base +
                                     (is_conv_l10 ? L10_WGT_BYTE_OFF :
                                      is_conv_l8  ? L8_WGT_BYTE_OFF  :
                                      is_conv_l6  ? L6_WGT_BYTE_OFF  :
                                      is_conv_l4  ? L4_WGT_BYTE_OFF  :
                                      is_conv_l2  ? L2_WGT_BYTE_OFF  : 32'd0);
    // per-filter weight DRAM byte addr = layer_base + fi × per_fi_bytes
    wire [31:0] addr_wgt_fi = cur_wgt_layer_base + ({20'd0, fi_r} * cur_wgt_per_fi_bytes);

    // Bias base byte offset (within bias DRAM region)
    wire [31:0] cur_bias_off = is_conv_l10 ? L10_BIAS_BYTE_OFF :
                               is_conv_l8  ? L8_BIAS_BYTE_OFF  :
                               is_conv_l6  ? L6_BIAS_BYTE_OFF  :
                               is_conv_l4  ? L4_BIAS_BYTE_OFF  :
                               is_conv_l2  ? L2_BIAS_BYTE_OFF  : 32'd0;
    wire [31:0] addr_bias = dram_wgt_base + 32'h00A00000 + cur_bias_off;

    // IFM row stride byte:
    //   L0: W*Ci_pad = 256*4 = 1024 byte/row (shift 10)
    //   L2: 128*16 = 2048 byte/row (shift 11)
    //   L4: 64*32  = 2048 byte/row (shift 11)
    //   (L6+ 도 모두 2048 byte/row — W*Ci 가 상수)
    wire [11:0] ifm_first_row_for_rb = (rb_r == 12'd0) ? 12'd0 : ({rb_r[10:0], 1'b0}) + 12'd1;
    wire [31:0] cur_ifm_base = is_conv_l10 ? (dram_ofm_base + L10_IFM_BYTE_BASE) :
                               is_conv_l8  ? (dram_ofm_base + L8_IFM_BYTE_BASE)  :
                               is_conv_l6  ? (dram_ofm_base + L6_IFM_BYTE_BASE)  :
                               is_conv_l4  ? (dram_ofm_base + L4_IFM_BYTE_BASE)  :
                               is_conv_l2  ? (dram_ofm_base + L2_IFM_BYTE_BASE)  :
                                             dram_ifm_base;
    wire [31:0] addr_ifm_byte = cur_ifm_base +
                                (is_conv_l0 ?
                                   ({20'd0, ifm_first_row_for_rb} << 10) :
                                   ({20'd0, ifm_first_row_for_rb} << 11));

    // OFM per (rb, fi):
    //   L0: ofm_base + fi*65536 + rb*512
    //     fi*16384 word (W_HALF^2=16384) × 4 byte/word = 65536 byte = fi << 16
    //     rb*128  word (W_HALF=128) × 4 = 512 byte = rb << 9
    //   L2: ofm_base + L2_OFM_BYTE_BASE + fi*16384 + rb*256
    //     fi*4096 word (W_HALF^2=4096) × 4 = 16384 byte = fi << 14
    //     rb*64   word (W_HALF=64) × 4 = 256 byte = rb << 8
    // OFM per (rb, fi) DRAM byte addr
    //   per fi byte = H_HALF × W_HALF × 4
    //   per rb byte = W_HALF × 4
    //     L0:  65536, 512
    //     L2:  16384, 256
    //     L4:   4096, 128
    //     L6:   1024,  64
    //     L8:    256,  32
    //     L10:    64,  16
    wire [31:0] cur_ofm_layer_base = is_conv_l10 ? (dram_ofm_base + L10_OFM_BYTE_BASE) :
                                     is_conv_l8  ? (dram_ofm_base + L8_OFM_BYTE_BASE)  :
                                     is_conv_l6  ? (dram_ofm_base + L6_OFM_BYTE_BASE)  :
                                     is_conv_l4  ? (dram_ofm_base + L4_OFM_BYTE_BASE)  :
                                     is_conv_l2  ? (dram_ofm_base + L2_OFM_BYTE_BASE)  :
                                                   dram_ofm_base;
    wire [31:0] cur_ofm_fi_byte = is_conv_l10 ? 32'd64    :
                                  is_conv_l8  ? 32'd256   :
                                  is_conv_l6  ? 32'd1024  :
                                  is_conv_l4  ? 32'd4096  :
                                  is_conv_l2  ? 32'd16384 : 32'd65536;
    wire [31:0] cur_ofm_rb_byte = is_conv_l10 ? 32'd16    :
                                  is_conv_l8  ? 32'd32    :
                                  is_conv_l6  ? 32'd64    :
                                  is_conv_l4  ? 32'd128   :
                                  is_conv_l2  ? 32'd256   : 32'd512;
    wire [31:0] addr_ofm_byte = cur_ofm_layer_base +
                                ({20'd0, fi_r} * cur_ofm_fi_byte) +
                                ({20'd0, rb_r} * cur_ofm_rb_byte);

    // Pool IFM (= 이전 layer 의 OFM[fi]) : base + fi × ifm_fi_byte
    wire [31:0] addr_pool_ifm_byte = dram_ofm_base + cur_pool_ifm_base_byte +
                                     ({20'd0, fi_r} * cur_pool_ifm_fi_byte);
    // Pool OFM[fi]            : base + fi × ofm_fi_byte
    wire [31:0] addr_pool_ofm_byte = dram_ofm_base + cur_pool_ofm_base_byte +
                                     ({20'd0, fi_r} * cur_pool_ofm_fi_byte);

    //----------------------------------------------------------------
    // REPACK 주소 (row r, ci_g, ch_l within group)
    //   rp_cig_r 6-bit: L9→L10 (ci_g 0..63) 까지 cover
    //   rp_chfull 8-bit: max = ci_g*4 + ch_l = 63*4+3 = 255
    //----------------------------------------------------------------
    reg [11:0] rp_row_r;
    reg [5:0]  rp_cig_r;
    reg [2:0]  rp_chl_r;

    wire [7:0]  rp_chfull = {rp_cig_r[5:0], rp_chl_r[1:0]};
    wire [31:0] addr_rp_load_byte =
        dram_ofm_base + cur_rp_src_base_byte +
        ({24'd0, rp_chfull} * cur_rp_src_ch_byte) +
        ({20'd0, rp_row_r}  * cur_rp_src_row_byte);

    wire [31:0] addr_rp_store_byte =
        dram_ofm_base + cur_rp_dst_base_byte +
        ({20'd0, rp_row_r} * cur_rp_dst_row_byte) +
        ({26'd0, rp_cig_r} * cur_rp_dst_cig_byte);

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
            fi_r                    <= 12'd0;
            layer_idx               <= 5'd0;
            conv_phase_r            <= 5'd0;
            pool_phase_r            <= 5'd0;
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
            rp_cig_r                <= 6'd0;
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
                        fi_r            <= 12'd0;
                        layer_idx       <= 5'd0;
                        conv_phase_r    <= 5'd0;
                        pool_phase_r    <= 5'd0;
                        network_done_r  <= 1'b0;
                        state_r         <= S_LOAD_BIAS;
                    end
                end

                //------------------------------------------------
                // Bias 는 layer 시작 시 한 번 BRAM 전체 적재 (작아서 streaming
                // 불필요). Weight 는 per-fi 로 stream → S_LOAD_BIAS 만 layer
                // 시작 시 실행.
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
                        fi_r    <= 12'd0;
                        state_r <= S_FI_LOAD_WGT;
                    end
                end

                //------------------------------------------------
                // Streaming weight DMA — 현재 fi 의 weight 만 BRAM[0..] 에 fresh 적재
                //   per-fi DMA word count = cur_wgt_per_fi_words (L0=16, L2=64)
                //   per-fi DRAM byte addr = layer_base + fi × per_fi_bytes
                //------------------------------------------------
                S_FI_LOAD_WGT: begin
                    dma_target_r      <= DMA_TGT_WGT;
                    dma_rd_num_trans  <= cur_wgt_per_fi_words;
                    dma_rd_start_addr <= addr_wgt_fi;
                    dma_rd_start      <= 1'b1;
                    state_r           <= S_FI_LOAD_WGT_WAIT;
                end
                S_FI_LOAD_WGT_WAIT: begin
                    if (dma_rd_done) state_r <= S_FIL_CONV_START;
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
                        if (fi_r == cur_co - 12'd1) begin
                            state_r <= S_RB_NEXT;
                        end else begin
                            fi_r    <= fi_r + 12'd1;
                            state_r <= S_FI_LOAD_WGT;
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
                // Conv 완료 → 다음 pool 진입
                //   cp=0  → L1 pool   (layer_idx=1, pp=1)
                //   cp=2  → L3 pool   (layer_idx=3, pp=3)
                //   cp=4  → L5 pool   (layer_idx=5, pp=5)
                //   cp=6  → L7 pool   (layer_idx=7, pp=7)
                //   cp=8  → L9 pool   (layer_idx=9, pp=9)
                //   cp=10 → 최종 종료 (layer_idx=11)
                //------------------------------------------------
                S_CONV_DONE: begin
                    fi_r         <= 12'd0;
                    dma_target_r <= DMA_TGT_NONE;
                    if (conv_phase_r == 5'd10) begin
                        // L10 완료 → 최종 종료
                        layer_idx      <= 5'd11;
                        network_done_r <= 1'b1;
                        state_r        <= S_DONE;
                    end else begin
                        state_r      <= S_L1_FI_LOAD;
                        case (conv_phase_r)
                            5'd0: begin layer_idx <= 5'd1; pool_phase_r <= 5'd1; end
                            5'd2: begin layer_idx <= 5'd3; pool_phase_r <= 5'd3; end
                            5'd4: begin layer_idx <= 5'd5; pool_phase_r <= 5'd5; end
                            5'd6: begin layer_idx <= 5'd7; pool_phase_r <= 5'd7; end
                            default: begin   // cp == 5'd8
                                layer_idx <= 5'd9; pool_phase_r <= 5'd9;
                            end
                        endcase
                    end
                end

                //------------------------------------------------
                // Pool (L1/L3/L5) — fi 별 (load → pool → store)
                //   pool_phase_r 로 layer 구별, cur_pool_* 로 파라미터 mux
                //------------------------------------------------
                S_L1_FI_LOAD: begin
                    dma_target_r           <= DMA_TGT_L1_IFM;
                    dpram_load_addr_init_r <= 16'd0;
                    dma_rd_num_trans       <= cur_pool_ifm_per_fi;
                    dma_rd_start_addr      <= addr_pool_ifm_byte;
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
                    dma_wr_num_trans        <= cur_pool_ofm_per_fi;
                    dma_wr_start_addr       <= addr_pool_ofm_byte;
                    dpram_store_addr_init_r <= 16'd0;
                    dma_wr_start            <= 1'b1;
                    state_r                 <= S_L1_FI_STORE_WAIT;
                end
                S_L1_FI_STORE_WAIT: begin
                    if (dma_wr_done) state_r <= S_L1_NEXT_FI;
                end

                S_L1_NEXT_FI: begin
                    if (fi_r == {2'd0, cur_pool_co} - 12'd1) begin
                        // Pool 완료 → REPACK 진입 (다음 conv 의 IFM 생성)
                        rp_row_r  <= 12'd0;
                        rp_cig_r  <= 6'd0;
                        rp_chl_r  <= 3'd0;
                        state_r   <= S_RP_LOAD;
                        case (pool_phase_r)
                            5'd1: begin layer_idx <= 5'd2;  conv_phase_r <= 5'd2;  end
                            5'd3: begin layer_idx <= 5'd4;  conv_phase_r <= 5'd4;  end
                            5'd5: begin layer_idx <= 5'd6;  conv_phase_r <= 5'd6;  end
                            5'd7: begin layer_idx <= 5'd8;  conv_phase_r <= 5'd8;  end
                            default: begin   // pp == 5'd9
                                layer_idx <= 5'd10; conv_phase_r <= 5'd10;
                            end
                        endcase
                    end else begin
                        fi_r    <= fi_r + 12'd1;
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
                    // scratch_a 의 ch_l 슬롯 = ch_l × W_BLK
                    dpram_load_addr_init_r <= ({14'd0, rp_chl_r[1:0]} * cur_rp_load_words[15:0]);
                    dma_rd_num_trans       <= cur_rp_load_words;
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
                    if (rp_gen_done_r) state_r <= S_RP_STORE;
                end

                S_RP_STORE: begin
                    dma_wr_num_trans        <= cur_rp_store_words;
                    dma_wr_start_addr       <= addr_rp_store_byte;
                    dpram_store_addr_init_r <= SCRATCH_B_BASE;
                    dma_wr_start            <= 1'b1;
                    state_r                 <= S_RP_STORE_WAIT;
                end
                S_RP_STORE_WAIT: begin
                    if (dma_wr_done) state_r <= S_RP_NEXT_CIG;
                end

                S_RP_NEXT_CIG: begin
                    if (rp_cig_r == cur_rp_total_cig_minus1) begin
                        rp_cig_r <= 6'd0;
                        if (rp_row_r == cur_rp_total_rows - 12'd1) begin
                            // REPACK 완료 → 다음 conv 진입 (streaming: bias 부터)
                            rb_r    <= 12'd0;
                            fi_r    <= 12'd0;
                            state_r <= S_LOAD_BIAS;
                        end else begin
                            rp_row_r <= rp_row_r + 12'd1;
                            state_r  <= S_RP_LOAD;
                        end
                    end else begin
                        rp_cig_r <= rp_cig_r + 6'd1;
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
