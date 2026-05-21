`timescale 1ns / 1ps
//----------------------------------------------------------------+
// yolo_engine.v — Clean rewrite v1 (L0 / L1 / L2 only)
//
// 설계 원칙:
//   1. rb_stream uniform across all conv layers
//      - conv_top 은 항상 i_ofm_h_half=1, i_row_start=rb 로 호출.
//      - 각 rb 마다 IFM 2-3 row DMA → conv 1회 → OFM Co개 row DMA.
//   2. Pool chunk-based (prev OFM > dpram 한도)
//      - L1: L0 OFM = 262144 word > 65536 → 4 chunks.
//      - 한 chunk = 한 filter group (4 fil × 16384 word) → 안전 분할.
//   3. 서브모듈 인터페이스 전부 유지
//      - conv_top, max_pool_unit, ifm_line_buf, gbuff_param
//      - axi_dma_rd, axi_dma_wr, dpram_wrapper
//   4. AXI slave register map 유지
//      - ctrl_reg0[0] = ap_start
//      - ctrl_reg1    = dram_wgt_base
//      - ctrl_reg2    = dram_ifm_base (L0 input)
//      - ctrl_reg3    = dram_ofm_base
//   5. v1 미지원: conv1×1, s1_pool, upsample, route, stream_wgt
//
// 지원 layer (v1):
//   L0 : conv 3×3 — Ci=3, Co=16, 256×256×3 → 256×256×16
//   L1 : maxpool stride-2 — 256×256×16 → 128×128×16
//   L2 : conv 3×3 — Ci=16, Co=32, 128×128×16 → 128×128×32
//
// DRAM layout (software 약속):
//   dram_wgt_base + 0           : weights (L0=27 entry × 16B, L2=144 entry × 16B)
//   dram_wgt_base + 0x00A00000  : bias 영역 (각 layer Co 만큼)
//   dram_ifm_base               : L0 input 이미지 (256×256×4ch padded, NCHW packed)
//   dram_ofm_base + 0           : L0 OFM (16 × 128 × 128 packed word = 262144 word)
//   dram_ofm_base + 0x00100000  : L1 OFM (16 ×  64 ×  64           =  65536 word)
//   dram_ofm_base + 0x00140000  : L2 OFM (32 ×  64 ×  64           = 131072 word)
//
// Top FSM (15 states):
//   IDLE  → INIT → (conv) LOAD_WGT → LOAD_WGT_WAIT → LOAD_BIAS → LOAD_BIAS_WAIT
//                 → RB_DMA_IFM → RB_DMA_IFM_WAIT → CONV_START → CONV_WAIT
//                 → RB_DMA_OFM → RB_DMA_OFM_WAIT → RB_NEXT
//                                             (loop until last rb) → LAYER_NEXT
//         → (pool) POOL_DMA_IFM → POOL_DMA_IFM_WAIT
//                 → POOL_RUN → POOL_DMA_OFM → POOL_DMA_OFM_WAIT
//                 → POOL_NEXT (loop chunks) → LAYER_NEXT
//         → DONE
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

    //================================================================
    // AXI Slave (control)
    //================================================================
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

    wire        ap_start       = ctrl_reg0[0];
    wire [31:0] dram_wgt_base  = ctrl_reg1;
    wire [31:0] dram_ifm_base  = ctrl_reg2;
    wire [31:0] dram_ofm_base  = ctrl_reg3;

    //================================================================
    // Per-layer parameter table (v1: L0/L1/L2 only)
    //
    //   각 layer 의 OFM 크기, weight/bias DRAM offset, ci_groups 등.
    //   v2 에서 L3~L10 까지 확장 예정.
    //================================================================
    reg  [4:0]  layer_idx;             // 현재 layer

    // 조합 — layer_idx 로부터 layer 속성 도출
    reg         lyr_is_conv;           // conv layer flag
    reg         lyr_is_pool;           // maxpool stride-2 flag
    reg  [11:0] lyr_ofm_w;             // OFM W (conv: 결과, pool: 입력 의 1/2)
    reg  [11:0] lyr_ofm_h;             // OFM H
    reg  [11:0] lyr_co;                // OFM Co (= conv 출력 채널 수 또는 pool 입력 채널 수)
    reg  [11:0] lyr_ci;                // IFM Ci (conv 전용)
    reg  [7:0]  lyr_acc_len;           // conv 누적 cycle 수 = ceil(Ci/4)
    reg  [4:0]  lyr_shift;             // descaling shift
    reg  [7:0]  lyr_ci_groups;         // ifm_line_buf 의 ci_groups (= ceil(Ci/4))

    // DRAM offset (word 단위)
    reg  [21:0] lyr_wgt_dram_words;    // 누적 weight word offset
    reg  [11:0] lyr_bias_dram_words;   // 누적 bias word offset
    reg  [21:0] lyr_ifm_offset_w;      // IFM 시작 (OFM 영역 기준 word)
    reg  [21:0] lyr_ofm_offset_w;      // OFM 시작 (OFM 영역 기준 word)
    reg         lyr_use_input;         // 1 이면 dram_ifm_base 사용 (L0 만)

    always @(*) begin
        // 기본값
        lyr_is_conv         = 1'b0;
        lyr_is_pool         = 1'b0;
        lyr_ofm_w           = 12'd0;
        lyr_ofm_h           = 12'd0;
        lyr_co              = 12'd0;
        lyr_ci              = 12'd0;
        lyr_acc_len         = 8'd1;
        lyr_shift           = 5'd13;
        lyr_ci_groups       = 8'd1;
        lyr_wgt_dram_words  = 22'd0;
        lyr_bias_dram_words = 12'd0;
        lyr_ifm_offset_w    = 22'd0;
        lyr_ofm_offset_w    = 22'd0;
        lyr_use_input       = 1'b0;

        case (layer_idx)
            // L0: conv 3×3, Ci=3, Co=16, 256×256×3 → 256×256×16
            //   weight word count = 16 entry × Co (16) × 16 word/entry / 16 ent × ...
            //   실제: 1 filter = acc_len(1) × 16 words = 16 words
            //         total weight = Co × acc_len × 16 = 16 × 1 × 16 = 256 words
            //   bias  = Co × 1 word = 16 words
            5'd0: begin
                lyr_is_conv         = 1'b1;
                lyr_ofm_w           = 12'd256;
                lyr_ofm_h           = 12'd256;
                lyr_co              = 12'd16;
                lyr_ci              = 12'd3;
                lyr_acc_len         = 8'd1;
                lyr_shift           = 5'd8;
                lyr_ci_groups       = 8'd1;
                lyr_wgt_dram_words  = 22'd0;
                lyr_bias_dram_words = 12'd0;
                lyr_use_input       = 1'b1;
                lyr_ofm_offset_w    = 22'd0;             // L0 OFM @ ofm_base + 0
            end

            // L1: maxpool stride-2, in 256×256×16 → 128×128×16
            //   lyr_ofm_w/h = pool 출력 크기 (128)
            //   lyr_co      = filter 수 (= 16)
            //   lyr_ifm_offset_w = L0 OFM 위치 (= 0)
            //   lyr_ofm_offset_w = L1 OFM 위치
            5'd1: begin
                lyr_is_pool         = 1'b1;
                lyr_ofm_w           = 12'd128;
                lyr_ofm_h           = 12'd128;
                lyr_co              = 12'd16;
                lyr_ifm_offset_w    = 22'd0;             // L0 OFM start
                lyr_ofm_offset_w    = 22'd262144;        // L1 OFM @ word 262144
            end

            // L2: conv 3×3, Ci=16, Co=32, 128×128×16 → 128×128×32
            //   weight word = Co × acc_len × 16 = 32 × 4 × 16 = 2048 words
            //     ※ L0 weight 256 word + L1 (no weight) → L2 base = 256 words.
            //   bias  = Co × 1 = 32 words. L0 bias 16 + L1 (none) → L2 base = 16 words.
            5'd2: begin
                lyr_is_conv         = 1'b1;
                lyr_ofm_w           = 12'd128;
                lyr_ofm_h           = 12'd128;
                lyr_co              = 12'd32;
                lyr_ci              = 12'd16;
                lyr_acc_len         = 8'd4;
                lyr_shift           = 5'd6;
                lyr_ci_groups       = 8'd4;
                lyr_wgt_dram_words  = 22'd256;           // L0 (16×1×16=256) 다음
                lyr_bias_dram_words = 12'd16;            // L0 bias (16) 다음
                lyr_ifm_offset_w    = 22'd262144;        // L1 OFM @ 262144
                lyr_ofm_offset_w    = 22'd327680;        // L2 OFM @ 262144 + 65536
            end

            default: ;
        endcase
    end

    // 파생값
    wire [11:0] lyr_ofm_w_half = {1'b0, lyr_ofm_w[11:1]};   // W/2
    wire [11:0] lyr_ofm_h_half = {1'b0, lyr_ofm_h[11:1]};   // H/2
    wire [11:0] lyr_w_blocks   = (lyr_ofm_w + 12'd3) >> 2;  // ceil(W/4)
    wire [11:0] lyr_h_blocks   = (lyr_ofm_h + 12'd3) >> 2;  // ceil(H/4) — unused
    /* verilator lint_off UNUSED */
    wire _unused_hb = |lyr_h_blocks;
    /* verilator lint_on UNUSED */

    // 한 IFM row 당 BRAM entry 수 (= w_blocks × ci_groups)
    wire [15:0] entries_per_row = {4'd0, lyr_w_blocks} * {8'd0, lyr_ci_groups};

    // DRAM byte address 계산
    wire [31:0] addr_wgt  = dram_wgt_base + ({10'd0, lyr_wgt_dram_words} << 2);
    wire [31:0] addr_bias = dram_wgt_base + 32'h00A00000 + ({20'd0, lyr_bias_dram_words} << 2);
    wire [31:0] addr_ifm  = lyr_use_input ? dram_ifm_base
                                          : (dram_ofm_base + ({10'd0, lyr_ifm_offset_w} << 2));
    wire [31:0] addr_ofm  = dram_ofm_base + ({10'd0, lyr_ofm_offset_w} << 2);

    //================================================================
    // FSM 상태
    //================================================================
    localparam ST_IDLE             = 5'd0,
               ST_INIT             = 5'd1,
               ST_LOAD_WGT         = 5'd2,
               ST_LOAD_WGT_WAIT    = 5'd3,
               ST_LOAD_BIAS        = 5'd4,
               ST_LOAD_BIAS_WAIT   = 5'd5,
               ST_RB_DMA_IFM       = 5'd6,
               ST_RB_DMA_IFM_WAIT  = 5'd7,
               ST_CONV_START       = 5'd8,
               ST_CONV_WAIT        = 5'd9,
               ST_RB_DMA_OFM       = 5'd10,
               ST_RB_DMA_OFM_WAIT  = 5'd11,
               ST_RB_NEXT          = 5'd12,
               ST_POOL_DMA_IFM     = 5'd13,
               ST_POOL_DMA_IFM_WAIT= 5'd14,
               ST_POOL_RUN         = 5'd15,
               ST_POOL_WAIT        = 5'd16,
               ST_POOL_DMA_OFM     = 5'd17,
               ST_POOL_DMA_OFM_WAIT= 5'd18,
               ST_POOL_NEXT        = 5'd19,
               ST_LAYER_NEXT       = 5'd20,
               ST_DONE             = 5'd21;
    reg [4:0] top_state;

    // DMA target enum (read 경로 분기)
    localparam DMA_TGT_NONE  = 2'd0,
               DMA_TGT_WGT   = 2'd1,
               DMA_TGT_BIAS  = 2'd2,
               DMA_TGT_IFM   = 2'd3;
    reg [1:0]  dma_target_r;

    // Pool 경로: DRAM → dpram 직접 적재용 별도 플래그
    reg        pool_dma_load_r;       // 1=현재 DMA read 는 pool input dpram 로딩
    reg        pool_dma_store_r;      // 1=현재 DMA write 는 pool output

    //================================================================
    // DMA Read 인스턴스
    //================================================================
    reg         dma_rd_start;
    reg  [19:0] dma_rd_num_trans;
    reg  [31:0] dma_rd_start_addr;
    wire [31:0] dma_rd_data;
    wire        dma_rd_data_vld;
    wire [19:0] dma_rd_data_cnt;
    wire        dma_rd_done;
    /* verilator lint_off UNUSED */
    wire _unused_cnt = |dma_rd_data_cnt;
    /* verilator lint_on UNUSED */

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

    //================================================================
    // DMA Write 인스턴스
    //================================================================
    reg         dma_wr_start;
    reg  [19:0] dma_wr_num_trans;
    reg  [31:0] dma_wr_start_addr;
    wire [31:0] dma_wr_indata;
    wire        dma_wr_indata_req;
    wire        dma_wr_done;
    wire        dma_wr_fail;
    /* verilator lint_off UNUSED */
    wire _unused_fail = dma_wr_fail;
    /* verilator lint_on UNUSED */

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

    //================================================================
    // 4-word assembler (32-bit AXI → 128-bit entry)
    //   Weight / IFM 은 16-byte entry 단위. Bias 는 32-bit 직접.
    //================================================================
    reg  [1:0]   asm_cnt;
    reg  [31:0]  asm_w0, asm_w1, asm_w2;
    reg          asm_full;
    reg  [127:0] asm_data;

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
            end else if (dma_rd_data_vld && (dma_target_r != DMA_TGT_BIAS) && !pool_dma_load_r) begin
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

    //================================================================
    // 가중치 / Bias / IFM 적재 주소 카운터
    //
    //   ※ dma_ifm_row_start_r 는 main FSM 이 ST_RB_DMA_IFM 진입 시 셋업.
    //     이 always 는 dma_rd_start && IFM target 일 때 그 값을 초기 dma_ifm_row_r 로
    //     사용하고, 이후 asm_full 마다 entries_per_row 단위로 증가.
    //================================================================
    reg  [11:0] wgt_entry_addr_r;
    reg  [11:0] bias_entry_addr_r;

    // IFM 적재: rb_stream 모드 → row r → bank r%4 의 addr 0..entries_per_row-1
    reg  [11:0] dma_ifm_row_r;
    reg  [11:0] dma_ifm_eir_r;
    reg  [11:0] dma_ifm_row_start_r;     // main FSM 이 세팅

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            wgt_entry_addr_r  <= 12'd0;
            bias_entry_addr_r <= 12'd0;
            dma_ifm_row_r     <= 12'd0;
            dma_ifm_eir_r     <= 12'd0;
        end else begin
            if (dma_rd_start) begin
                case (dma_target_r)
                    DMA_TGT_WGT:  wgt_entry_addr_r  <= 12'd0;
                    DMA_TGT_BIAS: bias_entry_addr_r <= 12'd0;
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
                    if (dma_ifm_eir_r == entries_per_row[11:0] - 12'd1) begin
                        dma_ifm_eir_r <= 12'd0;
                        dma_ifm_row_r <= dma_ifm_row_r + 12'd1;
                    end else begin
                        dma_ifm_eir_r <= dma_ifm_eir_r + 12'd1;
                    end
                end
            end
        end
    end

    // gbuff_param 으로 가는 weight write 신호
    wire        dma_wgt_we   = asm_full && (dma_target_r == DMA_TGT_WGT);
    wire [11:0] dma_wgt_addr = wgt_entry_addr_r;
    wire [71:0] dma_wgt_data = asm_data[71:0];   // lower 72b (software 가 16B padded)

    wire        dma_bias_we   = dma_rd_data_vld && (dma_target_r == DMA_TGT_BIAS);
    wire [11:0] dma_bias_addr = bias_entry_addr_r;
    wire [31:0] dma_bias_data = dma_rd_data;

    // ifm_line_buf 로 가는 IFM write 신호
    wire        dma_lb_wr_en   = asm_full && (dma_target_r == DMA_TGT_IFM);
    wire [1:0]  dma_lb_wr_line = dma_ifm_row_r[1:0];     // bank = row mod 4
    wire [10:0] dma_lb_wr_addr = dma_ifm_eir_r[10:0];    // addr = eir (rb_stream → 항상 0..epr-1)
    wire [127:0] dma_lb_wr_data = asm_data;

    //================================================================
    // ifm_line_buf
    //================================================================
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
        .i_mode(1'b0),                                  // v1: 3x3 만
        .i_w_blocks(lyr_w_blocks),
        .i_ci_groups(lyr_ci_groups),
        .i_w(lyr_ofm_w),
        .i_h(lyr_ofm_h),
        .i_line_valid(4'b1111),
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

    //================================================================
    // conv_top — 항상 rb_stream 모드 (h_half=1, row_start=rb_r)
    //================================================================
    reg         conv_start;
    wire        conv_done;
    wire        conv_fil_done;
    wire [31:0] conv_pixel;
    wire        conv_pixel_vld;
    wire [25:0] conv_ofm_addr;
    reg  [11:0] rb_r;                          // 현재 처리 중인 rb

    /* verilator lint_off UNUSED */
    wire _unused_fil_done = conv_fil_done;
    /* verilator lint_on UNUSED */

    conv_top u_conv (
        .clk(clk), .rstn(rstn),
        .i_start(conv_start),
        .o_done(conv_done),
        .o_fil_done(conv_fil_done),
        .i_conv_pause(1'b0),                   // v1: stream_wgt 미사용 → pause 불필요
        .i_stream_wgt_mode(1'b0),
        .i_mode(1'b0),                         // v1: 3x3 만
        .i_ofm_w_half(lyr_ofm_w_half),
        .i_ofm_h_half(12'd1),                  // rb_stream: 한 번에 1 row 만
        .i_row_start(rb_r),
        .i_co_total(lyr_co),
        .i_acc_len(lyr_acc_len),
        .i_wgt_base(10'd0),
        .i_bias_base(12'd0),
        .i_shift(lyr_shift),
        .dma_wgt_we(dma_wgt_we),   .dma_wgt_addr(dma_wgt_addr),   .dma_wgt_data(dma_wgt_data),
        .dma_bias_we(dma_bias_we), .dma_bias_addr(dma_bias_addr), .dma_bias_data(dma_bias_data),
        .o_ifm_re(conv_ifm_re),
        .o_ifm_row(conv_ifm_row), .o_ifm_col(conv_ifm_col), .o_ifm_acc(conv_ifm_acc),
        .i_ifm_00(ifm_00), .i_ifm_01(ifm_01),
        .i_ifm_10(ifm_10), .i_ifm_11(ifm_11),
        .o_pixel(conv_pixel),
        .o_pixel_vld(conv_pixel_vld),
        .o_ofm_addr(conv_ofm_addr)
    );

    //================================================================
    // max_pool_unit (stride 2)
    //   v1 에서는 chunked 모드 — 한 chunk 당 dpram[0..N_in-1] 처리.
    //================================================================
    reg         pool_start;
    wire        pool_done;
    reg  [19:0] pool_in_words_r;       // 현재 chunk 의 입력 word 수
    wire        pool_rd_en;
    wire [15:0] pool_rd_addr;
    wire [31:0] pool_rd_data;
    wire        pool_wr_en;
    wire [15:0] pool_wr_addr;
    wire [31:0] pool_wr_data;

    max_pool_unit u_pool (
        .clk(clk), .rstn(rstn),
        .i_start(pool_start), .o_done(pool_done),
        .i_total_in_words(pool_in_words_r),
        .o_rd_en(pool_rd_en), .o_rd_addr(pool_rd_addr), .i_rd_data(pool_rd_data),
        .o_wr_en(pool_wr_en), .o_wr_addr(pool_wr_addr), .o_wr_data(pool_wr_data)
    );

    //================================================================
    // OFM dpram (65536 × 32-bit) — yolo_engine_l0_tb 와 동일 파라미터
    //   Port A (write): conv_pixel / pool_wr / DMA load (pool 모드)
    //   Port B (read)  : pool_rd / DMA store
    //================================================================
    // DMA load (pool input → dpram) 카운터
    reg  [15:0] dpram_load_addr_r;
    reg  [15:0] dpram_store_addr_r;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            dpram_load_addr_r  <= 16'd0;
            dpram_store_addr_r <= 16'd0;
        end else begin
            // dpram load (pool input) addr
            if (dma_rd_start && pool_dma_load_r)         dpram_load_addr_r <= 16'd0;
            else if (dma_rd_data_vld && pool_dma_load_r) dpram_load_addr_r <= dpram_load_addr_r + 16'd1;

            // dpram store addr — conv 모드는 fil 의 dpram base, pool 모드는 0
            if (dma_wr_start) begin
                if (pool_dma_store_r) dpram_store_addr_r <= 16'd0;
                else                  dpram_store_addr_r <= ofm_dpram_base;
            end else if (dma_wr_indata_req)
                dpram_store_addr_r <= dpram_store_addr_r + 16'd1;
        end
    end

    // OFM dpram port A (write) mux:
    //   1) conv_pixel — conv layer 진행 중
    //   2) pool_wr    — max_pool_unit 의 in-place write
    //   3) DMA load   — pool input 을 DRAM 에서 dpram 으로 적재
    wire        dma_dpram_we      = dma_rd_data_vld && pool_dma_load_r;
    wire        ofm_wr_en   = conv_pixel_vld | pool_wr_en | dma_dpram_we;
    wire [15:0] ofm_wr_addr =
                  conv_pixel_vld ? conv_ofm_addr[15:0] :
                  pool_wr_en     ? pool_wr_addr        :
                                   dpram_load_addr_r;
    wire [31:0] ofm_wr_data =
                  conv_pixel_vld ? conv_pixel :
                  pool_wr_en     ? pool_wr_data :
                                   dma_rd_data;

    // OFM dpram port B (read) mux:
    //   1) pool_rd  — max_pool_unit 의 read
    //   2) DMA store — OFM 을 DRAM 으로 dump
    wire        ofm_rd_en   = pool_rd_en | dma_wr_indata_req | pool_dma_store_r;
    wire [15:0] ofm_rd_addr =
                  pool_rd_en ? pool_rd_addr :
                               dpram_store_addr_r;
    wire [31:0] ofm_rd_data;

    assign pool_rd_data = ofm_rd_data;
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

    //================================================================
    // Pool chunking
    //
    //   L1 pool: input = 16 fil × 128 × 128 = 262144 word > 65536 dpram
    //   Chunk = 4 fil × 16384 word = 65536 word.
    //   N_chunks = 262144 / 65536 = 4.
    //
    //   각 chunk 에 대해:
    //     - DMA RD : DRAM[L0 OFM + chunk × 65536 word .. ] → dpram[0..65535]
    //     - max_pool: dpram[0..65535] → dpram[0..16383] (in-place 안전성 검증됨)
    //     - DMA WR : dpram[0..16383] → DRAM[L1 OFM + chunk × 16384 word ..]
    //
    //   ※ 일반화: chunk_in_words = min(65536, remaining)
    //              chunk_out_words = chunk_in_words / 4
    //================================================================
    reg  [3:0]  pool_chunk_idx_r;
    reg  [3:0]  pool_n_chunks_r;
    wire [19:0] pool_total_words = ({8'd0, lyr_co} *
                                    {4'd0, lyr_ofm_w, 4'd0}); // Co × W × 16? — 잘못
    // 올바른 식: pool 입력 = prev_layer_OFM = Co × (W*2) × (H*2) packed word
    //            = Co × (lyr_ofm_w*2 * lyr_ofm_h*2) / 4
    //            = Co × W × H ÷ 4 × 4? 헷갈리므로 명시적으로
    //
    // L1 의 경우: lyr_ofm_w=128, lyr_ofm_h=128 (= L1 output 크기)
    //            L0 OFM packed word = 16 × 128 × 128 = 262144
    // 일반화: L1 OFM packed = lyr_co × lyr_ofm_w × lyr_ofm_h = pool 출력 word
    //          L1 IFM packed (= L0 OFM) = 4 × pool 출력 = 4 × lyr_co × lyr_ofm_w × lyr_ofm_h
    wire [21:0] pool_in_total_words  = ({10'd0, lyr_co} *
                                       {10'd0, lyr_ofm_w} *
                                       {10'd0, lyr_ofm_h});  // pool_out × 4? — Let me think
    // Actually pool out word = Co × (W/2) × (H/2). 하지만 v1 에서 lyr_ofm_w/h 가
    // 이미 pool 의 OUTPUT 크기 (= L1 의 128) 로 설정됨. 그러면:
    //   pool input word = 4 × pool output word = 4 × Co × ofm_w_half × ofm_h_half
    //   여기서 ofm_w_half/h_half 는 pool output 의 W/2,H/2 — 안 맞음.
    //
    // 정정: L1 pool 의 lyr_ofm_w=128 은 pool 출력의 가로 (= L0 출력 / 2).
    //       L1 pool 의 input packed word = 16 × 128 × 128 = 262144
    //       L1 pool 의 output packed word = 16 × 64 × 64 = 65536
    //       즉 pool input = lyr_co × lyr_ofm_w × lyr_ofm_h = 16 × 128 × 128 = 262144 ✓
    /* verilator lint_off UNUSED */
    wire _unused_pin = |pool_total_words;
    /* verilator lint_on UNUSED */

    wire [21:0] pool_out_total_words =
                ({10'd0, lyr_co} *
                 {10'd0, lyr_ofm_w_half} *
                 {10'd0, lyr_ofm_h_half});

    // pool 입력 총 word: lyr_co × lyr_ofm_w × lyr_ofm_h (L1 = 16 × 128 × 128 = 262144)
    wire [21:0] pool_in_total_22 = ({10'd0, lyr_co} *
                                    {10'd0, lyr_ofm_w} *
                                    {10'd0, lyr_ofm_h});

    //================================================================
    // Top FSM — 본체
    //================================================================
    // rb_stream IFM DMA 워드 수 계산
    //   초기 (rb=0): 3 row = 3 × entries_per_row × 4 word
    //   이후 (rb>0): 2 row = 2 × entries_per_row × 4 word
    wire [19:0] ifm_dma_init_words = ({4'd0, entries_per_row} * 16'd3) << 2;
    wire [19:0] ifm_dma_next_words = ({4'd0, entries_per_row} * 16'd2) << 2;

    // Conv weight / bias DMA 워드 수
    //   weight = Co × acc_len × 16 word (16-byte entry × 4 word/entry × Co × acc_len)
    wire [21:0] wgt_dma_words = ({10'd0, lyr_co} * {14'd0, lyr_acc_len}) << 4;
    wire [11:0] bias_dma_words = lyr_co;

    // RB 별 IFM row 번호 (rb_stream 매핑)
    //   rb=0: rows 0, 1, 2 적재 (window row -1 = padding 으로 처리)
    //   rb>0: rows (2*rb+1), (2*rb+2) 적재 (rows 2*rb-1, 2*rb 는 이전 rb 에서 적재됨)
    wire [11:0] rb_init_first_row = 12'd0;
    wire [11:0] rb_next_first_row = ({rb_r[10:0], 1'b0}) + 12'd1;  // 2*rb+1

    // OFM DMA store per rb (한 filter 의 한 row = ofm_w_half words)
    //   fil 별로 별도 DMA. dpram 내 fil 의 시작 addr = fil × ofm_w_half
    //   DRAM 내 fil 의 시작 byte = lyr_ofm_offset_w × 4
    //                              + fil × (ofm_w_half × ofm_h_half) × 4
    //                              + rb × ofm_w_half × 4
    reg [11:0] ofm_fil_r;     // 현재 DMA 중인 filter (0..lyr_co-1)
    wire [21:0] fil_dram_base_words = ({10'd0, ofm_fil_r} *
                                       {10'd0, lyr_ofm_w_half} *
                                       {10'd0, lyr_ofm_h_half});
    wire [21:0] rb_row_offset_words = {10'd0, rb_r} * {10'd0, lyr_ofm_w_half};
    wire [31:0] ofm_dma_addr        = addr_ofm +
                                      ({10'd0, fil_dram_base_words} << 2) +
                                      ({10'd0, rb_row_offset_words} << 2);
    wire [15:0] ofm_dpram_base      = {4'd0, ofm_fil_r} * {4'd0, lyr_ofm_w_half};

    // 메인 FSM body
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            top_state         <= ST_IDLE;
            layer_idx         <= 5'd0;
            dma_target_r      <= DMA_TGT_NONE;
            pool_dma_load_r   <= 1'b0;
            pool_dma_store_r  <= 1'b0;
            dma_rd_start      <= 1'b0;
            dma_rd_num_trans  <= 20'd0;
            dma_rd_start_addr <= 32'd0;
            dma_wr_start      <= 1'b0;
            dma_wr_num_trans  <= 20'd0;
            dma_wr_start_addr <= 32'd0;
            conv_start        <= 1'b0;
            pool_start        <= 1'b0;
            network_done_r    <= 1'b0;
            rb_r              <= 12'd0;
            ofm_fil_r         <= 12'd0;
            pool_chunk_idx_r  <= 4'd0;
            pool_n_chunks_r   <= 4'd0;
            pool_in_words_r   <= 20'd0;
            dma_ifm_row_start_r <= 12'd0;
        end else begin
            // 1-cycle pulse defaults
            dma_rd_start <= 1'b0;
            dma_wr_start <= 1'b0;
            conv_start   <= 1'b0;
            pool_start   <= 1'b0;

            case (top_state)
                //------------------------------------------------
                ST_IDLE: begin
                    if (ap_start) begin
                        layer_idx      <= 5'd0;
                        network_done_r <= 1'b0;
                        top_state      <= ST_INIT;
                    end
                end

                //------------------------------------------------
                ST_INIT: begin
                    // 1 cycle 대기 (layer 파라미터 안정화)
                    if (lyr_is_conv) begin
                        top_state <= ST_LOAD_WGT;
                    end else if (lyr_is_pool) begin
                        // pool n_chunks 계산: ceil(pool_in_total / 65536)
                        //   v1: L1 만 지원, 정확히 나눠떨어진다는 가정. pool_in_total >> 16
                        pool_chunk_idx_r <= 4'd0;
                        pool_n_chunks_r  <= pool_in_total_22[21:16];
                        top_state <= ST_POOL_DMA_IFM;
                    end else begin
                        top_state <= ST_LAYER_NEXT;
                    end
                end

                //================================================
                // Conv path
                //================================================
                ST_LOAD_WGT: begin
                    dma_target_r      <= DMA_TGT_WGT;
                    dma_rd_num_trans  <= wgt_dma_words[19:0];
                    dma_rd_start_addr <= addr_wgt;
                    dma_rd_start      <= 1'b1;
                    top_state         <= ST_LOAD_WGT_WAIT;
                end
                ST_LOAD_WGT_WAIT: begin
                    if (dma_rd_done) top_state <= ST_LOAD_BIAS;
                end

                ST_LOAD_BIAS: begin
                    dma_target_r      <= DMA_TGT_BIAS;
                    dma_rd_num_trans  <= {8'd0, bias_dma_words};
                    dma_rd_start_addr <= addr_bias;
                    dma_rd_start      <= 1'b1;
                    top_state         <= ST_LOAD_BIAS_WAIT;
                end
                ST_LOAD_BIAS_WAIT: begin
                    if (dma_rd_done) begin
                        rb_r       <= 12'd0;
                        top_state  <= ST_RB_DMA_IFM;
                    end
                end

                //------------------------------------------------
                // rb_stream 루프 : DMA IFM → CONV → DMA OFM × Co → rb++
                ST_RB_DMA_IFM: begin
                    dma_target_r      <= DMA_TGT_IFM;
                    if (rb_r == 12'd0) begin
                        // 초기 3 row 적재: row 0, 1, 2 (window row -1 은 padding)
                        dma_ifm_row_start_r <= rb_init_first_row;
                        dma_rd_num_trans    <= ifm_dma_init_words;
                        dma_rd_start_addr   <= addr_ifm;
                    end else begin
                        // 이후 2 row 적재: row 2*rb+1, 2*rb+2
                        dma_ifm_row_start_r <= rb_next_first_row;
                        dma_rd_num_trans    <= ifm_dma_next_words;
                        // DRAM byte addr = addr_ifm + (2*rb+1) × entries_per_row × 16 byte
                        dma_rd_start_addr   <= addr_ifm +
                            (({20'd0, rb_next_first_row} *
                              {16'd0, entries_per_row}) << 4);
                    end
                    dma_rd_start <= 1'b1;
                    top_state    <= ST_RB_DMA_IFM_WAIT;
                end
                ST_RB_DMA_IFM_WAIT: begin
                    if (dma_rd_done) top_state <= ST_CONV_START;
                end

                ST_CONV_START: begin
                    conv_start <= 1'b1;
                    top_state  <= ST_CONV_WAIT;
                end
                ST_CONV_WAIT: begin
                    if (conv_done) begin
                        ofm_fil_r <= 12'd0;
                        top_state <= ST_RB_DMA_OFM;
                    end
                end

                //------------------------------------------------
                // OFM DMA : Co 개 filter 각각 ofm_w_half word 씩
                ST_RB_DMA_OFM: begin
                    pool_dma_store_r  <= 1'b0;  // conv 모드: dpram_store_addr_r 직접 사용
                    // dpram addr 시작 = fil × ofm_w_half  ← dpram_store_addr_r 초기값
                    // 그러나 dpram_store_addr_r 의 reset 은 dma_wr_start && pool_dma_store_r 에만 됨
                    // → conv 모드에서는 fil 별 시작 addr 을 별도로 셋업.
                    //   여기서는 dma_wr_indata_req 첫 cycle 이 ofm_dpram_base 를 가리키도록
                    //   별도 메커니즘 필요 — 아래 dpram_store_addr_r 갱신 로직 수정.
                    dma_wr_num_trans  <= {8'd0, lyr_ofm_w_half};
                    dma_wr_start_addr <= ofm_dma_addr;
                    dma_wr_start      <= 1'b1;
                    top_state         <= ST_RB_DMA_OFM_WAIT;
                end
                ST_RB_DMA_OFM_WAIT: begin
                    if (dma_wr_done) begin
                        if (ofm_fil_r == lyr_co - 12'd1) begin
                            top_state <= ST_RB_NEXT;
                        end else begin
                            ofm_fil_r <= ofm_fil_r + 12'd1;
                            top_state <= ST_RB_DMA_OFM;
                        end
                    end
                end

                //------------------------------------------------
                ST_RB_NEXT: begin
                    if (rb_r == lyr_ofm_h_half - 12'd1) begin
                        top_state <= ST_LAYER_NEXT;
                    end else begin
                        rb_r      <= rb_r + 12'd1;
                        top_state <= ST_RB_DMA_IFM;
                    end
                end

                //================================================
                // Pool path
                //================================================
                ST_POOL_DMA_IFM: begin
                    dma_target_r      <= DMA_TGT_NONE;
                    pool_dma_load_r   <= 1'b1;
                    // chunk 입력 word = 65536 (고정), 마지막 chunk 도 동일 (정확 나눠 떨어짐 가정)
                    dma_rd_num_trans  <= 20'd65536;
                    // DRAM byte addr = addr_ifm + chunk × 65536 word × 4 byte
                    dma_rd_start_addr <= addr_ifm + ({18'd0, pool_chunk_idx_r} << 18);
                    dma_rd_start      <= 1'b1;
                    pool_in_words_r   <= 20'd65536;
                    top_state         <= ST_POOL_DMA_IFM_WAIT;
                end
                ST_POOL_DMA_IFM_WAIT: begin
                    if (dma_rd_done) begin
                        pool_dma_load_r <= 1'b0;
                        top_state       <= ST_POOL_RUN;
                    end
                end

                ST_POOL_RUN: begin
                    pool_start <= 1'b1;
                    top_state  <= ST_POOL_WAIT;
                end
                ST_POOL_WAIT: begin
                    if (pool_done) top_state <= ST_POOL_DMA_OFM;
                end

                ST_POOL_DMA_OFM: begin
                    pool_dma_store_r  <= 1'b1;
                    // chunk 출력 word = 65536 / 4 = 16384
                    dma_wr_num_trans  <= 20'd16384;
                    // DRAM byte addr = addr_ofm + chunk × 16384 word × 4 byte
                    dma_wr_start_addr <= addr_ofm + ({18'd0, pool_chunk_idx_r} << 16);
                    dma_wr_start      <= 1'b1;
                    top_state         <= ST_POOL_DMA_OFM_WAIT;
                end
                ST_POOL_DMA_OFM_WAIT: begin
                    if (dma_wr_done) begin
                        pool_dma_store_r <= 1'b0;
                        top_state        <= ST_POOL_NEXT;
                    end
                end

                ST_POOL_NEXT: begin
                    if (pool_chunk_idx_r == pool_n_chunks_r - 4'd1) begin
                        top_state <= ST_LAYER_NEXT;
                    end else begin
                        pool_chunk_idx_r <= pool_chunk_idx_r + 4'd1;
                        top_state        <= ST_POOL_DMA_IFM;
                    end
                end

                //================================================
                ST_LAYER_NEXT: begin
                    if (layer_idx == 5'd2) begin     // v1: L0,L1,L2 까지만
                        top_state <= ST_DONE;
                    end else begin
                        layer_idx <= layer_idx + 5'd1;
                        top_state <= ST_INIT;
                    end
                end

                ST_DONE: begin
                    network_done_r <= 1'b1;
                    if (!ap_start) top_state <= ST_IDLE;
                end

                default: top_state <= ST_IDLE;
            endcase
        end
    end

endmodule
