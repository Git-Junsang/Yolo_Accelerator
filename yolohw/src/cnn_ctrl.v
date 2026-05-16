`timescale 1ns / 1ps
//================================================================
// cnn_ctrl.v — [LEGACY] CNN 픽셀 스트림 타이밍 제어기
//
// ⚠️  이 파일은 레거시(legacy) 파일입니다.
//     현재 프로젝트에서는 사용하지 않으며 Vivado 소스 목록에 포함하지 마십시오.
//     대체: yolo_engine.v 의 Top FSM 이 레이어별 픽셀 좌표 / 타이밍을 직접 관리.
//
// 원래 역할:
//   카메라 센서 또는 비디오 스트림처럼 vsync/hsync 가 있는 픽셀 입력 방식에서
//   CNN 레이어의 row/col 타이밍과 유효 데이터 구간을 생성하는 컨트롤러.
//
// 4-상태 FSM:
//   ST_IDLE  : q_start=1 이면 ST_VSYNC 로 전이
//   ST_VSYNC : 수직 동기 지연 (ctrl_vsync_cnt 가 q_vsync_delay 에 도달하면 ST_HSYNC)
//   ST_HSYNC : 수평 동기 지연 (ctrl_hsync_cnt 가 q_hsync_delay 에 도달하면 ST_DATA)
//   ST_DATA  : 실제 픽셀 전송 구간
//              col == q_width-1: 행 끝 → ST_HSYNC (다음 행의 수평 동기)
//              data_count == q_frame_size-1: 프레임 끝 → ST_IDLE
//
// 출력 타이밍:
//   o_ctrl_vsync_run : ST_VSYNC 에서 1 (수직 동기 진행 중)
//   o_ctrl_hsync_run : ST_HSYNC 에서 1 (수평 동기 진행 중)
//   o_ctrl_data_run  : ST_DATA  에서 1 (픽셀 데이터 유효)
//   o_row, o_col     : 현재 픽셀 좌표 (ST_DATA 내에서 자동 증가)
//   o_data_count     : 누적 픽셀 카운터 (0 ~ q_frame_size-1)
//   o_end_frame      : 마지막 픽셀 여부 (data_count == q_frame_size-1)
//
// 파라미터:
//   W_SIZE       = 12 : row/col 비트 폭 (최대 4096 픽셀, 4K 해상도 대응)
//   W_FRAME_SIZE = 25 : data_count 비트 폭 (= 2×W_SIZE+1, 최대 33M 픽셀)
//   W_DELAY      = 12 : vsync/hsync 지연 카운터 비트 폭
//================================================================
module cnn_ctrl(
    clk,
    rstn,

    // 설정 입력
    q_width,        // 이미지 가로 픽셀 수
    q_height,       // 이미지 세로 픽셀 수
    q_vsync_delay,  // 수직 동기 지연 클록 수 (ST_VSYNC 구간 길이)
    q_hsync_delay,  // 수평 동기 지연 클록 수 (ST_HSYNC 구간 길이)
    q_frame_size,   // 프레임 총 픽셀 수 (= q_width × q_height)
    q_start,        // 시작 트리거 (1 클록 펄스)

    // 상태 출력
    o_ctrl_vsync_run,  // 수직 동기 구간 진행 중 (1=ST_VSYNC)
    o_ctrl_vsync_cnt,  // 수직 동기 카운터 현재값
    o_ctrl_hsync_run,  // 수평 동기 구간 진행 중 (1=ST_HSYNC)
    o_ctrl_hsync_cnt,  // 수평 동기 카운터 현재값
    o_ctrl_data_run,   // 픽셀 데이터 유효 구간 (1=ST_DATA)

    // 픽셀 좌표 / 카운터
    o_row,         // 현재 행 인덱스 (0 ~ q_height-1)
    o_col,         // 현재 열 인덱스 (0 ~ q_width-1)
    o_data_count,  // 누적 픽셀 카운터 (0 ~ q_frame_size-1)
    o_end_frame    // 프레임 끝 신호 (마지막 픽셀 사이클에 1)
);

parameter W_SIZE       = 12;              // row/col 비트 폭 (최대 4096 픽셀)
parameter W_FRAME_SIZE = 2 * W_SIZE + 1;  // data_count 비트 폭 (= 25)
parameter W_DELAY      = 12;              // 동기 지연 카운터 비트 폭

input clk, rstn;
input [W_SIZE-1 :0]      q_width;       // 이미지 가로 픽셀 수
input [W_SIZE-1 :0]      q_height;      // 이미지 세로 픽셀 수
input [W_DELAY-1:0]      q_vsync_delay; // 수직 동기 지연
input [W_DELAY-1:0]      q_hsync_delay; // 수평 동기 지연
input [W_FRAME_SIZE-1:0] q_frame_size;  // 총 픽셀 수 (q_width × q_height)
input q_start;

output                    o_ctrl_vsync_run;
output [W_DELAY-1:0]      o_ctrl_vsync_cnt;
output                    o_ctrl_hsync_run;
output [W_DELAY-1:0]      o_ctrl_hsync_cnt;
output                    o_ctrl_data_run;
output [W_SIZE-1:0]       o_row;
output [W_SIZE-1:0]       o_col;
output [W_FRAME_SIZE-1:0] o_data_count;
output                    o_end_frame;

//──────────────────────────────────────────────────────────────
// 내부 신호
//──────────────────────────────────────────────────────────────
// FSM 상태 인코딩
localparam ST_IDLE  = 2'b00,  // 초기 대기
           ST_VSYNC = 2'b01,  // 수직 동기 지연 구간
           ST_HSYNC = 2'b10,  // 수평 동기 지연 구간
           ST_DATA  = 2'b11;  // 픽셀 데이터 유효 구간

reg [1:0] cstate, nstate;  // FSM 현재/다음 상태

reg              ctrl_vsync_run;  // 수직 동기 진행 중 플래그
reg [W_DELAY-1:0] ctrl_vsync_cnt; // 수직 동기 카운터
reg              ctrl_hsync_run;  // 수평 동기 진행 중 플래그
reg [W_DELAY-1:0] ctrl_hsync_cnt; // 수평 동기 카운터
reg              ctrl_data_run;   // 픽셀 유효 구간 플래그

reg [W_SIZE-1:0]       row;        // 현재 행 인덱스
reg [W_SIZE-1:0]       col;        // 현재 열 인덱스
reg [W_FRAME_SIZE-1:0] data_count; // 누적 픽셀 카운터

// 프레임 끝 신호: data_count 가 마지막 픽셀에 도달하면 1
wire end_frame = (data_count == q_frame_size - 1) ? 1'b1 : 1'b0;

//──────────────────────────────────────────────────────────────
// FSM 상태 레지스터
//──────────────────────────────────────────────────────────────
always @(posedge clk, negedge rstn) begin
    if(!rstn) cstate <= ST_IDLE;
    else      cstate <= nstate;
end

//──────────────────────────────────────────────────────────────
// FSM 다음 상태 로직
//──────────────────────────────────────────────────────────────
always @(*) begin
    case(cstate)
        ST_IDLE: begin
            if(q_start) nstate = ST_VSYNC;
            else         nstate = ST_IDLE;
        end
        ST_VSYNC: begin
            // 수직 동기 지연 완료 → 첫 행의 수평 동기 시작
            if(ctrl_vsync_cnt == q_vsync_delay) nstate = ST_HSYNC;
            else                                 nstate = ST_VSYNC;
        end
        ST_HSYNC: begin
            // 수평 동기 지연 완료 → 픽셀 데이터 전송 시작
            if(ctrl_hsync_cnt == q_hsync_delay) nstate = ST_DATA;
            else                                 nstate = ST_HSYNC;
        end
        ST_DATA: begin
            if(end_frame)                   nstate = ST_IDLE;  // 프레임 전체 완료
            else if(col == q_width - 1)     nstate = ST_HSYNC; // 행 끝 → 다음 행 동기
            else                            nstate = ST_DATA;
        end
        default: nstate = ST_IDLE;
    endcase
end

//──────────────────────────────────────────────────────────────
// FSM 출력 로직 (조합)
//──────────────────────────────────────────────────────────────
always @(*) begin
    ctrl_vsync_run = 0;
    ctrl_hsync_run = 0;
    ctrl_data_run  = 0;
    case(cstate)
        ST_VSYNC: ctrl_vsync_run = 1;  // 수직 동기 구간
        ST_HSYNC: ctrl_hsync_run = 1;  // 수평 동기 구간
        ST_DATA:  ctrl_data_run  = 1;  // 픽셀 데이터 구간
    endcase
end

//──────────────────────────────────────────────────────────────
// vsync / hsync 카운터
//   각 동기 구간에서 1씩 증가. 구간 이탈 시 리셋.
//──────────────────────────────────────────────────────────────
always @(posedge clk, negedge rstn) begin
    if(!rstn) begin
        ctrl_vsync_cnt <= 0;
        ctrl_hsync_cnt <= 0;
    end
    else begin
        if(ctrl_vsync_run) ctrl_vsync_cnt <= ctrl_vsync_cnt + 1;
        else               ctrl_vsync_cnt <= 0;  // ST_VSYNC 이탈 시 리셋

        if(ctrl_hsync_run) ctrl_hsync_cnt <= ctrl_hsync_cnt + 1;
        else               ctrl_hsync_cnt <= 0;  // ST_HSYNC 이탈 시 리셋
    end
end

//──────────────────────────────────────────────────────────────
// 픽셀 좌표 (row, col) 업데이트
//   ST_DATA 구간에서만 증가.
//   col == q_width-1: 행 끝 → col 리셋, row 증가
//   end_frame: 프레임 끝 → row 리셋
//──────────────────────────────────────────────────────────────
always @(posedge clk, negedge rstn) begin
    if(!rstn) begin
        row <= 0;
        col <= 0;
    end
    else begin
        if(ctrl_data_run) begin
            if(col == q_width - 1) begin
                if(end_frame) row <= 0;   // 프레임 끝: row 리셋
                else          row <= row + 1;  // 다음 행으로 이동
            end
            if(col == q_width - 1) col <= 0;      // 행 끝: col 리셋
            else                   col <= col + 1; // 다음 열로 이동
        end
    end
end

//──────────────────────────────────────────────────────────────
// 누적 픽셀 카운터 (data_count)
//   ST_DATA 구간에서만 증가. 프레임 끝에서 리셋.
//──────────────────────────────────────────────────────────────
always @(posedge clk, negedge rstn) begin
    if(!rstn) data_count <= 0;
    else begin
        if(ctrl_data_run) begin
            if(!end_frame) data_count <= data_count + 1;
            else           data_count <= 0;  // 프레임 끝: 리셋
        end
    end
end

//──────────────────────────────────────────────────────────────
// 출력 연결
//──────────────────────────────────────────────────────────────
assign o_ctrl_vsync_run = ctrl_vsync_run;
assign o_ctrl_vsync_cnt = ctrl_vsync_cnt;
assign o_ctrl_hsync_run = ctrl_hsync_run;
assign o_ctrl_hsync_cnt = ctrl_hsync_cnt;
assign o_ctrl_data_run  = ctrl_data_run;
assign o_row            = row;
assign o_col            = col;
assign o_data_count     = data_count;
assign o_end_frame      = end_frame;

endmodule
