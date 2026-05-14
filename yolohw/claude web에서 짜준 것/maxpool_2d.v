`timescale 1ns / 1ps

//================================================================
// 모듈명: maxpool_2d
//
// 역할: conv_layer_ctrl에서 흘러나오는 (row, col, fil) 순서의
//       8bit 픽셀 스트림을 받아 2×2 stride-2 max pooling을 수행하고,
//       출력 OFM BRAM에 채널-우선(NCHW) 순서로 저장한다.
//
// 입력 픽셀 순서(conv_layer_ctrl의 NEXT_PIXEL/NEXT_FILTER 루프):
//   for row in 0..H-1
//     for col in 0..W-1
//       for fil in 0..Co-1
//         conv_out_pixel = pixel(row, col, fil)
//
// 풀링 알고리즘 (Line Buffer 방식):
//   - 짝수 row: 모든 (col, fil) 픽셀을 line_buf[col*Co + fil]에 저장
//   - 홀수 row, 짝수 col: 새 픽셀과 line_buf의 짝지어진 픽셀의 max를
//                         left_max[fil]에 저장
//   - 홀수 row, 홀수 col: 새 col_max와 left_max[fil]의 최종 max를
//                         OFM에 쓴다 (출력 좌표: row/2, col/2, fil)
//
// 출력 OFM 레이아웃 (NCHW, 채널 가장 느린 차원):
//   out_addr = fil * (out_h * out_w) + out_row * out_w + out_col
//
// 레이어별 입력 차원 (conv_layer_ctrl의 current_layer로 디코딩):
//   L0: 256×256×16 → 128×128×16
//   L1: 128×128×32 → 64×64×32
//   L2: 64×64×64   → 32×32×64
//
// Line buffer 깊이 = max(W*Co) = max(256*16, 128*32, 64*64) = 4096 byte
// Left  buffer 깊이 = max(Co)   = 64 byte
//================================================================

module maxpool_2d (
    input               clk,
    input               rstn,

    //----------------------------------------------------------
    // conv_layer_ctrl로부터의 입력 스트림
    //----------------------------------------------------------
    input               conv_valid,     // 픽셀 유효 펄스
    input      [7:0]    conv_pixel,
    input      [8:0]    conv_row,
    input      [8:0]    conv_col,
    input      [5:0]    conv_fil,
    input      [1:0]    current_layer,  // 0/1/2: 입력 해상도 디코딩

    //----------------------------------------------------------
    // conv_layer_ctrl과의 핸드셰이크
    //----------------------------------------------------------
    input               layer_conv_done,// 1펄스: 이 레이어 conv 종료 통지
    output reg          maxpool_done,   // 1펄스: 이 레이어 maxpool 결과 모두 OFM에 기록 완료

    //----------------------------------------------------------
    // OFM BRAM(dpram_wrapper) 쓰기 포트
    //   주소 폭: 18비트 (Layer 0 maxpool 출력 128*128*16 = 262144)
    //----------------------------------------------------------
    output reg          ofm_wr_en,
    output reg [17:0]   ofm_wr_addr,
    output reg [7:0]    ofm_wr_data
);

//----------------------------------------------------------------------
// 레이어별 차원 디코딩 (입력 = conv 출력 해상도)
//----------------------------------------------------------------------
reg [8:0]  in_w;       // 입력 폭   (= conv 출력 폭)
reg [8:0]  out_w;      // 출력 폭   (= in_w / 2)
reg [8:0]  out_h;      // 출력 높이 (= in_h / 2)
reg [5:0]  co;         // 채널 수
reg [17:0] ch_stride;  // out_h * out_w (한 채널 픽셀 수)

always @(*) begin
    case (current_layer)
        2'd0: begin
            in_w      = 9'd256;
            out_w     = 9'd128;
            out_h     = 9'd128;
            co        = 6'd16;
            ch_stride = 18'd16384;   // 128*128
        end
        2'd1: begin
            in_w      = 9'd128;
            out_w     = 9'd64;
            out_h     = 9'd64;
            co        = 6'd32;
            ch_stride = 18'd4096;    // 64*64
        end
        2'd2: begin
            in_w      = 9'd64;
            out_w     = 9'd32;
            out_h     = 9'd32;
            co        = 6'd64;
            ch_stride = 18'd1024;    // 32*32
        end
        default: begin
            in_w      = 9'd256;
            out_w     = 9'd128;
            out_h     = 9'd128;
            co        = 6'd16;
            ch_stride = 18'd16384;
        end
    endcase
end

//----------------------------------------------------------------------
// 메모리
//----------------------------------------------------------------------
// 짝수 row의 한 줄(가로 in_w개 × Co채널) 임시 저장
reg [7:0] line_buf [0:4095];

// 홀수 row의 짝수 col에서 계산된 col-max를 임시 저장 (Co개)
reg [7:0] left_max [0:63];

//----------------------------------------------------------------------
// 인덱스 계산 (조합 로직)
//----------------------------------------------------------------------
// 16384 < 2^14, in_col*co + conv_fil 의 최대 = 255*64+63 = 16383 → 14비트 충분
wire [13:0] line_buf_addr = conv_col * co + conv_fil;

// 같은 (col, fil)에 대한 짝수 row의 픽셀
wire [7:0]  prev_row_pix  = line_buf[line_buf_addr];

// 새 픽셀과 이전 row 픽셀의 max
wire [7:0]  col_max       = (conv_pixel > prev_row_pix) ? conv_pixel : prev_row_pix;

// 4픽셀 최종 max (홀수 col에서 사용)
wire [7:0]  final_max     = (col_max > left_max[conv_fil]) ? col_max : left_max[conv_fil];

//----------------------------------------------------------------------
// maxpool 완료 카운트 (마지막 4픽셀 윈도우까지 OFM에 쓴 뒤 pulse)
//----------------------------------------------------------------------
reg layer_conv_done_lat;     // conv_layer_ctrl이 layer_conv_done을 1펄스 보냄
reg done_pending;            // 마지막 윈도우의 쓰기 1클록을 기다림

//----------------------------------------------------------------------
// 메인 로직
//----------------------------------------------------------------------
integer i;
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        ofm_wr_en           <= 1'b0;
        ofm_wr_addr         <= 18'd0;
        ofm_wr_data         <= 8'd0;
        maxpool_done        <= 1'b0;
        layer_conv_done_lat <= 1'b0;
        done_pending        <= 1'b0;
        // 시뮬레이션 안정성을 위해 left_max만 초기화 (line_buf는 짝수row에서 항상 덮어씀)
        for (i = 0; i < 64; i = i + 1)
            left_max[i] <= 8'd0;
    end
    else begin
        // 매 클록 디어서트
        ofm_wr_en    <= 1'b0;
        maxpool_done <= 1'b0;

        //--------------------------------------------------------
        // CONV 픽셀 1개 도착 → 풀링 처리
        //--------------------------------------------------------
        if (conv_valid) begin
            // 짝수 row: line_buf에만 저장
            if (conv_row[0] == 1'b0) begin
                line_buf[line_buf_addr] <= conv_pixel;
            end
            // 홀수 row: 풀링 비교 진행
            else begin
                if (conv_col[0] == 1'b0) begin
                    // 짝수 col: (row-1,col)과 (row,col)의 max를 left_max에 저장
                    left_max[conv_fil] <= col_max;
                end
                else begin
                    // 홀수 col: 4픽셀 최종 max를 OFM에 기록
                    ofm_wr_en   <= 1'b1;
                    ofm_wr_data <= final_max;
                    // NCHW: fil * (out_h*out_w) + (row>>1)*out_w + (col>>1)
                    ofm_wr_addr <= conv_fil * ch_stride
                                 + conv_row[8:1] * out_w
                                 + conv_col[8:1];
                end
            end
        end

        //--------------------------------------------------------
        // 레이어 conv 종료 통지 → 마지막 쓰기 클록 후 done 펄스
        //--------------------------------------------------------
        if (layer_conv_done) begin
            layer_conv_done_lat <= 1'b1;
            done_pending        <= 1'b1;
        end

        // 마지막 conv 픽셀이 OFM에 기록되는 클록은 conv_valid와 동시.
        // layer_conv_done은 conv_layer_ctrl이 WAIT_MAXPOOL 진입 후 발사하므로
        // 그 이후 1~2 클록 안에 모든 쓰기가 끝난다. 1클록 마진을 둠.
        if (done_pending) begin
            maxpool_done        <= 1'b1;
            layer_conv_done_lat <= 1'b0;
            done_pending        <= 1'b0;
            // 다음 레이어 대비 left_max 초기화
            for (i = 0; i < 64; i = i + 1)
                left_max[i] <= 8'd0;
        end
    end
end

endmodule
