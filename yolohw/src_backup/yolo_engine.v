//----------------------------------------------------------------+
// Project: Deep Learning Hardware Design Contest (AIX2026)
// Team:    베타트론
// Module:  yolo_engine (Tier 1 통합 스캐폴드)
//
// 변경 이유:
//   기존 yolo_engine.v는 "DRAM → 256-entry buffer → DRAM" DMA loopback
//   만 인스턴스화하고 있어서 가속기로 동작하지 않았다.
//   conv_unit / conv_layer_ctrl / max_pool / SPRAM·DPRAM 통합을 위해
//   Top을 phase FSM 기반 compute path로 재작성한다.
//
// 새 데이터 흐름:
//   IDLE → LD_WGT → LD_BIAS → LD_IFM → COMPUTE → ST_OFM → DONE
//                                       ↑
//   axi_dma_rd ──────────────────────────┘  (phase별 destination 라우팅)
//
//   COMPUTE: conv_layer_ctrl → conv_unit → max_pool(bypass) → OFM pack → OFM DPRAM
//   ST_OFM : OFM DPRAM → axi_dma_wr → DRAM
//
// DRAM 주소 약속:
//   ctrl_reg1 + 0                          : weight  (WGT_BYTES)
//   ctrl_reg1 + WGT_BYTES                  : bias    (BIAS_BYTES)
//   ctrl_reg1 + WGT_BYTES + BIAS_BYTES     : IFM     (IFM_BYTES)
//   ctrl_reg2                              : OFM 출력
//   ctrl_reg0[0] = ap_start (kick)
//
// 알려진 한계 (Tier 1.5 / 후속 작업에서 해결할 항목):
//   T1.5-A  [폐기 2026-05-14] 이전에 host hex 를 128-bit aligned + 5 byte zero-pad
//           로 가정했으나, skeleton/bin/log_param/*.hex 는 1 byte/line tight packing.
//           param_wgt_base 와 WGT_BYTES/BIAS_BYTES 를 호스트 hex 실제 사이즈로 원복.
//           이 yolo_engine.v 자체는 강의 12차시 정통 경로(cnn_ctrl + mac_kern + gbuff_param)
//           로 통째로 재작성 예정 → 본 파일의 phased FSM 은 임시 스캐폴드.
//   T1.5-B  max_pool 을 bypass(pool_en=0) 로 고정. 실제 풀링 활성화 시
//           conv_layer_ctrl 의 ofm_wr_addr 생성이 풀링 후 좌표 기준으로 바뀌어야 함.
//   T1.5-C  3×3 sliding window 생성기 없음. 호스트가 im2col 변환한 IFM 을 DRAM 에
//           올려놓아야 함 (window_buf.v 가 들어오면 raw IFM 처리 가능).
//   T1.5-D  Layer 0 OFM(1MB) 은 OFM DPRAM(64KB) 에 들어가지 않음.
//           → 스트리밍/타일링이 다음 큰 작업. 현 스캐폴드는 작은 레이어(Layer 14 등)
//             또는 OFM 잘림을 감수한 부분 검증용.
//   T1.5-E  conv_layer_ctrl 의 출력 좌표 순서는 (row, col, fil) NHWC.
//           C 레퍼런스는 NCHW. 검증 시 SW 측에서 transpose 필요.
//   T1.5-F  spram/dpram_wrapper 의 새 (DW,DEPTH) 조합은 FPGA 합성 단계에서
//           IP Catalog 에 spram_2048x128, spram_128x32, dpram_16384x128,
//           dpram_65536x32 추가 필요. 현재는 sim 모드 (FPGA 매크로 OFF) 동작만 보장.
//
// 2026.05.14 by 베타트론 (Tier 1 scaffold)
//----------------------------------------------------------------+
module yolo_engine #(
    parameter AXI_WIDTH_AD       = 32,
    parameter AXI_WIDTH_ID       = 4,
    parameter AXI_WIDTH_DA       = 32,
    parameter AXI_WIDTH_DS       = AXI_WIDTH_DA/8,
    parameter OUT_BITS_TRANS     = 18,
    parameter MEM_BASE_ADDR      = 'h8000_0000,
    parameter MEM_DATA_BASE_ADDR = 4096
)(
      input                          clk
    , input                          rstn

    , input  [31:0]                  i_ctrl_reg0    // {31:1 reserved, 0: ap_start}
    , input  [31:0]                  i_ctrl_reg1    // Read base in DRAM (weight, bias, IFM)
    , input  [31:0]                  i_ctrl_reg2    // Write base in DRAM (OFM)
    , input  [31:0]                  i_ctrl_reg3    // Reserved

    // AXI master read channel
    , output                         M_ARVALID
    , input                          M_ARREADY
    , output [AXI_WIDTH_AD-1:0]      M_ARADDR
    , output [AXI_WIDTH_ID-1:0]      M_ARID
    , output [7:0]                   M_ARLEN
    , output [2:0]                   M_ARSIZE
    , output [1:0]                   M_ARBURST
    , output [1:0]                   M_ARLOCK
    , output [3:0]                   M_ARCACHE
    , output [2:0]                   M_ARPROT
    , output [3:0]                   M_ARQOS
    , output [3:0]                   M_ARREGION
    , output [3:0]                   M_ARUSER
    , input                          M_RVALID
    , output                         M_RREADY
    , input  [AXI_WIDTH_DA-1:0]      M_RDATA
    , input                          M_RLAST
    , input  [AXI_WIDTH_ID-1:0]      M_RID
    , input  [3:0]                   M_RUSER
    , input  [1:0]                   M_RRESP

    // AXI master write channel
    , output                         M_AWVALID
    , input                          M_AWREADY
    , output [AXI_WIDTH_AD-1:0]      M_AWADDR
    , output [AXI_WIDTH_ID-1:0]      M_AWID
    , output [7:0]                   M_AWLEN
    , output [2:0]                   M_AWSIZE
    , output [1:0]                   M_AWBURST
    , output [1:0]                   M_AWLOCK
    , output [3:0]                   M_AWCACHE
    , output [2:0]                   M_AWPROT
    , output [3:0]                   M_AWQOS
    , output [3:0]                   M_AWREGION
    , output [3:0]                   M_AWUSER
    , output                         M_WVALID
    , input                          M_WREADY
    , output [AXI_WIDTH_DA-1:0]      M_WDATA
    , output [AXI_WIDTH_DS-1:0]      M_WSTRB
    , output                         M_WLAST
    , output [AXI_WIDTH_ID-1:0]      M_WID
    , output [3:0]                   M_WUSER
    , input                          M_BVALID
    , output                         M_BREADY
    , input  [1:0]                   M_BRESP
    , input  [AXI_WIDTH_ID-1:0]      M_BID
    , input                          M_BUSER

    , output                         network_done
    , output                         network_done_led

    // Debug observe (TB 호환)
    , output [AXI_WIDTH_DA-1:0]      read_data
    , output                         read_data_vld
);

`include "user_define_h.v"
`include "user_param_h.v"

localparam BIT_TRANS = 18;

//----------------------------------------------------------------
// 1. DRAM 페이로드 사이즈 (현재는 conv_layer_ctrl 의 3-레이어 체이닝 기준)
//----------------------------------------------------------------
// weight SPRAM 은 128-bit (16-byte) 정렬. filter 끝마다 zero padding 들어감.
//   L0 : 16 filter × ⌈27/16⌉=2 entry  = 32 entry  (5 byte/filter zero-padding 포함)
//   L1 : 32 filter × ⌈144/16⌉=9 entry = 288 entry (정확히 정렬)
//   L2 : 64 filter × ⌈288/16⌉=18 entry= 1152 entry (정확히 정렬)
//   Total: 1472 entry × 16 byte = 23552 byte
//   ※ 호스트 hex 생성 시 L0 weight 의 filter 마다 5 byte zero 삽입 필수.
//     안 그러면 L1/L2 가중치가 5×16 = 80 byte 시프트되어 모두 깨짐.
//
// bias SPRAM 은 32-bit sign-extended INT16.
//   (16+32+64) entry × 4 byte = 448 byte
//   ※ 호스트 hex 생성 시 원본 INT16 을 32-bit 부호확장으로 저장 필수.
//
// IFM/OFM: 평소대로 byte tight.
// Host hex 실제 byte 사이즈 (skeleton/bin/log_param/CONV*_param_*.hex 기준).
//   weight: L0(16×27=432) + L2(32×144=4608) + L4(64×288=18432) = 23472 byte
//   bias  : 16-bit big-endian, (16+32+64)=112 entry × 2 byte = 224 byte
//           RTL 측에서 sign-extend → 32-bit SPRAM 저장은 그대로 유지.
localparam integer WGT_BYTES  = 23472;
localparam integer BIAS_BYTES = 224;
localparam integer IFM_BYTES  = 256*256*3;
localparam integer OFM_BYTES  = 64*64*64;

// AXI 32-bit word count
localparam integer WGT_NUM_W  = (WGT_BYTES  + 3) / 4;
localparam integer BIAS_NUM_W = (BIAS_BYTES + 3) / 4;
localparam integer IFM_NUM_W  = (IFM_BYTES  + 3) / 4;
localparam integer OFM_NUM_W  = (OFM_BYTES  + 3) / 4;

//----------------------------------------------------------------
// 2. Phase FSM
//----------------------------------------------------------------
localparam P_IDLE    = 4'd0,
           P_LD_WGT  = 4'd1,
           P_LD_BIAS = 4'd2,
           P_LD_IFM  = 4'd3,
           P_COMPUTE = 4'd4,
           P_ST_OFM  = 4'd5,
           P_DONE    = 4'd6;

reg [3:0] phase, next_phase;

//----------------------------------------------------------------
// 3. CSR / handshake
//----------------------------------------------------------------
reg ap_start;
reg interrupt;

assign network_done     = interrupt;
assign network_done_led = interrupt;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        ap_start  <= 1'b0;
        interrupt <= 1'b0;
    end
    else begin
        // ap_start: ctrl_reg0[0] 가 0→1 상승 시 set, DONE 도달 시 clear
        if (!ap_start && i_ctrl_reg0[0])
            ap_start <= 1'b1;
        else if (phase == P_DONE)
            ap_start <= 1'b0;

        // interrupt: DONE 진입 시 set, 다음 ctrl_reg0[0] 펄스에서 clear
        if (i_ctrl_reg0[0])
            interrupt <= 1'b0;
        else if (phase == P_DONE)
            interrupt <= 1'b1;
    end
end

//----------------------------------------------------------------
// 4. DMA Read / Write wire / control
//----------------------------------------------------------------
reg                       dma_rd_start;
reg  [31:0]               dma_rd_addr;
reg  [BIT_TRANS-1:0]      dma_rd_num_trans;
wire                      dma_rd_done;
wire [AXI_WIDTH_DA-1:0]   dma_rd_data;
wire                      dma_rd_data_vld;
wire [BIT_TRANS-1:0]      dma_rd_data_cnt;

reg                       dma_wr_start;
reg  [31:0]               dma_wr_addr;
reg  [BIT_TRANS-1:0]      dma_wr_num_trans;
wire                      dma_wr_done;
wire                      wr_indata_req;
wire [AXI_WIDTH_DA-1:0]   wr_indata;

assign read_data     = dma_rd_data;
assign read_data_vld = dma_rd_data_vld;

//----------------------------------------------------------------
// 5. conv_layer_ctrl ↔ buffer 인터페이스
//----------------------------------------------------------------
reg                  conv_start;
wire                 conv_done;
wire [1:0]           current_layer;
wire                 buf_sel_unused;

wire                 cu_vld_i;
wire [127:0]         cu_win;
wire [127:0]         cu_din;
wire [4:0]           cu_num_cycles;
wire signed [31:0]   cu_bias;
wire [4:0]           cu_shift_amount;
wire [7:0]           cu_pixel_out;
wire                 cu_output_valid;

wire [10:0]          clc_wgt_addr;
wire                 clc_wgt_cs;
wire                 clc_wgt_we;
wire [127:0]         clc_wgt_rdata;

wire [6:0]           clc_bias_addr;
wire                 clc_bias_cs;
wire                 clc_bias_we;
wire [31:0]          clc_bias_rdata;

wire [16:0]          clc_ifm_rd_addr;
wire                 clc_ifm_rd_en;
wire [127:0]         clc_ifm_rd_data;

wire [16:0]          clc_ofm_wr_addr;   // 미사용 (OFM pack 카운터가 따로 관리)
wire                 clc_ofm_wr_en;     // 미사용
wire [7:0]           clc_ofm_wr_data;   // 미사용 (max_pool.pool_out 으로 대체)

//----------------------------------------------------------------
// 6. Load-phase 로더 레지스터
//----------------------------------------------------------------
// 가중치 : 4×32-bit AXI 워드 → 128-bit SPRAM 엔트리
reg  [10:0]          wgt_ld_addr;
reg  [1:0]           wgt_ld_word;
reg  [127:0]         wgt_ld_data;
reg                  wgt_ld_we;

// 바이어스 : 32-bit 1:1
reg  [6:0]           bias_ld_addr;
reg  [31:0]          bias_ld_data;
reg                  bias_ld_we;

// IFM : 4×32-bit → 128-bit DPRAM
reg  [13:0]          ifm_ld_addr;
reg  [1:0]           ifm_ld_word;
reg  [127:0]         ifm_ld_data;
reg                  ifm_ld_we;

//----------------------------------------------------------------
// 7. OFM packer : pool_out(8-bit) 4개 → 32-bit DPRAM 엔트리
//----------------------------------------------------------------
wire [7:0]   pool_out;
wire         pool_valid;

reg  [31:0]  ofm_pk_wdata;
reg  [1:0]   ofm_pk_byte;
reg  [15:0]  ofm_pk_waddr;     // 32-bit 워드 주소 (0..65535)
reg          ofm_pk_we;

// Store-phase 측 read 카운터
reg  [15:0]  ofm_rd_addr;

//----------------------------------------------------------------
// 8. SPRAM / DPRAM 인스턴스 + 포트 mux (load vs compute)
//----------------------------------------------------------------
wire [10:0]  wgt_mux_addr  = (phase == P_LD_WGT)  ? wgt_ld_addr   : clc_wgt_addr;
wire         wgt_mux_we    = (phase == P_LD_WGT)  ? wgt_ld_we     : 1'b0;
wire [127:0] wgt_mux_wdata = wgt_ld_data;

spram_wrapper #(.DW(128), .AW(11), .DEPTH(2048))
u_weight_spram (
    .clk   (clk),
    .addr  (wgt_mux_addr),
    .we    (wgt_mux_we),
    .cs    (1'b1),
    .wdata (wgt_mux_wdata),
    .rdata (clc_wgt_rdata)
);

wire [6:0]   bias_mux_addr  = (phase == P_LD_BIAS) ? bias_ld_addr : clc_bias_addr;
wire         bias_mux_we    = (phase == P_LD_BIAS) ? bias_ld_we   : 1'b0;
wire [31:0]  bias_mux_wdata = bias_ld_data;

spram_wrapper #(.DW(32), .AW(7), .DEPTH(128))
u_bias_spram (
    .clk   (clk),
    .addr  (bias_mux_addr),
    .we    (bias_mux_we),
    .cs    (1'b1),
    .wdata (bias_mux_wdata),
    .rdata (clc_bias_rdata)
);

// IFM DPRAM : port A = load 쓰기, port B = compute 읽기
dpram_wrapper #(.DW(128), .AW(14), .DEPTH(16384))
u_ifm_dpram (
    .clk   (clk),
    .ena   (1'b1),
    .addra (ifm_ld_addr),
    .wea   (ifm_ld_we),
    .dia   (ifm_ld_data),
    .enb   (clc_ifm_rd_en),
    .addrb (clc_ifm_rd_addr[13:0]),
    .dob   (clc_ifm_rd_data)
);

// OFM DPRAM : port A = compute 쓰기 (packer), port B = store 읽기 (DMA)
dpram_wrapper #(.DW(32), .AW(16), .DEPTH(65536))
u_ofm_dpram (
    .clk   (clk),
    .ena   (1'b1),
    .addra (ofm_pk_waddr),
    .wea   (ofm_pk_we),
    .dia   (ofm_pk_wdata),
    .enb   (1'b1),
    .addrb (ofm_rd_addr),
    .dob   (wr_indata)
);

//----------------------------------------------------------------
// 9. 데이터패스 인스턴스
//----------------------------------------------------------------
conv_unit u_conv_unit (
    .clk          (clk),
    .rstn         (rstn),
    .vld_i        (cu_vld_i),
    .win          (cu_win),
    .din          (cu_din),
    .num_cycles   (cu_num_cycles),
    .bias         (cu_bias),
    .shift_amount (cu_shift_amount),
    .pixel_out    (cu_pixel_out),
    .output_valid (cu_output_valid)
);

// SCAFFOLD: max_pool bypass 모드 (pool_en=0). Tier 1.5 에서 layer-aware 제어 추가.
max_pool u_max_pool (
    .clk         (clk),
    .rstn        (rstn),
    .pool_en     (1'b0),
    .pixel_valid (cu_output_valid),
    .pixel_in    (cu_pixel_out),
    .pool_out    (pool_out),
    .pool_valid  (pool_valid)
);

conv_layer_ctrl u_conv_layer_ctrl (
    .clk             (clk),
    .rstn            (rstn),
    .start           (conv_start),
    .done            (conv_done),
    .cu_vld_i        (cu_vld_i),
    .cu_win          (cu_win),
    .cu_din          (cu_din),
    .cu_num_cycles   (cu_num_cycles),
    .cu_bias         (cu_bias),
    .cu_shift_amount (cu_shift_amount),
    .cu_pixel_out    (cu_pixel_out),
    .cu_output_valid (cu_output_valid),
    .wgt_addr        (clc_wgt_addr),
    .wgt_cs          (clc_wgt_cs),
    .wgt_we          (clc_wgt_we),
    .wgt_rdata       (clc_wgt_rdata),
    .bias_addr       (clc_bias_addr),
    .bias_cs         (clc_bias_cs),
    .bias_we         (clc_bias_we),
    .bias_rdata      (clc_bias_rdata),
    .ifm_rd_addr     (clc_ifm_rd_addr),
    .ifm_rd_en       (clc_ifm_rd_en),
    .ifm_rd_data     (clc_ifm_rd_data),
    .ofm_wr_addr     (clc_ofm_wr_addr),
    .ofm_wr_en       (clc_ofm_wr_en),
    .ofm_wr_data     (clc_ofm_wr_data),
    .buf_sel         (buf_sel_unused),
    .current_layer   (current_layer)
);

//----------------------------------------------------------------
// 10. AXI DMA Read
//----------------------------------------------------------------
axi_dma_rd #(
    .BITS_TRANS    (BIT_TRANS),
    .OUT_BITS_TRANS(OUT_BITS_TRANS),
    .AXI_WIDTH_USER(1),
    .AXI_WIDTH_ID  (AXI_WIDTH_ID),
    .AXI_WIDTH_AD  (AXI_WIDTH_AD),
    .AXI_WIDTH_DA  (AXI_WIDTH_DA),
    .AXI_WIDTH_DS  (AXI_WIDTH_DS))
u_dma_read (
    .M_ARVALID  (M_ARVALID),
    .M_ARREADY  (M_ARREADY),
    .M_ARADDR   (M_ARADDR),
    .M_ARID     (M_ARID),
    .M_ARLEN    (M_ARLEN),
    .M_ARSIZE   (M_ARSIZE),
    .M_ARBURST  (M_ARBURST),
    .M_ARLOCK   (M_ARLOCK),
    .M_ARCACHE  (M_ARCACHE),
    .M_ARPROT   (M_ARPROT),
    .M_ARQOS    (M_ARQOS),
    .M_ARREGION (M_ARREGION),
    .M_ARUSER   (M_ARUSER),
    .M_RVALID   (M_RVALID),
    .M_RREADY   (M_RREADY),
    .M_RDATA    (M_RDATA),
    .M_RLAST    (M_RLAST),
    .M_RID      (M_RID),
    .M_RUSER    (M_RUSER),
    .M_RRESP    (M_RRESP),
    .start_dma  (dma_rd_start),
    .num_trans  (dma_rd_num_trans),
    .start_addr (dma_rd_addr),
    .data_o     (dma_rd_data),
    .data_vld_o (dma_rd_data_vld),
    .data_cnt_o (dma_rd_data_cnt),
    .done_o     (dma_rd_done),
    .clk        (clk),
    .rstn       (rstn)
);

//----------------------------------------------------------------
// 11. AXI DMA Write
//----------------------------------------------------------------
axi_dma_wr #(
    .BITS_TRANS    (BIT_TRANS),
    .OUT_BITS_TRANS(BIT_TRANS),
    .AXI_WIDTH_USER(1),
    .AXI_WIDTH_ID  (AXI_WIDTH_ID),
    .AXI_WIDTH_AD  (AXI_WIDTH_AD),
    .AXI_WIDTH_DA  (AXI_WIDTH_DA),
    .AXI_WIDTH_DS  (AXI_WIDTH_DS))
u_dma_write (
    .M_AWID      (M_AWID),
    .M_AWADDR    (M_AWADDR),
    .M_AWLEN     (M_AWLEN),
    .M_AWSIZE    (M_AWSIZE),
    .M_AWBURST   (M_AWBURST),
    .M_AWLOCK    (M_AWLOCK),
    .M_AWCACHE   (M_AWCACHE),
    .M_AWPROT    (M_AWPROT),
    .M_AWREGION  (M_AWREGION),
    .M_AWQOS     (M_AWQOS),
    .M_AWVALID   (M_AWVALID),
    .M_AWREADY   (M_AWREADY),
    .M_AWUSER    (M_AWUSER),
    .M_WID       (M_WID),
    .M_WDATA     (M_WDATA),
    .M_WSTRB     (M_WSTRB),
    .M_WLAST     (M_WLAST),
    .M_WVALID    (M_WVALID),
    .M_WREADY    (M_WREADY),
    .M_WUSER     (M_WUSER),
    .M_BUSER     (M_BUSER),
    .M_BID       (M_BID),
    .M_BRESP     (M_BRESP),
    .M_BVALID    (M_BVALID),
    .M_BREADY    (M_BREADY),
    .start_dma   (dma_wr_start),
    .num_trans   (dma_wr_num_trans),
    .start_addr  (dma_wr_addr),
    .indata      (wr_indata),
    .indata_req_o(wr_indata_req),
    .done_o      (dma_wr_done),
    .fail_check  (),
    .clk         (clk),
    .rstn        (rstn)
);

//----------------------------------------------------------------
// 12. Phase 다음상태 + 트리거
//----------------------------------------------------------------
always @(*) begin
    next_phase = phase;
    case (phase)
        P_IDLE    : if (ap_start)    next_phase = P_LD_WGT;
        P_LD_WGT  : if (dma_rd_done) next_phase = P_LD_BIAS;
        P_LD_BIAS : if (dma_rd_done) next_phase = P_LD_IFM;
        P_LD_IFM  : if (dma_rd_done) next_phase = P_COMPUTE;
        P_COMPUTE : if (conv_done)   next_phase = P_ST_OFM;
        P_ST_OFM  : if (dma_wr_done) next_phase = P_DONE;
        P_DONE    :                  next_phase = P_IDLE;
        default   :                  next_phase = P_IDLE;
    endcase
end

always @(posedge clk or negedge rstn) begin
    if (!rstn) phase <= P_IDLE;
    else       phase <= next_phase;
end

//----------------------------------------------------------------
// 13. DMA / conv 트리거 펄스 (phase 진입 시 1 클록 high)
//----------------------------------------------------------------
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        dma_rd_start     <= 1'b0;
        dma_rd_addr      <= 32'd0;
        dma_rd_num_trans <= {BIT_TRANS{1'b0}};
        dma_wr_start     <= 1'b0;
        dma_wr_addr      <= 32'd0;
        dma_wr_num_trans <= {BIT_TRANS{1'b0}};
        conv_start       <= 1'b0;
    end
    else begin
        // 모두 기본 0, 전이 시점에만 1
        dma_rd_start <= 1'b0;
        dma_wr_start <= 1'b0;
        conv_start   <= 1'b0;

        if (phase == P_IDLE && next_phase == P_LD_WGT) begin
            dma_rd_addr      <= i_ctrl_reg1;
            dma_rd_num_trans <= WGT_NUM_W[BIT_TRANS-1:0];
            dma_rd_start     <= 1'b1;
        end
        else if (phase == P_LD_WGT && next_phase == P_LD_BIAS) begin
            dma_rd_addr      <= i_ctrl_reg1 + WGT_BYTES;
            dma_rd_num_trans <= BIAS_NUM_W[BIT_TRANS-1:0];
            dma_rd_start     <= 1'b1;
        end
        else if (phase == P_LD_BIAS && next_phase == P_LD_IFM) begin
            dma_rd_addr      <= i_ctrl_reg1 + WGT_BYTES + BIAS_BYTES;
            dma_rd_num_trans <= IFM_NUM_W[BIT_TRANS-1:0];
            dma_rd_start     <= 1'b1;
        end
        else if (phase == P_LD_IFM && next_phase == P_COMPUTE) begin
            conv_start <= 1'b1;
        end
        else if (phase == P_COMPUTE && next_phase == P_ST_OFM) begin
            dma_wr_addr      <= i_ctrl_reg2;
            dma_wr_num_trans <= OFM_NUM_W[BIT_TRANS-1:0];
            dma_wr_start     <= 1'b1;
        end
    end
end

//----------------------------------------------------------------
// 14. Weight 로더 : 4×32-bit → 128-bit SPRAM
//----------------------------------------------------------------
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        wgt_ld_addr <= 11'd0;
        wgt_ld_word <= 2'd0;
        wgt_ld_data <= 128'd0;
        wgt_ld_we   <= 1'b0;
    end
    else begin
        wgt_ld_we <= 1'b0;

        if (phase == P_IDLE) begin
            wgt_ld_addr <= 11'd0;
            wgt_ld_word <= 2'd0;
        end
        else if (phase == P_LD_WGT && dma_rd_data_vld) begin
            case (wgt_ld_word)
                2'd0: wgt_ld_data[ 31:  0] <= dma_rd_data;
                2'd1: wgt_ld_data[ 63: 32] <= dma_rd_data;
                2'd2: wgt_ld_data[ 95: 64] <= dma_rd_data;
                2'd3: wgt_ld_data[127: 96] <= dma_rd_data;
            endcase
            if (wgt_ld_word == 2'd3) begin
                wgt_ld_we   <= 1'b1;
                wgt_ld_word <= 2'd0;
            end
            else begin
                wgt_ld_word <= wgt_ld_word + 1'b1;
            end
        end

        if (wgt_ld_we)
            wgt_ld_addr <= wgt_ld_addr + 1'b1;
    end
end

//----------------------------------------------------------------
// 15. Bias 로더 : 32-bit 1:1 SPRAM (★Tier 1.5 : sign-extend 처리 필요)
//   현재 hex 가 INT16 두 개를 32-bit 워드에 패킹한 형태면 두 엔트리로 분리 필요.
//   여기선 1워드 = 1 bias 가정. hex 생성 측에서 32-bit sign-extended 로 저장 권장.
//----------------------------------------------------------------
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        bias_ld_addr <= 7'd0;
        bias_ld_data <= 32'd0;
        bias_ld_we   <= 1'b0;
    end
    else begin
        bias_ld_we <= 1'b0;

        if (phase == P_IDLE) begin
            bias_ld_addr <= 7'd0;
        end
        else if (phase == P_LD_BIAS && dma_rd_data_vld) begin
            bias_ld_data <= dma_rd_data;
            bias_ld_we   <= 1'b1;
        end

        if (bias_ld_we)
            bias_ld_addr <= bias_ld_addr + 1'b1;
    end
end

//----------------------------------------------------------------
// 16. IFM 로더 : 4×32-bit → 128-bit DPRAM (port A)
//----------------------------------------------------------------
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        ifm_ld_addr <= 14'd0;
        ifm_ld_word <= 2'd0;
        ifm_ld_data <= 128'd0;
        ifm_ld_we   <= 1'b0;
    end
    else begin
        ifm_ld_we <= 1'b0;

        if (phase == P_IDLE) begin
            ifm_ld_addr <= 14'd0;
            ifm_ld_word <= 2'd0;
        end
        else if (phase == P_LD_IFM && dma_rd_data_vld) begin
            case (ifm_ld_word)
                2'd0: ifm_ld_data[ 31:  0] <= dma_rd_data;
                2'd1: ifm_ld_data[ 63: 32] <= dma_rd_data;
                2'd2: ifm_ld_data[ 95: 64] <= dma_rd_data;
                2'd3: ifm_ld_data[127: 96] <= dma_rd_data;
            endcase
            if (ifm_ld_word == 2'd3) begin
                ifm_ld_we   <= 1'b1;
                ifm_ld_word <= 2'd0;
            end
            else begin
                ifm_ld_word <= ifm_ld_word + 1'b1;
            end
        end

        if (ifm_ld_we)
            ifm_ld_addr <= ifm_ld_addr + 1'b1;
    end
end

//----------------------------------------------------------------
// 17. OFM packer : pool_out (8-bit) 4개 → 32-bit DPRAM 엔트리
//   - pool_valid 마다 1 byte 누적
//   - 4 byte 채워지면 ofm_pk_we = 1 펄스, 주소 +1
//----------------------------------------------------------------
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        ofm_pk_wdata <= 32'd0;
        ofm_pk_byte  <= 2'd0;
        ofm_pk_waddr <= 16'd0;
        ofm_pk_we    <= 1'b0;
    end
    else begin
        ofm_pk_we <= 1'b0;

        // compute 시작 시 OFM 라이트 포인터 리셋
        if (phase == P_LD_IFM && next_phase == P_COMPUTE) begin
            ofm_pk_byte  <= 2'd0;
            ofm_pk_waddr <= 16'd0;
        end

        if (pool_valid) begin
            case (ofm_pk_byte)
                2'd0: ofm_pk_wdata[ 7: 0] <= pool_out;
                2'd1: ofm_pk_wdata[15: 8] <= pool_out;
                2'd2: ofm_pk_wdata[23:16] <= pool_out;
                2'd3: ofm_pk_wdata[31:24] <= pool_out;
            endcase
            if (ofm_pk_byte == 2'd3) begin
                ofm_pk_we   <= 1'b1;       // 4 byte 채워졌으니 1워드 write
                ofm_pk_byte <= 2'd0;
            end
            else begin
                ofm_pk_byte <= ofm_pk_byte + 1'b1;
            end
        end

        if (ofm_pk_we)
            ofm_pk_waddr <= ofm_pk_waddr + 1'b1;
    end
end

//----------------------------------------------------------------
// 18. OFM 스트리머 : DMA write indata 카운터
//   axi_dma_wr 의 indata_req_o 가 1일 때마다 ofm_rd_addr 진행.
//   DPRAM read latency = 1 → indata 는 1 사이클 지연되어 도착 (axi_dma_wr 내부에서
//   허용하는지 확인 필요. 안 맞으면 미리 1 사이클 prefetch 추가 — Tier 1.5).
//----------------------------------------------------------------
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        ofm_rd_addr <= 16'd0;
    end
    else begin
        if (phase == P_COMPUTE && next_phase == P_ST_OFM) begin
            ofm_rd_addr <= 16'd0;
        end
        else if (phase == P_ST_OFM && wr_indata_req) begin
            ofm_rd_addr <= ofm_rd_addr + 1'b1;
        end
    end
end

endmodule
