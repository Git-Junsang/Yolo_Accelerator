`timescale 1ns / 1ps
//----------------------------------------------------------------+
// conv_top.v — Convolution Top (gbuff_param + mac_kern + FSM)
//
// 강의 11~12차시 통합 모듈. 한 layer 의 conv 연산을 진행한다.
//   - gbuff_param 인스턴스: weight (288-bit) / bias-shift (32-bit) 공급
//   - mac_kern 인스턴스   : 한 cycle 에 4 출력 픽셀 (2×2 block) 생성
//   - 자체 FSM/카운터로 (fil, row, col, acc_cyc) 4중 loop 순회
//
// Loop order (output-stationary, weight reuse 극대화):
//   for fil = 0..Co-1:                ← 각 filter 마다 bias 1 read
//     for row = 0..H_half-1:
//       for col = 0..W_half-1:        ← 한 spatial 좌표 = 2×2 OFM block
//         for acc = 0..acc_len-1:     ← Ci/4 (3×3) 또는 Ci/36 (1×1) 누적
//           mac_kern.vld_i = 1        ← streaming, 매 cycle 새 weight+IFM
//
// 외부 인터페이스:
//   - i_start / o_done       : layer 시작/완료 (1-pulse)
//   - DMA write (gbuff_param 으로 직결)
//   - IFM 4 set (외부 line buffer 가 좌표에 맞춰 공급)
//   - OFM 4 pixel packed + flat addr (외부 dpram 이 word 단위로 write)
//
// Latency 정렬:
//   gbuff_param BRAM read latency = 1 cycle.
//   ST_LOAD 동안 weight/bias 의 첫 read addr 발사 → ST_RUN 첫 cycle 에 data 도착.
//   mac_kern.i_vld 는 1-cycle delayed (mac_vld_d) 로 wgt_data 와 정렬.
//----------------------------------------------------------------+
module conv_top(
    input              clk,
    input              rstn,

    // ===== layer 컨트롤 =====
    input              i_start,        // 1-cycle pulse
    output             o_done,         // 1-cycle pulse
    output             o_fil_done,     // 1-cycle pulse: 필터 1개 완료 (ST_DRAIN→ST_NEXT 전이)
    input              i_conv_pause,   // HIGH: ST_NEXT 에서 대기 (streaming DMA 용)
    input              i_mode,         // 0=CONV3x3, 1=CONV1x1

    // ===== layer 파라미터 =====
    input  [11:0]      i_ofm_w_half,   // OFM width  / 2 (2×2 block 수)
    input  [11:0]      i_ofm_h_half,   // OFM height / 2
    input  [11:0]      i_co_total,     // 출력 filter 수
    input  [7:0]       i_acc_len,      // 한 spatial 의 누적 cycle 수
    input  [9:0]       i_wgt_base,     // weight buffer 시작 entry (288-bit entry)
    input  [11:0]      i_bias_base,    // bias buffer 시작 entry (32-bit entry)
    input  [4:0]       i_shift,

    // ===== gbuff_param DMA write =====
    input              dma_wgt_we,
    input  [11:0]      dma_wgt_addr,
    input  [71:0]      dma_wgt_data,
    input              dma_bias_we,
    input  [11:0]      dma_bias_addr,
    input  [31:0]      dma_bias_data,

    // ===== IFM 인터페이스 =====
    //   외부 line buffer 는 (row_idx, col_idx, acc_cyc) 를 보고
    //   해당하는 2×2 block 의 36-byte 입력을 4 set 공급한다.
    output             o_ifm_re,
    output [11:0]      o_ifm_row,
    output [11:0]      o_ifm_col,
    output [7:0]       o_ifm_acc,
    input  [287:0]     i_ifm_00,
    input  [287:0]     i_ifm_01,
    input  [287:0]     i_ifm_10,
    input  [287:0]     i_ifm_11,

    // ===== OFM 출력 =====
    output [31:0]      o_pixel,        // {pix11, pix10, pix01, pix00}
    output             o_pixel_vld,
    output [25:0]      o_ofm_addr      // {fil × (W/2)×(H/2) + row×(W/2) + col} flat
);

    //----------------------------------------------------------------
    // FSM 상태
    //----------------------------------------------------------------
    localparam ST_IDLE  = 3'd0,
               ST_LOAD  = 3'd1,    // weight/bias read 발사 (1 cycle)
               ST_RUN   = 3'd2,    // mac_kern streaming
               ST_DRAIN = 3'd3,    // pipeline 비우기
               ST_NEXT  = 3'd4,    // 다음 filter 진입 전 carry
               ST_DONE  = 3'd5;
    reg [2:0] cstate, nstate;

    //----------------------------------------------------------------
    // 카운터 / 주소 레지스터
    //----------------------------------------------------------------
    reg [11:0] fil_idx;
    reg [11:0] row_idx;
    reg [11:0] col_idx;
    reg [7:0]  acc_cyc;
    reg [9:0]  wgt_addr_r;     // 다음 cycle 의 BRAM read addr
    reg [9:0]  wgt_base_r;     // 현재 filter 의 weight base
    reg [11:0] bias_addr_r;
    reg [23:0] out_cnt;        // 현재 filter 내 발생한 mac_pixel_vld 수
    reg [25:0] frame_offset_r; // 누적 OFM offset (fil_idx 의 함수)

    wire [23:0] q_total      = i_ofm_w_half * i_ofm_h_half;   // 작은 곱 (≤ 16×16 = 256)
    wire        spatial_last = (col_idx == i_ofm_w_half - 1) &&
                               (row_idx == i_ofm_h_half - 1) &&
                               (acc_cyc == i_acc_len - 1);
    wire        fil_last     = (fil_idx == i_co_total - 1);

    //----------------------------------------------------------------
    // gbuff_param 인스턴스
    //----------------------------------------------------------------
    wire         wgt_rd_en  = (cstate == ST_LOAD) || (cstate == ST_RUN);
    wire         bias_rd_en = (cstate == ST_LOAD);
    wire [287:0] wgt_data;
    wire [31:0]  bias_data;

    gbuff_param u_gbuff (
        .clk         (clk),
        .rstn        (rstn),
        // DMA write
        .wr_wgt_en   (dma_wgt_we),
        .wr_wgt_addr (dma_wgt_addr),
        .wr_wgt_data (dma_wgt_data),
        .wr_bias_en  (dma_bias_we),
        .wr_bias_addr(dma_bias_addr),
        .wr_bias_data(dma_bias_data),
        // MAC read
        .rd_wgt_en   (wgt_rd_en),
        .rd_wgt_addr (wgt_addr_r),
        .rd_wgt_data (wgt_data),
        .rd_bias_en  (bias_rd_en),
        .rd_bias_addr(bias_addr_r),
        .rd_bias_data(bias_data)
    );

    //----------------------------------------------------------------
    // mac_kern 인스턴스 — 1-cycle delayed vld (BRAM read latency 보정)
    //   ST_RUN 만 포함: q_total 정확히 일치 (ST_LOAD 포함 시 extra pulse 발생).
    //
    //   IFM 정렬 원리 (look-ahead 와 pipeline_reg 의 역할):
    //     ST_LOAD (i_cb=col_idx): col=0 BRAM 요청 → posedge+1 에 phys_ent_a=data(col=0)
    //                              pipeline_reg 에 offset(col=0) 저장
    //     ST_RUN K=0 (i_cb=lah_col=1): col=1 요청 — K=1 을 위한 사전 발사.
    //       ifm00_w = window(col=0) (phys_ent_a=data(col=0) + offset_r=offset(col=0))
    //       → output_reg 에 window(col=0) 저장
    //     mac_vld_d fires at ST_RUN K=0+1 cycle → mac_kern at K=0 에 window(col=0) 도착 ✓
    //----------------------------------------------------------------
    reg mac_vld_d;
    always @(posedge clk or negedge rstn) begin
        if (!rstn) mac_vld_d <= 1'b0;
        else       mac_vld_d <= (cstate == ST_RUN);
    end

    wire [31:0] mac_pixel;
    wire        mac_pixel_vld;

    mac_kern u_mac_kern (
        .clk     (clk),
        .rstn    (rstn),
        .i_vld   (mac_vld_d),
        .i_mode  (i_mode),
        .i_len   (i_acc_len),
        .i_wgt   (wgt_data),
        .i_ifm_00(i_ifm_00),
        .i_ifm_01(i_ifm_01),
        .i_ifm_10(i_ifm_10),
        .i_ifm_11(i_ifm_11),
        .i_bias  (bias_data),
        .i_shift (i_shift),
        .o_pixel (mac_pixel),
        .o_vld   (mac_pixel_vld)
    );

    //----------------------------------------------------------------
    // FSM 전이
    //----------------------------------------------------------------
    always @(posedge clk or negedge rstn) begin
        if (!rstn) cstate <= ST_IDLE;
        else       cstate <= nstate;
    end

    always @(*) begin
        nstate = cstate;
        case (cstate)
            ST_IDLE : if (i_start)                       nstate = ST_LOAD;
            ST_LOAD :                                    nstate = ST_RUN;
            ST_RUN  : if (spatial_last)                  nstate = ST_DRAIN;
            ST_DRAIN: if (out_cnt == q_total[23:0])      nstate = ST_NEXT;
            ST_NEXT : if (!i_conv_pause)                 nstate = fil_last ? ST_DONE : ST_LOAD;
            ST_DONE :                                    nstate = ST_IDLE;
            default :                                    nstate = ST_IDLE;
        endcase
    end

    //----------------------------------------------------------------
    // 카운터/주소 update
    //   wgt_addr_r 는 BRAM 으로 발사할 "다음" addr.
    //   - ST_LOAD     : wgt_base 발사 (ST_RUN 첫 cycle 의 wgt_data 가 entry 0)
    //   - ST_RUN cyc k: wgt_data = entry k, wgt_addr_r = entry k+1 발사
    //----------------------------------------------------------------
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            fil_idx        <= 12'd0;
            row_idx        <= 12'd0;
            col_idx        <= 12'd0;
            acc_cyc        <= 8'd0;
            wgt_addr_r     <= 10'd0;
            wgt_base_r     <= 10'd0;
            bias_addr_r    <= 12'd0;
            out_cnt        <= 24'd0;
            frame_offset_r <= 26'd0;
        end else begin
            case (cstate)
                ST_IDLE: if (i_start) begin
                    fil_idx        <= 12'd0;
                    row_idx        <= 12'd0;
                    col_idx        <= 12'd0;
                    acc_cyc        <= 8'd0;
                    wgt_addr_r     <= i_wgt_base;
                    wgt_base_r     <= i_wgt_base;
                    bias_addr_r    <= i_bias_base;
                    out_cnt        <= 24'd0;
                    frame_offset_r <= 26'd0;
                end

                ST_LOAD: begin
                    // ST_LOAD 1 cycle: 첫 read 발사 (BRAM 입력 = wgt_addr_r)
                    //   - ST_LOAD cycle 의 wgt_addr_r 발사값 = wgt_base (이전 cycle 갱신)
                    //   - 다음 cycle (ST_RUN 1st) wgt_data = entry 0 ✓
                    //   - 이 cycle 갱신: 다음 cycle 에 발사할 wgt_addr (= entry 1)
                    if (i_acc_len == 8'd1) wgt_addr_r <= wgt_base_r;
                    else                   wgt_addr_r <= wgt_base_r + 10'd1;
                    row_idx <= 12'd0;
                    col_idx <= 12'd0;
                    acc_cyc <= 8'd0;
                    out_cnt <= 24'd0;
                end

                ST_RUN: begin
                    //----------------------------------------------------
                    // BRAM 1-cycle latency 정렬을 위한 streaming 패턴:
                    //   - 일반 cycle (acc_cyc < i_acc_len-2): wgt_addr_r++ 진행
                    //   - acc_cyc == i_acc_len-2 (pre-reset): wgt_addr_r <= wgt_base
                    //       → 다음 cycle (i_acc_len-1) 의 BRAM 발사값이 wgt_base
                    //       → 그 다음 cycle (next spatial 1st) wgt_data = entry 0
                    //   - acc_cyc == i_acc_len-1 (spatial 끝): wgt_addr_r <= wgt_base+1
                    //       → spatial transition, 자기 자신 cycle 의 wgt_data 는
                    //         이전 발사 (wgt_base+i_acc_len-1) → entry i_acc_len-1 ✓
                    //   - i_acc_len == 1: 매 cycle 같은 entry 0 (special-case)
                    //----------------------------------------------------
                    if (i_acc_len == 8'd1) begin
                        wgt_addr_r <= wgt_base_r;
                        acc_cyc    <= 8'd0;
                        if (col_idx == i_ofm_w_half - 1) begin
                            col_idx <= 12'd0;
                            if (row_idx != i_ofm_h_half - 1) row_idx <= row_idx + 12'd1;
                            else                              row_idx <= 12'd0;
                        end else col_idx <= col_idx + 12'd1;
                    end
                    else if (acc_cyc == i_acc_len - 8'd1) begin
                        // spatial transition
                        acc_cyc    <= 8'd0;
                        wgt_addr_r <= wgt_base_r + 10'd1;
                        if (col_idx == i_ofm_w_half - 1) begin
                            col_idx <= 12'd0;
                            if (row_idx != i_ofm_h_half - 1) row_idx <= row_idx + 12'd1;
                            else                              row_idx <= 12'd0;
                        end else col_idx <= col_idx + 12'd1;
                    end
                    else if (acc_cyc == i_acc_len - 8'd2) begin
                        // pre-reset (i_acc_len >= 2)
                        acc_cyc    <= acc_cyc + 8'd1;
                        wgt_addr_r <= wgt_base_r;
                    end
                    else begin
                        acc_cyc    <= acc_cyc + 8'd1;
                        wgt_addr_r <= wgt_addr_r + 10'd1;
                    end
                    if (mac_pixel_vld) out_cnt <= out_cnt + 24'd1;
                end

                ST_DRAIN: begin
                    if (mac_pixel_vld) out_cnt <= out_cnt + 24'd1;
                end

                ST_NEXT: begin
                    fil_idx        <= fil_idx + 12'd1;
                    wgt_base_r     <= wgt_base_r + {2'b00, i_acc_len};
                    // 다음 ST_LOAD cycle 의 wgt_addr_r 발사값 = new wgt_base (entry 0)
                    wgt_addr_r     <= wgt_base_r + {2'b00, i_acc_len};
                    bias_addr_r    <= bias_addr_r + 12'd1;
                    frame_offset_r <= frame_offset_r + {2'd0, q_total};
                end

                ST_DONE: ;
                default: ;
            endcase
        end
    end

    //----------------------------------------------------------------
    // 출력 결선
    //----------------------------------------------------------------
    assign o_pixel     = mac_pixel;
    assign o_pixel_vld = mac_pixel_vld;
    assign o_ofm_addr  = frame_offset_r + {2'd0, out_cnt};
    // ST_DRAIN → ST_NEXT 전이 1-cycle pulse (필터 k 완료 신호)
    assign o_fil_done  = (cstate == ST_DRAIN) && (out_cnt[23:0] == q_total[23:0]);

    // IFM look-ahead: ifm_line_buf 의 BRAM read latency = 1 cycle.
    //   ST_LOAD: 현재 (row=0, col=0, acc=0) 발사 → ST_RUN 첫 cycle 에 데이터 도착.
    //   ST_RUN:  다음 cycle 의 (row, col, acc) 를 미리 발사하여 latency 보상.
    wire        lah_acc_last = (acc_cyc  == i_acc_len   - 8'd1);
    wire        lah_col_last = (col_idx  == i_ofm_w_half - 12'd1);
    wire        lah_row_last = (row_idx  == i_ofm_h_half - 12'd1);
    wire [7:0]  lah_acc = lah_acc_last ? 8'd0 : acc_cyc + 8'd1;
    wire [11:0] lah_col = lah_acc_last ? (lah_col_last ? 12'd0 : col_idx + 12'd1) : col_idx;
    wire [11:0] lah_row = (lah_acc_last && lah_col_last) ?
                          (lah_row_last ? 12'd0 : row_idx + 12'd1) : row_idx;

    assign o_ifm_re    = (cstate == ST_LOAD) || (cstate == ST_RUN);
    assign o_ifm_row   = (cstate == ST_RUN) ? lah_row : row_idx;
    assign o_ifm_col   = (cstate == ST_RUN) ? lah_col : col_idx;
    assign o_ifm_acc   = (cstate == ST_RUN) ? lah_acc : acc_cyc;

    assign o_done      = (cstate == ST_DONE);

endmodule
