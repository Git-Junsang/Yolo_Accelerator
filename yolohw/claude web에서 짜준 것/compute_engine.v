//============================================================================
// Module: compute_engine
// 
// 역할: DNN Compute Engine sub-module
//   - conv_layer_ctrl (FSM)
//   - conv_unit (mul + adder_tree + mac + accumulator + post_process)
//   - max_pool (2x2 stride-2, 별도 패스)
//   - Weight SPRAM (8-bit wide, CONV00+02+04 통합)
//   - Bias SPRAM (32-bit wide, 112 entries)
//   - IFM/OFM dpram x2 (ping-pong A/B)
//
// 외부 인터페이스:
//   - start/done 컨트롤
//   - 외부 메모리 로드 포트 (weight/bias/IFM_A 초기 적재용)
//   - 외부 결과 read 포트 (최종 결과 가져가기용)
//   - current_layer/buf_sel 상태 노출
//
// 메모리 사이즈 (현 시점 결정):
//   - WBUF_DEPTH = 24576  (8-bit, 24KB) ← CONV00~04 통합
//   - BBUF_DEPTH = 112    (32-bit)
//   - FMBUF_DEPTH = 262144 (8-bit, 256KB) ← Layer 2 기준
//     ※ Layer 0 OFM 풀사이즈(1MB)는 미수용. 합성 단계에서 타일링 or DMA 청크 처리 필요.
//============================================================================
module compute_engine #(
    parameter WBUF_DEPTH  = 24576,    // 8-bit weight, 24KB
    parameter WBUF_AW     = 15,       // log2(24576) ≈ 15
    parameter BBUF_DEPTH  = 112,      // 32-bit bias, 112 entries (16+32+64)
    parameter BBUF_AW     = 7,        // log2(112) ≈ 7
    parameter FMBUF_DEPTH = 262144,   // 8-bit feature map, 256KB
    parameter FMBUF_AW    = 18        // log2(262144) = 18
)
(
    input               clk,
    input               rstn,

    //------------------------------------------------------------------
    // Control
    //------------------------------------------------------------------
    input               start,            // 한 번 펄스로 전체 3-layer 시작
    output              done,             // 전체 완료 펄스
    output      [1:0]   current_layer,    // 진행 중 레이어 (0/1/2)
    output              buf_sel,          // 현재 ping-pong 선택 (0=A read/B write, 1=B/A)

    //------------------------------------------------------------------
    // 외부 메모리 로드 포트 (DMA가 사용)
    //   - load_sel: 2'd0=W, 2'd1=B, 2'd2=FM_A, 2'd3=FM_B
    //------------------------------------------------------------------
    input               load_en,          // 로드 모드 활성화 (compute idle 시에만 의미 있음)
    input       [1:0]   load_sel,
    input       [17:0]  load_addr,        // 충분히 큰 폭으로 통일
    input               load_we,
    input       [31:0]  load_wdata,       // 32-bit (W는 하위 8-bit만 사용, B는 32-bit, FM은 하위 8-bit)

    //------------------------------------------------------------------
    // 외부 결과 read 포트 (DMA가 결과 회수)
    //   - read_sel: 2'd0=FM_A, 2'd1=FM_B
    //------------------------------------------------------------------
    input               read_en,
    input       [0:0]   read_sel,
    input       [17:0]  read_addr,
    output      [7:0]   read_rdata
);

//==========================================================================
// conv_layer_ctrl ↔ conv_unit 연결 와이어
//==========================================================================
wire        cu_vld_i;
wire [127:0] cu_win;
wire [127:0] cu_din;
wire [4:0]  cu_num_cycles;
wire signed [31:0] cu_bias;
wire [4:0]  cu_shift_amount;
wire [7:0]  cu_pixel_out;
wire        cu_output_valid;

//==========================================================================
// FSM ↔ 메모리 와이어
//==========================================================================
// Weight
wire [12:0] wgt_addr_fsm;       // FSM에서 13-bit (byte 단위)
wire [7:0]  wgt_rdata;          // 1-byte read

// Bias
wire [6:0]  bias_addr;
wire [31:0] bias_rdata;

// IFM read (ping-pong)
wire [20:0] ifm_rd_addr_fsm;    // FSM 측 21-bit
wire        ifm_rd_en;
wire [7:0]  ifm_rdata;          // MUX 통과 후

// OFM write (conv 결과 저장)
wire [20:0] ofm_wr_addr_fsm;
wire        ofm_wr_en;
wire [7:0]  ofm_wr_data;

// OFM read (maxpool 패스에서 읽기)
wire [20:0] ofm_rd_addr_fsm;
wire        ofm_rd_en;
wire [7:0]  ofm_rd_data;

// MaxPool 결과 write (압축 좌표계)
wire [20:0] mp_wr_addr_fsm;
wire        mp_wr_en;
wire [7:0]  mp_wr_data;

// max_pool 모듈 연결
wire        mp_pool_en;
wire        mp_pixel_valid;
wire [7:0]  mp_pixel_in;
wire [7:0]  mp_pool_out;
wire        mp_pool_valid;

//==========================================================================
// FSM 비트폭과 BRAM 비트폭 어댑터
//   - FSM은 byte/픽셀 단위 절대주소(21-bit)
//   - BRAM 주소는 FMBUF_AW(18-bit)이므로 하위만 사용 (실제 사용 가능 범위 내)
//==========================================================================
wire [FMBUF_AW-1:0] ifm_rd_addr_buf = ifm_rd_addr_fsm[FMBUF_AW-1:0];
wire [FMBUF_AW-1:0] ofm_wr_addr_buf = ofm_wr_addr_fsm[FMBUF_AW-1:0];
wire [FMBUF_AW-1:0] ofm_rd_addr_buf = ofm_rd_addr_fsm[FMBUF_AW-1:0];
wire [FMBUF_AW-1:0] mp_wr_addr_buf  = mp_wr_addr_fsm[FMBUF_AW-1:0];
wire [WBUF_AW-1:0]  wgt_addr_buf    = wgt_addr_fsm[WBUF_AW-1:0];

//==========================================================================
// conv_layer_ctrl 인스턴스
//==========================================================================
conv_layer_ctrl u_ctrl (
    .clk             (clk),
    .rstn            (rstn),
    .start           (start),
    .done            (done),
    .current_layer   (current_layer),
    .buf_sel         (buf_sel),

    // → conv_unit
    .cu_vld_i        (cu_vld_i),
    .cu_win          (cu_win),
    .cu_din          (cu_din),
    .cu_num_cycles   (cu_num_cycles),
    .cu_bias         (cu_bias),
    .cu_shift_amount (cu_shift_amount),
    .cu_pixel_out    (cu_pixel_out),
    .cu_output_valid (cu_output_valid),

    // Weight SPRAM
    .wgt_addr        (wgt_addr_fsm),
    .wgt_cs          (),               // 미사용 (compute_engine에서 항상 cs=1)
    .wgt_we          (),               // 미사용 (compute_engine에서 별도 제어)
    .wgt_rdata       (wgt_rdata),

    // Bias SPRAM
    .bias_addr       (bias_addr),
    .bias_cs         (),               // 미사용
    .bias_we         (),               // 미사용
    .bias_rdata      (bias_rdata),

    // IFM read
    .ifm_rd_addr     (ifm_rd_addr_fsm),
    .ifm_rd_en       (ifm_rd_en),
    .ifm_rd_data     (ifm_rdata),

    // OFM write (conv 결과)
    .ofm_wr_addr     (ofm_wr_addr_fsm),
    .ofm_wr_en       (ofm_wr_en),
    .ofm_wr_data     (ofm_wr_data),

    // OFM read (maxpool 패스)
    .ofm_rd_addr     (ofm_rd_addr_fsm),
    .ofm_rd_en       (ofm_rd_en),
    .ofm_rd_data     (ofm_rd_data),

    // MaxPool 결과 write
    .mp_wr_addr      (mp_wr_addr_fsm),
    .mp_wr_en        (mp_wr_en),
    .mp_wr_data      (mp_wr_data),

    // max_pool 모듈 연결
    .mp_pool_en      (mp_pool_en),
    .mp_pixel_valid  (mp_pixel_valid),
    .mp_pixel_in     (mp_pixel_in),
    .mp_pool_out     (mp_pool_out),
    .mp_pool_valid   (mp_pool_valid)
);

//==========================================================================
// conv_unit 인스턴스 (MAC + Adder Tree + Accumulator + Post-process)
//==========================================================================
conv_unit u_conv (
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

//==========================================================================
// max_pool 인스턴스 (2x2 stride-2)
//==========================================================================
max_pool u_mp (
    .clk         (clk),
    .rstn        (rstn),
    .pool_en     (mp_pool_en),
    .pixel_valid (mp_pixel_valid),
    .pixel_in    (mp_pixel_in),
    .pool_out    (mp_pool_out),
    .pool_valid  (mp_pool_valid)
);

//==========================================================================
// Weight SPRAM (8-bit wide)
//   - 로드: load_en && load_sel==0 일 때 외부에서 write
//   - 컴퓨트 중: FSM이 read-only로 사용
//==========================================================================
wire                wbuf_we    = load_en && (load_sel == 2'd0) && load_we;
wire [WBUF_AW-1:0]  wbuf_addr  = load_en ? load_addr[WBUF_AW-1:0] : wgt_addr_buf;
wire [7:0]          wbuf_wdata = load_wdata[7:0];

spram_wrapper #(
    .DEPTH (WBUF_DEPTH),
    .AW    (WBUF_AW),
    .DW    (8)
) u_wbuf (
    .clk   (clk),
    .addr  (wbuf_addr),
    .we    (wbuf_we),
    .cs    (1'b1),
    .wdata (wbuf_wdata),
    .rdata (wgt_rdata)
);

//==========================================================================
// Bias SPRAM (32-bit wide)
//==========================================================================
wire                bbuf_we    = load_en && (load_sel == 2'd1) && load_we;
wire [BBUF_AW-1:0]  bbuf_addr  = load_en ? load_addr[BBUF_AW-1:0] : bias_addr;
wire [31:0]         bbuf_rdata;
assign bias_rdata = bbuf_rdata;

spram_wrapper #(
    .DEPTH (BBUF_DEPTH),
    .AW    (BBUF_AW),
    .DW    (32)
) u_bbuf (
    .clk   (clk),
    .addr  (bbuf_addr),
    .we    (bbuf_we),
    .cs    (1'b1),
    .wdata (load_wdata),
    .rdata (bbuf_rdata)
);

//==========================================================================
// Feature-Map BRAM A (ping-pong buffer A) - dpram_wrapper
//   - port a: write 전용 (FSM ofm_wr 또는 mp_wr, 외부 load)
//   - port b: read 전용 (FSM ifm_rd 또는 ofm_rd, 외부 read)
//   - buf_sel == 0 일 때 A=read 측, B=write 측
//   - buf_sel == 1 일 때 A=write 측, B=read 측
//==========================================================================

// A 버퍼 write 측 MUX (buf_sel==1일 때 conv/mp 결과가 A로)
wire                a_we;
wire [FMBUF_AW-1:0] a_waddr;
wire [7:0]          a_wdata;
wire                a_re;
wire [FMBUF_AW-1:0] a_raddr;
wire [7:0]          a_rdata;

// 외부 로드/리드와 FSM 쓰기/읽기 MUX
// 우선순위: 외부 로드/리드 > FSM
//   - A가 read 측 (buf_sel=0): port b는 FSM ifm_rd 또는 ofm_rd로
//     ※ ifm_rd_en은 conv 패스, ofm_rd_en은 maxpool 패스에서 켜짐 → 동시 X
//   - A가 write 측 (buf_sel=1): port a는 FSM ofm_wr 또는 mp_wr

assign a_we    = load_en ? ((load_sel == 2'd2) && load_we) :
                 (~buf_sel) ? 1'b0 :              // buf_sel=0: A=read 측, A는 write 안 함
                              (ofm_wr_en | mp_wr_en);    // buf_sel=1: A=write 측
assign a_waddr = load_en ? load_addr[FMBUF_AW-1:0] :
                 mp_wr_en ? mp_wr_addr_buf : ofm_wr_addr_buf;
assign a_wdata = load_en ? load_wdata[7:0] :
                 mp_wr_en ? mp_wr_data : ofm_wr_data;

assign a_re    = (read_en && (read_sel == 1'd0)) ? 1'b1 :
                 (~buf_sel) ? (ifm_rd_en | ofm_rd_en) :   // buf_sel=0: A=read 측
                              1'b0;
assign a_raddr = read_en ? read_addr[FMBUF_AW-1:0] :
                 ofm_rd_en ? ofm_rd_addr_buf : ifm_rd_addr_buf;

dpram_wrapper #(
    .DEPTH (FMBUF_DEPTH),
    .AW    (FMBUF_AW),
    .DW    (8)
) u_fmbuf_A (
    .clk   (clk),
    // port a: write
    .ena   (a_we),
    .addra (a_waddr),
    .wea   (a_we),
    .dia   (a_wdata),
    // port b: read
    .enb   (a_re),
    .addrb (a_raddr),
    .dob   (a_rdata)
);

//==========================================================================
// Feature-Map BRAM B (ping-pong buffer B)
//==========================================================================
wire                b_we;
wire [FMBUF_AW-1:0] b_waddr;
wire [7:0]          b_wdata;
wire                b_re;
wire [FMBUF_AW-1:0] b_raddr;
wire [7:0]          b_rdata;

assign b_we    = load_en ? ((load_sel == 2'd3) && load_we) :
                 (~buf_sel) ? (ofm_wr_en | mp_wr_en) :    // buf_sel=0: B=write 측
                              1'b0;
assign b_waddr = load_en ? load_addr[FMBUF_AW-1:0] :
                 mp_wr_en ? mp_wr_addr_buf : ofm_wr_addr_buf;
assign b_wdata = load_en ? load_wdata[7:0] :
                 mp_wr_en ? mp_wr_data : ofm_wr_data;

assign b_re    = (read_en && (read_sel == 1'd1)) ? 1'b1 :
                 (~buf_sel) ? 1'b0 :
                              (ifm_rd_en | ofm_rd_en);    // buf_sel=1: B=read 측
assign b_raddr = read_en ? read_addr[FMBUF_AW-1:0] :
                 ofm_rd_en ? ofm_rd_addr_buf : ifm_rd_addr_buf;

dpram_wrapper #(
    .DEPTH (FMBUF_DEPTH),
    .AW    (FMBUF_AW),
    .DW    (8)
) u_fmbuf_B (
    .clk   (clk),
    .ena   (b_we),
    .addra (b_waddr),
    .wea   (b_we),
    .dia   (b_wdata),
    .enb   (b_re),
    .addrb (b_raddr),
    .dob   (b_rdata)
);

//==========================================================================
// FSM read 데이터 MUX (buf_sel 기반)
//   - buf_sel=0: A=read 측 → ifm_rdata/ofm_rd_data = A.rdata
//   - buf_sel=1: B=read 측 → ifm_rdata/ofm_rd_data = B.rdata
//==========================================================================
assign ifm_rdata    = (~buf_sel) ? a_rdata : b_rdata;
assign ofm_rd_data  = (~buf_sel) ? a_rdata : b_rdata;

// 외부 read 데이터 (read_sel 기반)
assign read_rdata   = (read_sel == 1'd0) ? a_rdata : b_rdata;

endmodule
