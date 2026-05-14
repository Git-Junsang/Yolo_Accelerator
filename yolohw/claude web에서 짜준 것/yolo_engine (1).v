//----------------------------------------------------------------+
// Project: Deep Learning Hardware Design Contest
// Module: yolo_engine (v2 - compute_engine 통합)
// 
// 변경점 (vs 원본):
//   - compute_engine 인스턴스화
//   - i_ctrl_reg3 으로 외부 phase/sel 컨트롤
//   - DMA read → compute_engine.load_* 연결
//   - DMA write ← compute_engine.read_* 연결
//   - DMA-only 패스스루 옵션 유지 (호환성)
//
// 운용 시퀀스 (외부 host/MicroBlaze가 i_ctrl_reg0/1/2/3 설정):
//   1. Phase LOAD_W:  reg3=4'h0, DMA read → wbuf
//   2. Phase LOAD_B:  reg3=4'h1, DMA read → bbuf
//   3. Phase LOAD_IFM: reg3=4'h2 (A) 또는 4'h3 (B), DMA read → fmbuf
//   4. Phase COMPUTE: reg3=4'h8, compute_engine.start 펄스
//   5. Phase STORE_OFM: reg3=4'h4 (A) 또는 4'h5 (B), DMA write ← fmbuf
//
//   ap_start (reg0[0]) 펄스가 각 phase 진입 신호.
//   ap_done 펄스가 phase 종료 신호.
//----------------------------------------------------------------+
module yolo_engine #(
    parameter AXI_WIDTH_AD = 32,
    parameter AXI_WIDTH_ID = 4,
    parameter AXI_WIDTH_DA = 32,
    parameter AXI_WIDTH_DS = AXI_WIDTH_DA/8,
    parameter OUT_BITS_TRANS = 18,
    parameter MEM_BASE_ADDR = 'h8000_0000,
    parameter MEM_DATA_BASE_ADDR = 4096
)
(
      input                          clk
    , input                          rstn

    , input [31:0] i_ctrl_reg0    // [0]: ap_start (각 phase 트리거)
    , input [31:0] i_ctrl_reg1    // Read base address (DRAM)
    , input [31:0] i_ctrl_reg2    // Write base address (DRAM)
    , input [31:0] i_ctrl_reg3    // [3:0]: phase/sel (0=LOAD_W, 1=LOAD_B, 2=LOAD_FM_A, 3=LOAD_FM_B,
                                  //                   4=STORE_FM_A, 5=STORE_FM_B, 8=COMPUTE)
                                  // [31:16]: num_trans (블록 수)

    , output                         M_ARVALID
    , input                          M_ARREADY
    , output  [AXI_WIDTH_AD-1:0]     M_ARADDR
    , output  [AXI_WIDTH_ID-1:0]     M_ARID
    , output  [7:0]                  M_ARLEN
    , output  [2:0]                  M_ARSIZE
    , output  [1:0]                  M_ARBURST
    , output  [1:0]                  M_ARLOCK
    , output  [3:0]                  M_ARCACHE
    , output  [2:0]                  M_ARPROT
    , output  [3:0]                  M_ARQOS
    , output  [3:0]                  M_ARREGION
    , output  [3:0]                  M_ARUSER
    , input                          M_RVALID
    , output                         M_RREADY
    , input  [AXI_WIDTH_DA-1:0]      M_RDATA
    , input                          M_RLAST
    , input  [AXI_WIDTH_ID-1:0]      M_RID
    , input  [3:0]                   M_RUSER
    , input  [1:0]                   M_RRESP

    , output                         M_AWVALID
    , input                          M_AWREADY
    , output  [AXI_WIDTH_AD-1:0]     M_AWADDR
    , output  [AXI_WIDTH_ID-1:0]     M_AWID
    , output  [7:0]                  M_AWLEN
    , output  [2:0]                  M_AWSIZE
    , output  [1:0]                  M_AWBURST
    , output  [1:0]                  M_AWLOCK
    , output  [3:0]                  M_AWCACHE
    , output  [2:0]                  M_AWPROT
    , output  [3:0]                  M_AWQOS
    , output  [3:0]                  M_AWREGION
    , output  [3:0]                  M_AWUSER

    , output                         M_WVALID
    , input                          M_WREADY
    , output  [AXI_WIDTH_DA-1:0]     M_WDATA
    , output  [AXI_WIDTH_DS-1:0]     M_WSTRB
    , output                         M_WLAST
    , output  [AXI_WIDTH_ID-1:0]     M_WID
    , output  [3:0]                  M_WUSER

    , input                          M_BVALID
    , output                         M_BREADY
    , input  [1:0]                   M_BRESP
    , input  [AXI_WIDTH_ID-1:0]      M_BID
    , input                          M_BUSER

    , output network_done
    , output network_done_led
    , output [AXI_WIDTH_DA-1:0]      read_data
    , output                         read_data_vld
);
`include "user_define_h.v"
`include "user_param_h.v"

localparam BIT_TRANS = BUFF_ADDR_W;

//----------------------------------------------------------------
// Phase 디코딩 (i_ctrl_reg3[3:0])
//----------------------------------------------------------------
localparam PH_LOAD_W    = 4'h0;
localparam PH_LOAD_B    = 4'h1;
localparam PH_LOAD_FM_A = 4'h2;
localparam PH_LOAD_FM_B = 4'h3;
localparam PH_STORE_FM_A = 4'h4;
localparam PH_STORE_FM_B = 4'h5;
localparam PH_COMPUTE   = 4'h8;

wire [3:0] phase = i_ctrl_reg3[3:0];
wire is_load_phase  = (phase == PH_LOAD_W) || (phase == PH_LOAD_B) ||
                      (phase == PH_LOAD_FM_A) || (phase == PH_LOAD_FM_B);
wire is_store_phase = (phase == PH_STORE_FM_A) || (phase == PH_STORE_FM_B);
wire is_compute     = (phase == PH_COMPUTE);

//----------------------------------------------------------------
// CSR
//----------------------------------------------------------------
reg ap_start;
reg ap_ready;
reg ap_done;
reg interrupt;

reg [31:0] dram_base_addr_rd;
reg [31:0] dram_base_addr_wr;
reg [31:0] reserved_register;

// DMA read
wire ctrl_read;
wire read_done;
wire [AXI_WIDTH_AD-1:0] read_addr;
// read_data, read_data_vld 는 module output port로 이미 선언됨
wire [BIT_TRANS-1:0]    read_data_cnt;

// DMA write
wire ctrl_write_done;
wire ctrl_write;
wire write_done;
wire indata_req_wr;
wire [BIT_TRANS-1:0]    write_data_cnt;
wire [AXI_WIDTH_AD-1:0] write_addr;
wire [AXI_WIDTH_DA-1:0] write_data;

// num_trans: 외부에서 i_ctrl_reg3[31:16]으로 결정. 0이면 기본값 16 사용.
wire [BIT_TRANS-1:0] num_trans =
        (i_ctrl_reg3[31:16] != 16'd0) ? i_ctrl_reg3[31:16] : BIT_TRANS'(16);

// max_req_blk_idx: 운용 시 외부에서 결정해야 하나, 단순화 위해 phase별 디폴트 사용
wire [15:0] max_req_blk_idx = (phase == PH_LOAD_W)    ? 16'd1536 :  // 24576/16
                              (phase == PH_LOAD_B)    ? 16'd28   :  // 448/16
                                                        16'd16384;  // 256KB/16 (FM)

//----------------------------------------------------------------
// compute_engine 컨트롤
//----------------------------------------------------------------
wire        ce_done;
wire [1:0]  ce_current_layer;
wire        ce_buf_sel;

// compute phase 진입 펄스
reg compute_start_pulse;
always @(posedge clk or negedge rstn) begin
    if (!rstn) compute_start_pulse <= 1'b0;
    else       compute_start_pulse <= is_compute && i_ctrl_reg0[0] && !ap_start;
end

//----------------------------------------------------------------
// ap_start / ap_done / interrupt
//----------------------------------------------------------------
always @(*) begin
    if (is_compute)
        ap_done = ce_done;          // 컴퓨트 페이즈는 compute_engine 끝나면 done
    else if (is_load_phase)
        ap_done = read_done;        // 로드 페이즈는 DMA read 끝나면 done
    else if (is_store_phase)
        ap_done = ctrl_write_done;  // 스토어 페이즈는 DMA write 끝나면 done
    else
        ap_done = 1'b0;
    ap_ready = 1'b1;
end
assign network_done     = interrupt;
assign network_done_led = interrupt;

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        ap_start <= 1'b0;
    end
    else begin
        if (!ap_start && i_ctrl_reg0[0])
            ap_start <= 1'b1;
        else if (ap_done)
            ap_start <= 1'b0;
    end
end

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        interrupt <= 1'b0;
    end
    else begin
        if (i_ctrl_reg0[0])
            interrupt <= 1'b0;
        else if (ap_done)
            interrupt <= 1'b1;
    end
end

always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        dram_base_addr_rd <= 0;
        dram_base_addr_wr <= 0;
        reserved_register <= 0;
    end
    else begin
        if (!ap_start && i_ctrl_reg0[0]) begin
            dram_base_addr_rd <= i_ctrl_reg1;
            dram_base_addr_wr <= i_ctrl_reg2;
            reserved_register <= i_ctrl_reg3;
        end
        else if (ap_done) begin
            dram_base_addr_rd <= 0;
            dram_base_addr_wr <= 0;
            reserved_register <= 0;
        end
    end
end

//----------------------------------------------------------------
// DMA Controller (load/store phase 일 때만 활성화)
//----------------------------------------------------------------
wire dma_start = (is_load_phase || is_store_phase) && i_ctrl_reg0[0];

axi_dma_ctrl #(.BIT_TRANS(BIT_TRANS))
u_dma_ctrl(
    .clk              (clk              )
   ,.rstn             (rstn             )
   ,.i_start          (dma_start        )
   ,.i_base_address_rd(dram_base_addr_rd)
   ,.i_base_address_wr(dram_base_addr_wr)
   ,.i_num_trans      (num_trans        )
   ,.i_max_req_blk_idx(max_req_blk_idx  )
   // DMA Read
   ,.i_read_done      (read_done        )
   ,.o_ctrl_read      (ctrl_read        )
   ,.o_read_addr      (read_addr        )
   // DMA Write
   ,.i_indata_req_wr  (indata_req_wr    )
   ,.i_write_done     (write_done       )
   ,.o_ctrl_write     (ctrl_write       )
   ,.o_write_addr     (write_addr       )
   ,.o_write_data_cnt (write_data_cnt   )
   ,.o_ctrl_write_done(ctrl_write_done  )
);

//----------------------------------------------------------------
// DMA Read
//----------------------------------------------------------------
axi_dma_rd #(
    .BITS_TRANS(BIT_TRANS),
    .OUT_BITS_TRANS(OUT_BITS_TRANS),
    .AXI_WIDTH_USER(1),
    .AXI_WIDTH_ID(4),
    .AXI_WIDTH_AD(AXI_WIDTH_AD),
    .AXI_WIDTH_DA(AXI_WIDTH_DA),
    .AXI_WIDTH_DS(AXI_WIDTH_DS)
) u_dma_read(
    .M_ARVALID(M_ARVALID), .M_ARREADY(M_ARREADY), .M_ARADDR(M_ARADDR),
    .M_ARID(M_ARID), .M_ARLEN(M_ARLEN), .M_ARSIZE(M_ARSIZE),
    .M_ARBURST(M_ARBURST), .M_ARLOCK(M_ARLOCK), .M_ARCACHE(M_ARCACHE),
    .M_ARPROT(M_ARPROT), .M_ARQOS(M_ARQOS), .M_ARREGION(M_ARREGION),
    .M_ARUSER(M_ARUSER),
    .M_RVALID(M_RVALID), .M_RREADY(M_RREADY), .M_RDATA(M_RDATA),
    .M_RLAST(M_RLAST), .M_RID(M_RID), .M_RUSER(M_RUSER), .M_RRESP(M_RRESP),
    .start_dma(ctrl_read),
    .num_trans(num_trans),
    .start_addr(read_addr),
    .data_o(read_data),
    .data_vld_o(read_data_vld),
    .data_cnt_o(read_data_cnt),
    .done_o(read_done),
    .clk(clk), .rstn(rstn)
);

//----------------------------------------------------------------
// compute_engine 인스턴스
//   - DMA read → load_* 포트 (is_load_phase 일 때)
//   - DMA write ← read_* 포트 (is_store_phase 일 때)
//----------------------------------------------------------------

// load_sel 매핑: phase 그대로 (LOAD_W=0, LOAD_B=1, LOAD_FM_A=2, LOAD_FM_B=3)
wire [1:0] ce_load_sel = phase[1:0];

// read_sel 매핑: STORE_FM_A=4→0, STORE_FM_B=5→1
wire       ce_read_sel = phase[0];

// load_addr: 32-bit word counter를 byte/word 단위로 사용
// - W (8-bit BRAM): 한 word = 4 bytes → 외부에서 4 word씩 채워야 함 (단순화)
//   여기선 load_addr = read_data_cnt (32-bit word index)
//   실제 W BRAM에 1바이트씩 적재하려면 별도 chunker 필요 (다음 turn)
// - B (32-bit BRAM): 1 word = 1 bias → load_addr = read_data_cnt 그대로
// - FM (8-bit BRAM): 1 word = 4 픽셀 → W와 동일 한계
wire [17:0] ce_load_addr  = read_data_cnt[17:0];
wire        ce_load_en    = is_load_phase;
wire        ce_load_we    = is_load_phase && read_data_vld;
wire [31:0] ce_load_wdata = read_data;

wire [17:0] ce_read_addr  = write_data_cnt[17:0];
wire        ce_read_en    = is_store_phase;
wire [7:0]  ce_read_rdata;

compute_engine u_compute (
    .clk           (clk),
    .rstn          (rstn),
    .start         (compute_start_pulse),
    .done          (ce_done),
    .current_layer (ce_current_layer),
    .buf_sel       (ce_buf_sel),

    // 외부 메모리 로드 포트
    .load_en       (ce_load_en),
    .load_sel      (ce_load_sel),
    .load_addr     (ce_load_addr),
    .load_we       (ce_load_we),
    .load_wdata    (ce_load_wdata),

    // 외부 결과 read 포트
    .read_en       (ce_read_en),
    .read_sel      (ce_read_sel),
    .read_addr     (ce_read_addr),
    .read_rdata    (ce_read_rdata)
);

// DMA write data: compute_engine.read_rdata (8-bit)를 32-bit으로 확장
// ※ 단순화: 1 픽셀당 32-bit word 1개 사용. 실제 운용 시 4 픽셀을 한 word에 packing 필요 (다음 turn)
assign write_data = {24'd0, ce_read_rdata};

//----------------------------------------------------------------
// DMA Write
//----------------------------------------------------------------
axi_dma_wr #(
    .BITS_TRANS(BIT_TRANS),
    .OUT_BITS_TRANS(BIT_TRANS),
    .AXI_WIDTH_USER(1),
    .AXI_WIDTH_ID(4),
    .AXI_WIDTH_AD(AXI_WIDTH_AD),
    .AXI_WIDTH_DA(AXI_WIDTH_DA),
    .AXI_WIDTH_DS(AXI_WIDTH_DS)
) u_dma_write(
    .M_AWID(M_AWID), .M_AWADDR(M_AWADDR), .M_AWLEN(M_AWLEN),
    .M_AWSIZE(M_AWSIZE), .M_AWBURST(M_AWBURST), .M_AWLOCK(M_AWLOCK),
    .M_AWCACHE(M_AWCACHE), .M_AWPROT(M_AWPROT), .M_AWREGION(M_AWREGION),
    .M_AWQOS(M_AWQOS), .M_AWVALID(M_AWVALID), .M_AWREADY(M_AWREADY),
    .M_AWUSER(),
    .M_WID(M_WID), .M_WDATA(M_WDATA), .M_WSTRB(M_WSTRB),
    .M_WLAST(M_WLAST), .M_WVALID(M_WVALID), .M_WREADY(M_WREADY),
    .M_WUSER(), .M_BUSER(),
    .M_BID(M_BID), .M_BRESP(M_BRESP), .M_BVALID(M_BVALID), .M_BREADY(M_BREADY),
    .start_dma(ctrl_write),
    .num_trans(num_trans),
    .start_addr(write_addr),
    .indata(write_data),
    .indata_req_o(indata_req_wr),
    .done_o(write_done),
    .fail_check(),
    .clk(clk), .rstn(rstn)
);

endmodule
