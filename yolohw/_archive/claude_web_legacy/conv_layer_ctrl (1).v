`timescale 1ns / 1ps

//================================================================
// 모듈명: conv_layer_ctrl (Multi-Layer Convolution Controller)
//
// 역할: Conv Layer 1→2→3을 자동으로 순차 실행하는 FSM.
//       weight/bias를 BRAM에서 읽고, input feature map을 BRAM에서 읽어서
//       conv_unit에 공급하고, 출력을 다시 BRAM에 저장한다.
//
// 네트워크 구조 (CONV00 → MAXPOOL01 → CONV02 → MAXPOOL03 → CONV04):
//   Layer 0 (CONV00): 256×256×3  → 3×3 conv → 256×256×16  → maxpool → 128×128×16
//   Layer 1 (CONV02): 128×128×16 → 3×3 conv → 128×128×32  → maxpool → 64×64×32
//   Layer 2 (CONV04): 64×64×32   → 3×3 conv → 64×64×64    → maxpool → 32×32×64
//
// hex 파일 데이터 확인:
//   CONV00: weight 432줄(=16×27), bias 16줄, scale 16줄(0x0080=128)
//   CONV02: weight 4608줄(=32×144), bias 32줄, scale 32줄(0x0040=64)
//   CONV04: weight 18432줄(=64×288), bias 64줄, scale 64줄(0x0040=64)
//
// 데이터 흐름 (1개 출력 픽셀 기준):
//   1) FSM이 weight 주소 + input 주소를 생성
//   2) BRAM에서 weight(128bit), input(128bit) 읽기 (1클록 레이턴시)
//   3) conv_unit에 vld_i + win + din 공급 (num_cycles번 반복)
//   4) conv_unit이 output_valid + pixel_out 출력
//   5) pixel_out을 출력 FM BRAM에 저장
//   6) 모든 출력 픽셀에 대해 1~5 반복
//   7) maxpool 적용 (해당되는 경우)
//   8) 다음 레이어로 전환 (buf_sel 토글)
//================================================================

module conv_layer_ctrl(
    input               clk,
    input               rstn,

    //----------------------------------------------------------
    // 외부 제어
    //----------------------------------------------------------
    input               start,          // 1펄스: 전체 3레이어 연산 시작
    output reg          done,           // 1펄스: 3레이어 전부 완료

    //----------------------------------------------------------
    // conv_unit 제어 신호
    //----------------------------------------------------------
    output reg          cu_vld_i,       // conv_unit의 vld_i
    output reg [127:0]  cu_win,         // conv_unit의 win
    output reg [127:0]  cu_din,         // conv_unit의 din
    output reg [4:0]    cu_num_cycles,  // conv_unit의 num_cycles
    output reg signed [31:0] cu_bias,   // conv_unit의 bias
    output reg [4:0]    cu_shift_amount,// conv_unit의 shift_amount
    input  [7:0]        cu_pixel_out,   // conv_unit의 pixel_out
    input               cu_output_valid,// conv_unit의 output_valid

    //----------------------------------------------------------
    // Weight BRAM (spram_wrapper) 제어
    //----------------------------------------------------------
    output reg [12:0]   wgt_addr,       // weight BRAM 주소 (max 5040+1151=6191, byte 단위)
    output              wgt_cs,         // chip select (항상 1)
    output              wgt_we,         // write enable (항상 0, 읽기만)
    input  [127:0]      wgt_rdata,      // weight BRAM 읽기 데이터

    //----------------------------------------------------------
    // Bias BRAM (spram_wrapper) 제어
    //----------------------------------------------------------
    output reg [6:0]    bias_addr,      // bias BRAM 주소
    output              bias_cs,
    output              bias_we,
    input  [31:0]       bias_rdata,     // bias BRAM 읽기 데이터 (signed 16bit → 32bit 확장)

    //----------------------------------------------------------
    // Input FM BRAM (dpram_wrapper) 읽기 포트
    //----------------------------------------------------------
    output reg [16:0]   ifm_rd_addr,    // 입력 FM 읽기 주소
    output reg          ifm_rd_en,      // 읽기 활성화
    input  [127:0]      ifm_rd_data,    // 128bit 입력 데이터

    //----------------------------------------------------------
    // Output FM BRAM (dpram_wrapper) 쓰기 포트
    //----------------------------------------------------------
    output reg [20:0]   ofm_wr_addr,    // 출력 FM 쓰기 주소 (Layer0 max 1,048,575)
    output reg          ofm_wr_en,      // 쓰기 활성화
    output reg [7:0]    ofm_wr_data,    // 8bit 출력 픽셀

    //----------------------------------------------------------
    // [신규] OFM 읽기 포트 (maxpool 패스에서 사용)
    //----------------------------------------------------------
    output reg [20:0]   ofm_rd_addr,    // OFM 읽기 주소
    output reg          ofm_rd_en,      // OFM 읽기 활성화
    input      [7:0]    ofm_rd_data,    // OFM 읽기 데이터

    //----------------------------------------------------------
    // [신규] MaxPool 결과 쓰기 포트 (별도 버퍼/영역으로 라우팅)
    //----------------------------------------------------------
    output reg [20:0]   mp_wr_addr,     // 압축 좌표계 주소 (max 262,143)
    output reg          mp_wr_en,       // 쓰기 활성화
    output reg [7:0]    mp_wr_data,     // 8bit max 결과

    //----------------------------------------------------------
    // [신규] max_pool 모듈 연결 (top에서 인스턴스화 가정)
    //----------------------------------------------------------
    output reg          mp_pool_en,     // 1=Pooling 모드
    output reg          mp_pixel_valid, // 픽셀 유효
    output reg [7:0]    mp_pixel_in,    // 픽셀 입력
    input      [7:0]    mp_pool_out,    // max_pool 결과
    input               mp_pool_valid,  // 결과 유효 펄스

    //----------------------------------------------------------
    // Buffer 스왑 신호
    //----------------------------------------------------------
    output reg          buf_sel,        // 0: A읽기/B쓰기, 1: B읽기/A쓰기

    //----------------------------------------------------------
    // 디버그/상태 출력
    //----------------------------------------------------------
    output reg [1:0]    current_layer   // 현재 레이어 번호 (0/1/2)
);

//----------------------------------------------------------------------
// 상수: 항상 읽기 모드
//----------------------------------------------------------------------
assign wgt_cs = 1'b1;       // weight BRAM 항상 활성화
assign wgt_we = 1'b0;       // 쓰기 안 함 (읽기만)
assign bias_cs = 1'b1;
assign bias_we = 1'b0;

//----------------------------------------------------------------------
// 레이어별 파라미터 테이블 (ROM처럼 사용)
//----------------------------------------------------------------------
// C코드에서 추출한 값들:
//
//                    Layer0(CONV00)   Layer1(CONV02)   Layer2(CONV04)
// 입력 크기:         256×256×3        128×128×16       64×64×32
// 필터 크기:         3×3              3×3              3×3
// 입력 채널(Ci):     3                16               32
// 출력 채널(Co):     16               32               64
// 출력 크기:         256×256          128×128          64×64
// K(=Fx*Fy*Ci):     27               144              288
// num_cycles:       ceil(27/16)=2    ceil(144/16)=9   ceil(288/16)=18
// MaxPool:          2×2 stride2      2×2 stride2      2×2 stride2
//
// weight 시작 주소:  0                432              5040
// bias 시작 주소:    0                16               48
//----------------------------------------------------------------------

// 레이어별 파라미터를 reg에 래치 (FSM에서 레이어 전환 시 설정)
reg [8:0]  param_out_h;         // 출력 높이
reg [8:0]  param_out_w;         // 출력 폭
reg [6:0]  param_co;            // 출력 채널 수 (최대 64)
reg [4:0]  param_num_cycles;    // MAC 누적 사이클 수
reg [4:0]  param_shift_amount;  // descaling 시프트량
reg [12:0] param_wgt_base;      // weight 시작 주소 (CONV00:0, CONV02:432, CONV04:5040)
reg [6:0]  param_bias_base;     // bias 시작 주소
reg [8:0]  param_in_h;          // 입력 높이
reg [8:0]  param_in_w;          // 입력 폭
reg [6:0]  param_ci;            // 입력 채널 수

//----------------------------------------------------------------------
// FSM 상태 정의
//----------------------------------------------------------------------
localparam  ST_IDLE         = 4'd0,     // 대기
            ST_LAYER_SETUP  = 4'd1,     // 레이어 파라미터 로드
            ST_PIXEL_INIT   = 4'd2,     // 출력 픽셀 좌표 초기화
            ST_LOAD_BIAS    = 4'd3,     // bias 읽기 요청
            ST_BIAS_WAIT    = 4'd4,     // bias BRAM 레이턴시 대기
            ST_FEED_MAC     = 4'd5,     // weight + input을 MAC에 공급
            ST_WAIT_RESULT  = 4'd6,     // conv_unit 결과 대기
            ST_STORE_PIXEL  = 4'd7,     // 결과 픽셀 저장
            ST_NEXT_FILTER  = 4'd8,     // 다음 필터로 이동
            ST_NEXT_PIXEL   = 4'd9,     // 다음 출력 좌표로 이동
            ST_LAYER_DONE   = 4'd10,    // conv 레이어 완료 → maxpool 패스로
            ST_DONE         = 4'd11,    // 전체 완료
            // [신규] MaxPool 패스 상태
            ST_MP_INIT      = 4'd12,    // maxpool 카운터 초기화
            ST_MP_RUN       = 4'd13,    // 윈도우 1개 처리 (6 phase)
            ST_MP_DONE      = 4'd14;    // 한 레이어 maxpool 완료 → 다음 레이어

reg [3:0]  state, next_state;

//----------------------------------------------------------------------
// 내부 카운터/레지스터
//----------------------------------------------------------------------
reg [8:0]  out_row;         // 현재 출력 픽셀의 row (y 좌표)
reg [8:0]  out_col;         // 현재 출력 픽셀의 col (x 좌표)
reg [6:0]  out_fil;         // 현재 필터 인덱스 (0 ~ Co-1)
reg [4:0]  feed_cnt;        // MAC 공급 카운터 (0 ~ num_cycles-1)
reg [16:0] pixel_cnt;       // 출력 픽셀 전체 카운터

// BRAM 레이턴시 카운터
reg [1:0]  bram_wait;

//----------------------------------------------------------------------
// [신규] MaxPool 패스 카운터
//----------------------------------------------------------------------
reg [8:0]  mp_row;            // 압축 좌표계 row (0 ~ out_h/2 - 1)
reg [8:0]  mp_col;            // 압축 좌표계 col (0 ~ out_w/2 - 1)
reg [6:0]  mp_fil;            // 채널 (0 ~ Co - 1)
reg [2:0]  mp_phase;          // 윈도우 내 phase (0~5)
reg        mp_done_layer;     // 한 레이어 maxpool 완료 플래그

//----------------------------------------------------------------------
// FSM: 상태 레지스터
//----------------------------------------------------------------------
always @(posedge clk or negedge rstn) begin
    if (!rstn)
        state <= ST_IDLE;
    else
        state <= next_state;
end

//----------------------------------------------------------------------
// FSM: 상태 전이 (조합 로직)
//----------------------------------------------------------------------
always @(*) begin
    next_state = state;
    case (state)
        ST_IDLE: begin
            if (start)
                next_state = ST_LAYER_SETUP;
        end

        ST_LAYER_SETUP: begin
            // 1클록으로 파라미터 로드 완료
            next_state = ST_PIXEL_INIT;
        end

        ST_PIXEL_INIT: begin
            next_state = ST_LOAD_BIAS;
        end

        ST_LOAD_BIAS: begin
            // bias BRAM에 주소 제출
            next_state = ST_BIAS_WAIT;
        end

        ST_BIAS_WAIT: begin
            // BRAM 1클록 레이턴시 대기
            if (bram_wait == 2'd1)
                next_state = ST_FEED_MAC;
        end

        ST_FEED_MAC: begin
            // num_cycles번 weight+input 공급
            if (feed_cnt == param_num_cycles - 1)
                next_state = ST_WAIT_RESULT;
        end

        ST_WAIT_RESULT: begin
            // conv_unit이 output_valid를 올릴 때까지 대기
            if (cu_output_valid)
                next_state = ST_STORE_PIXEL;
        end

        ST_STORE_PIXEL: begin
            // 픽셀 저장 후 다음 필터로
            next_state = ST_NEXT_FILTER;
        end

        ST_NEXT_FILTER: begin
            if (out_fil == param_co - 1)
                next_state = ST_NEXT_PIXEL;     // 모든 필터 완료
            else
                next_state = ST_LOAD_BIAS;      // 다음 필터
        end

        ST_NEXT_PIXEL: begin
            if (out_row == param_out_h - 1 && out_col == param_out_w - 1)
                next_state = ST_LAYER_DONE;     // 모든 픽셀 완료
            else
                next_state = ST_LOAD_BIAS;      // 다음 픽셀
        end

        ST_LAYER_DONE: begin
            // [변경] conv 끝나면 항상 maxpool 패스 실행 (3개 레이어 모두 2x2/stride2)
            next_state = ST_MP_INIT;
        end

        //----------------------------------------------------------
        // [신규] MaxPool 패스 상태 전이
        //----------------------------------------------------------
        ST_MP_INIT: begin
            next_state = ST_MP_RUN;
        end

        ST_MP_RUN: begin
            // 한 레이어 모든 윈도우 처리 완료 시 ST_MP_DONE
            if (mp_done_layer)
                next_state = ST_MP_DONE;
        end

        ST_MP_DONE: begin
            // maxpool 끝나면 다음 레이어 또는 전체 완료
            if (current_layer == 2'd2)
                next_state = ST_DONE;
            else
                next_state = ST_LAYER_SETUP;
        end

        ST_DONE: begin
            next_state = ST_IDLE;
        end

        default: next_state = ST_IDLE;
    endcase
end

//----------------------------------------------------------------------
// FSM: 출력/제어 로직 (순차 로직)
//----------------------------------------------------------------------
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        // 모든 출력/레지스터 초기화
        done            <= 1'b0;
        cu_vld_i        <= 1'b0;
        cu_win          <= 128'd0;
        cu_din          <= 128'd0;
        cu_num_cycles   <= 5'd1;
        cu_bias         <= 32'd0;
        cu_shift_amount <= 5'd0;
        wgt_addr        <= 13'd0;
        bias_addr       <= 7'd0;
        ifm_rd_addr     <= 17'd0;
        ifm_rd_en       <= 1'b0;
        ofm_wr_addr     <= 21'd0;
        ofm_wr_en       <= 1'b0;
        ofm_wr_data     <= 8'd0;
        // [신규] maxpool 신호 초기화
        ofm_rd_addr     <= 21'd0;
        ofm_rd_en       <= 1'b0;
        mp_wr_addr      <= 21'd0;
        mp_wr_en        <= 1'b0;
        mp_wr_data      <= 8'd0;
        mp_pool_en      <= 1'b0;
        mp_pixel_valid  <= 1'b0;
        mp_pixel_in     <= 8'd0;
        // [신규] maxpool 카운터 초기화
        mp_row          <= 9'd0;
        mp_col          <= 9'd0;
        mp_fil          <= 6'd0;
        mp_phase        <= 3'd0;
        mp_done_layer   <= 1'b0;
        buf_sel         <= 1'b0;
        current_layer   <= 2'd0;
        out_row         <= 9'd0;
        out_col         <= 9'd0;
        out_fil         <= 6'd0;
        feed_cnt        <= 5'd0;
        pixel_cnt       <= 17'd0;
        bram_wait       <= 2'd0;
        // 파라미터 초기화
        param_out_h     <= 9'd0;
        param_out_w     <= 9'd0;
        param_co        <= 6'd0;
        param_num_cycles<= 5'd0;
        param_shift_amount <= 5'd0;
        param_wgt_base  <= 13'd0;
        param_bias_base <= 7'd0;
        param_in_h      <= 9'd0;
        param_in_w      <= 9'd0;
        param_ci        <= 6'd0;
    end
    else begin
        // 기본값: 펄스 신호는 매 클록 리셋
        done       <= 1'b0;
        cu_vld_i   <= 1'b0;
        ofm_wr_en  <= 1'b0;
        ifm_rd_en  <= 1'b0;
        // [신규] maxpool 펄스 기본값
        ofm_rd_en      <= 1'b0;
        mp_wr_en       <= 1'b0;
        mp_pixel_valid <= 1'b0;

        case (state)
            //==========================================================
            // IDLE: start 펄스 대기
            //==========================================================
            ST_IDLE: begin
                current_layer <= 2'd0;
                buf_sel       <= 1'b0;      // 처음: A에서 읽기
            end

            //==========================================================
            // LAYER_SETUP: 레이어별 파라미터 로드
            //==========================================================
            // C코드에서 추출한 상수값을 레지스터에 래치한다.
            // 실제 FPGA에서는 외부 레지스터나 ROM에서 읽을 수도 있다.
            //==========================================================
            ST_LAYER_SETUP: begin
                out_row   <= 9'd0;
                out_col   <= 9'd0;
                out_fil   <= 6'd0;
                pixel_cnt <= 17'd0;

                case (current_layer)
                    2'd0: begin // CONV00: 256×256×3 → 256×256×16
                        param_in_h      <= 9'd256;
                        param_in_w      <= 9'd256;
                        param_ci        <= 6'd3;
                        param_out_h     <= 9'd256;
                        param_out_w     <= 9'd256;
                        param_co        <= 6'd16;
                        param_num_cycles<= 5'd2;    // ceil(27/16) = 2
                        param_shift_amount <= 5'd7;  // CONV00 scale = 0x80 → log2(128) = 7
                        param_wgt_base  <= 13'd0;
                        param_bias_base <= 7'd0;
                    end
                    2'd1: begin // CONV02: 128×128×16 → 128×128×32
                        param_in_h      <= 9'd128;
                        param_in_w      <= 9'd128;
                        param_ci        <= 6'd16;
                        param_out_h     <= 9'd128;
                        param_out_w     <= 9'd128;
                        param_co        <= 6'd32;
                        param_num_cycles<= 5'd9;    // ceil(144/16) = 9
                        param_shift_amount <= 5'd6;  // CONV02 scale = 0x40 → log2(64) = 6
                        param_wgt_base  <= 13'd432;  // CONV00 weight 끝 다음
                        param_bias_base <= 7'd16;
                    end
                    2'd2: begin // CONV04: 64×64×32 → 64×64×64
                        param_in_h      <= 9'd64;
                        param_in_w      <= 9'd64;
                        param_ci        <= 6'd32;
                        param_out_h     <= 9'd64;
                        param_out_w     <= 9'd64;
                        param_co        <= 7'd64;
                        param_num_cycles<= 5'd18;   // ceil(288/16) = 18
                        param_shift_amount <= 5'd6;  // CONV04 scale = 0x40 → log2(64) = 6
                        param_wgt_base  <= 13'd5040; // CONV02 끝(432+4608) = 5040부터 시작
                        param_bias_base <= 7'd48;
                    end
                endcase

                cu_num_cycles <= param_num_cycles;
            end

            //==========================================================
            // PIXEL_INIT: 출력 픽셀 루프 시작
            //==========================================================
            ST_PIXEL_INIT: begin
                cu_num_cycles   <= param_num_cycles;
                cu_shift_amount <= param_shift_amount;
            end

            //==========================================================
            // LOAD_BIAS: bias BRAM에 주소 요청
            //==========================================================
            ST_LOAD_BIAS: begin
                bias_addr <= param_bias_base + out_fil;
                bram_wait <= 2'd0;
                feed_cnt  <= 5'd0;
            end

            //==========================================================
            // BIAS_WAIT: BRAM 레이턴시 1클록 대기
            //==========================================================
            ST_BIAS_WAIT: begin
                bram_wait <= bram_wait + 1;
                if (bram_wait == 2'd1) begin
                    // bias 데이터가 나왔으므로 래치
                    cu_bias <= $signed(bias_rdata);
                end
            end

            //==========================================================
            // FEED_MAC: weight + input을 conv_unit에 공급
            //==========================================================
            // 매 클록 1쌍(win 128bit + din 128bit)을 넣는다.
            // num_cycles번 반복하면 accumulator가 완료 펄스를 생성한다.
            //
            // weight 주소 계산:
            //   base + fil * num_cycles + feed_cnt
            //   예: Layer1, 필터#3, 사이클#5:
            //       432 + 3*9 + 5 = 464
            //
            // input 주소 계산:
            //   출력 픽셀 (out_row, out_col)에 대응하는
            //   im2col 데이터의 위치. 간단화를 위해:
            //   (out_row * out_w + out_col) * num_cycles + feed_cnt
            //   실제로는 im2col 변환이 필요하지만,
            //   SW에서 미리 im2col 형태로 저장하면 이 주소로 접근 가능.
            //==========================================================
            ST_FEED_MAC: begin
                // weight 주소 계산 및 읽기
                wgt_addr  <= param_wgt_base
                           + out_fil * param_num_cycles
                           + feed_cnt;

                // input FM 주소 계산 및 읽기
                ifm_rd_addr <= (out_row * param_out_w + out_col)
                             * param_num_cycles
                             + feed_cnt;
                ifm_rd_en   <= 1'b1;

                // BRAM 데이터는 1클록 후에 나오므로,
                // 이전 클록에서 읽은 데이터를 conv_unit에 공급
                if (feed_cnt > 0) begin
                    cu_vld_i <= 1'b1;
                    cu_win   <= wgt_rdata;      // 이전 클록에 요청한 weight
                    cu_din   <= ifm_rd_data;    // 이전 클록에 요청한 input
                end

                if (feed_cnt == param_num_cycles - 1) begin
                    // 마지막 사이클: 다음 상태에서 마지막 데이터 공급
                    feed_cnt <= feed_cnt;
                end
                else begin
                    feed_cnt <= feed_cnt + 1;
                end
            end

            //==========================================================
            // WAIT_RESULT: 마지막 데이터 공급 + output_valid 대기
            //==========================================================
            ST_WAIT_RESULT: begin
                // 첫 클록: BRAM에서 마지막 데이터 도착 → conv_unit에 공급
                if (!cu_output_valid && feed_cnt == param_num_cycles - 1) begin
                    cu_vld_i <= 1'b1;
                    cu_win   <= wgt_rdata;
                    cu_din   <= ifm_rd_data;
                    feed_cnt <= feed_cnt + 1;   // 더 이상 공급 안 하도록
                end
                // output_valid 기다림 (conv_unit 내부 파이프라인 통과 중)
            end

            //==========================================================
            // STORE_PIXEL: 결과 픽셀을 출력 FM BRAM에 저장
            //==========================================================
            ST_STORE_PIXEL: begin
                ofm_wr_en   <= 1'b1;
                ofm_wr_data <= cu_pixel_out;
                // 출력 주소: 채널별로 연속 저장
                //   fil * out_h * out_w + row * out_w + col
                ofm_wr_addr <= out_fil * param_out_h * param_out_w
                             + out_row * param_out_w
                             + out_col;
            end

            //==========================================================
            // NEXT_FILTER: 다음 필터로 이동
            //==========================================================
            ST_NEXT_FILTER: begin
                if (out_fil == param_co - 1) begin
                    out_fil <= 6'd0;    // 필터 리셋 → 다음 픽셀
                end
                else begin
                    out_fil <= out_fil + 1;
                end
            end

            //==========================================================
            // NEXT_PIXEL: 다음 출력 좌표로 이동
            //==========================================================
            ST_NEXT_PIXEL: begin
                out_fil <= 6'd0;        // 필터 인덱스 리셋
                if (out_col == param_out_w - 1) begin
                    out_col <= 9'd0;
                    out_row <= out_row + 1;
                end
                else begin
                    out_col <= out_col + 1;
                end
                pixel_cnt <= pixel_cnt + 1;
            end

            //==========================================================
            // LAYER_DONE: conv 끝, maxpool 패스 진입 (레이어/buf_sel은 유지)
            //==========================================================
            ST_LAYER_DONE: begin
                // current_layer 증가는 ST_MP_DONE에서 처리 (maxpool도 같은 layer 파라미터 사용)
            end

            //==========================================================
            // [신규] MP_INIT: maxpool 카운터 초기화
            //==========================================================
            ST_MP_INIT: begin
                mp_row        <= 9'd0;
                mp_col        <= 9'd0;
                mp_fil        <= 6'd0;
                mp_phase      <= 3'd0;
                mp_done_layer <= 1'b0;
                mp_pool_en    <= 1'b1;          // pooling 활성화
            end

            //==========================================================
            // [신규] MP_RUN: 한 윈도우(6 phase) 처리, 모든 윈도우 순회
            //
            // 윈도우 1개 타이밍 (mp_phase):
            //   0: OFM read addr0 출력 (rd_en=1)
            //   1: data0 → mp_pixel_in, pixel_valid=1; OFM read addr1 출력
            //   2: data1 → mp_pixel_in, pixel_valid=1; OFM read addr2 출력
            //   3: data2 → mp_pixel_in, pixel_valid=1; OFM read addr3 출력
            //   4: data3 → mp_pixel_in, pixel_valid=1 (마지막)
            //   5: pool_valid=1 기대, mp_wr에 max 결과 저장, 다음 윈도우로
            //
            // OFM read addr: fil*H*W + r*W + c   (conv 좌표계)
            // mp_wr addr:    fil*(H/2)*(W/2) + r*(W/2) + c   (압축 좌표계)
            //==========================================================
            ST_MP_RUN: begin
                case (mp_phase)
                    3'd0: begin
                        // read pixel (mp_fil, 2*mp_row, 2*mp_col)
                        ofm_rd_addr <= mp_fil * param_out_h * param_out_w
                                     + (mp_row << 1) * param_out_w
                                     + (mp_col << 1);
                        ofm_rd_en   <= 1'b1;
                        mp_phase    <= 3'd1;
                    end
                    3'd1: begin
                        // data0 도착 → feed; read pixel (.., 2r, 2c+1)
                        mp_pixel_in    <= ofm_rd_data;
                        mp_pixel_valid <= 1'b1;
                        ofm_rd_addr <= mp_fil * param_out_h * param_out_w
                                     + (mp_row << 1) * param_out_w
                                     + (mp_col << 1) + 1;
                        ofm_rd_en   <= 1'b1;
                        mp_phase    <= 3'd2;
                    end
                    3'd2: begin
                        // data1 도착 → feed; read pixel (.., 2r+1, 2c)
                        mp_pixel_in    <= ofm_rd_data;
                        mp_pixel_valid <= 1'b1;
                        ofm_rd_addr <= mp_fil * param_out_h * param_out_w
                                     + ((mp_row << 1) + 1) * param_out_w
                                     + (mp_col << 1);
                        ofm_rd_en   <= 1'b1;
                        mp_phase    <= 3'd3;
                    end
                    3'd3: begin
                        // data2 도착 → feed; read pixel (.., 2r+1, 2c+1)
                        mp_pixel_in    <= ofm_rd_data;
                        mp_pixel_valid <= 1'b1;
                        ofm_rd_addr <= mp_fil * param_out_h * param_out_w
                                     + ((mp_row << 1) + 1) * param_out_w
                                     + (mp_col << 1) + 1;
                        ofm_rd_en   <= 1'b1;
                        mp_phase    <= 3'd4;
                    end
                    3'd4: begin
                        // data3 도착 → feed (마지막 픽셀, pool_valid 다음 클록)
                        mp_pixel_in    <= ofm_rd_data;
                        mp_pixel_valid <= 1'b1;
                        mp_phase       <= 3'd5;
                    end
                    3'd5: begin
                        // pool_valid 펄스 확인, max 결과 저장
                        if (mp_pool_valid) begin
                            mp_wr_addr <= mp_fil * (param_out_h >> 1) * (param_out_w >> 1)
                                        + mp_row * (param_out_w >> 1)
                                        + mp_col;
                            mp_wr_data <= mp_pool_out;
                            mp_wr_en   <= 1'b1;

                            // 다음 윈도우로 진행 (mp_col → mp_row → mp_fil 순회)
                            mp_phase <= 3'd0;
                            if (mp_col == (param_out_w >> 1) - 1) begin
                                mp_col <= 9'd0;
                                if (mp_row == (param_out_h >> 1) - 1) begin
                                    mp_row <= 9'd0;
                                    if (mp_fil == param_co - 1) begin
                                        // 한 레이어 maxpool 완료
                                        mp_fil        <= 6'd0;
                                        mp_done_layer <= 1'b1;
                                    end
                                    else begin
                                        mp_fil <= mp_fil + 1;
                                    end
                                end
                                else begin
                                    mp_row <= mp_row + 1;
                                end
                            end
                            else begin
                                mp_col <= mp_col + 1;
                            end
                        end
                    end
                    default: mp_phase <= 3'd0;
                endcase
            end

            //==========================================================
            // [신규] MP_DONE: 레이어 maxpool 완료 → 다음 레이어 or 전체 완료
            //==========================================================
            ST_MP_DONE: begin
                mp_pool_en    <= 1'b0;
                mp_done_layer <= 1'b0;
                if (current_layer < 2'd2) begin
                    current_layer <= current_layer + 1;
                    buf_sel       <= ~buf_sel;  // A↔B 버퍼 스왑
                end
            end

            //==========================================================
            // DONE: 전체 완료 펄스
            //==========================================================
            ST_DONE: begin
                done <= 1'b1;
            end
        endcase
    end
end

endmodule
