`timescale 1ns/1ps
//================================================================
// axi_dma_ctrl.v — [LEGACY] DMA 읽기/쓰기 제어기
//
// ⚠️  이 파일은 레거시(legacy) 파일입니다.
//     현재 프로젝트에서는 사용하지 않으며 Vivado 소스 목록에 포함하지 마십시오.
//     대체: yolo_engine.v 내의 Top FSM이 DMA 읽기/쓰기 제어를 직접 수행.
//
// 원래 역할:
//   이전 설계에서 DMA 읽기(axi_dma_rd)와 DMA 쓰기(axi_dma_wr)를
//   블록 단위로 조율하는 상위 컨트롤러.
//   최대 i_max_req_blk_idx 개의 블록을 순서대로 읽고 쓰는 핑퐁 구조.
//
// 구조:
//   두 개의 독립 FSM 이 병렬로 동작:
//     - cstate_rd FSM: DMA 읽기 시퀀서
//     - cstate_wr FSM: DMA 쓰기 시퀀서
//
// DMA 읽기 FSM (cstate_rd):
//   ST_IDLE     : i_start=1 이면 ST_DMA 로 전이
//   ST_DMA      : ctrl_read=1 (axi_dma_rd 의 start_dma 에 해당) → ST_DMA_WAIT
//   ST_DMA_WAIT : i_read_done=1 기다림
//                 마지막 블록이면 → ST_DMA_DONE
//                 중간 블록이면  → ST_DMA_SYNC (쓰기 완료 대기)
//   ST_DMA_SYNC : i_write_done=1 기다림 → ST_DMA (다음 블록 읽기 시작)
//   ST_DMA_DONE : ctrl_read_done=1, → ST_IDLE
//
// DMA 쓰기 FSM (cstate_wr):
//   ST_IDLE     : i_read_done=1 이면 ST_DMA 로 전이 (읽기 완료 후 쓰기 시작)
//   ST_DMA      : ctrl_write=1 → ST_DMA_WAIT
//   ST_DMA_WAIT : i_write_done=1 기다림
//                 마지막 블록이면 → ST_DMA_DONE
//                 중간 블록이면  → ST_DMA_SYNC
//   ST_DMA_SYNC : i_read_done=1 기다림 → ST_DMA (다음 블록 쓰기 시작)
//   ST_DMA_DONE : ctrl_write_done=1, → ST_IDLE
//
// 주소 계산:
//   o_read_addr  = i_base_address_rd + req_blk_idx_rd × 64
//                  (블록당 64 byte = 16 워드 × 4B)
//   o_write_addr = i_base_address_wr + req_blk_idx_wr × 64
//                  + write_data_cnt × 4B
//                  (블록 내 워드 단위 오프셋 포함)
//
// 파라미터:
//   AXI_WIDTH_AD = 32 : 주소 버스 폭
//   BIT_TRANS    = 18 : num_trans / write_data_cnt 비트 폭
//================================================================

module axi_dma_ctrl #(
    parameter AXI_WIDTH_AD = 32,  // 주소 버스 폭
    parameter BIT_TRANS    = 18   // 전송 워드 카운터 비트 폭
)(
    input                   clk,
    input                   rstn,

    // 제어 입력
    input                   i_start,            // DMA 시작 트리거 (1 클록 펄스)
    input [31:0]            i_base_address_rd,  // 읽기 DRAM 기준 주소 (바이트)
    input [31:0]            i_base_address_wr,  // 쓰기 DRAM 기준 주소 (바이트)
    input [BIT_TRANS-1:0]   i_num_trans,        // 블록당 전송 워드 수
    input [15:0]            i_max_req_blk_idx,  // 총 블록 수 (읽기/쓰기 각각)

    // DMA Read 인터페이스 (axi_dma_rd 와 연결)
    input                   i_read_done,        // 읽기 DMA 완료 신호
    output                  o_ctrl_read,        // 읽기 DMA 시작 (start_dma)
    output [31:0]           o_read_addr,        // 읽기 DRAM 주소

    // DMA Write 인터페이스 (axi_dma_wr 와 연결)
    input                   i_write_done,       // 쓰기 DMA 완료 신호
    input                   i_indata_req_wr,    // 쓰기 데이터 요청 신호
    output                  o_ctrl_write,       // 쓰기 DMA 시작 (start_dma)
    output [31:0]           o_write_addr,       // 쓰기 DRAM 주소
    output [BIT_TRANS-1:0]  o_write_data_cnt,   // 쓰기 데이터 워드 카운터
    output                  o_ctrl_write_done   // 쓰기 전체 완료 신호
);

//──────────────────────────────────────────────────────────────
// FSM 상태 인코딩 (읽기 / 쓰기 FSM 공용)
//──────────────────────────────────────────────────────────────
localparam ST_IDLE     = 0,  // 초기 대기
           ST_DMA      = 1,  // DMA 시작 (ctrl=1, 1 사이클)
           ST_DMA_WAIT = 2,  // DMA 완료 대기
           ST_DMA_SYNC = 3,  // 상대 DMA 완료 동기 대기
           ST_DMA_DONE = 4;  // 전체 완료

reg [2:0] cstate_rd, nstate_rd;  // 읽기 FSM 상태
reg [2:0] cstate_wr, nstate_wr;  // 쓰기 FSM 상태

//──────────────────────────────────────────────────────────────
// DMA 읽기 내부 제어 신호
//──────────────────────────────────────────────────────────────
reg ctrl_read;       // 읽기 DMA 시작 펄스 (ST_DMA 상태에서 1)
reg ctrl_read_wait;  // 읽기 DMA 대기 중 (미사용, 디버그용)
reg ctrl_read_sync;  // 쓰기 완료 동기 대기 중 (미사용, 디버그용)
reg ctrl_read_done;  // 읽기 FSM 전체 완료 (미사용, 디버그용)
wire [AXI_WIDTH_AD-1:0] read_addr;  // 계산된 읽기 주소
reg [15:0] req_blk_idx_rd;          // 현재 읽기 블록 인덱스 (0 ~ max-1)

//──────────────────────────────────────────────────────────────
// DMA 쓰기 내부 제어 신호
//──────────────────────────────────────────────────────────────
reg ctrl_write;       // 쓰기 DMA 시작 펄스 (ST_DMA 상태에서 1)
reg ctrl_write_wait;  // 쓰기 DMA 대기 중 (미사용, 디버그용)
reg ctrl_write_sync;  // 읽기 완료 동기 대기 중 (미사용, 디버그용)
reg ctrl_write_done;  // 쓰기 FSM 전체 완료
wire [AXI_WIDTH_AD-1:0] write_addr;  // 계산된 쓰기 주소
reg [BIT_TRANS-1:0] write_data_cnt;  // 블록 내 쓰기 워드 카운터
reg [15:0] req_blk_idx_wr;           // 현재 쓰기 블록 인덱스 (0 ~ max-1)

// 입력 별칭 (wire 로 명시적 연결)
wire [BIT_TRANS-1:0] num_trans      = i_num_trans;
wire [15:0] max_req_blk_idx         = i_max_req_blk_idx;
wire [31:0] dram_base_addr_rd       = i_base_address_rd;
wire [31:0] dram_base_addr_wr       = i_base_address_wr;
wire read_done                      = i_read_done;
wire write_done                     = i_write_done;
wire indata_req_wr                  = i_indata_req_wr;

// 출력 연결
assign o_write_data_cnt  = write_data_cnt;
assign o_ctrl_write      = ctrl_write;
assign o_ctrl_read       = ctrl_read;
assign o_read_addr       = read_addr;
assign o_write_addr      = write_addr;
assign o_ctrl_write_done = ctrl_write_done;

//──────────────────────────────────────────────────────────────
// DMA 읽기 FSM
//──────────────────────────────────────────────────────────────
// 상태 레지스터
always @(posedge clk, negedge rstn) begin
    if(~rstn) cstate_rd <= ST_IDLE;
    else      cstate_rd <= nstate_rd;
end

// 조합 로직: 다음 상태 + 출력 제어
always @(*) begin
    ctrl_read      = 0;
    ctrl_read_wait = 0;
    ctrl_read_sync = 0;
    ctrl_read_done = 0;
    nstate_rd      = cstate_rd;

    case(cstate_rd)
        ST_IDLE: begin
            if(i_start) nstate_rd = ST_DMA;
            else        nstate_rd = ST_IDLE;
        end
        ST_DMA: begin
            // 읽기 시작 펄스 (axi_dma_rd.start_dma 에 해당)
            ctrl_read = 1;
            nstate_rd = ST_DMA_WAIT;
        end
        ST_DMA_WAIT: begin
            ctrl_read_wait = 1;
            if(read_done) begin
                if(req_blk_idx_rd == max_req_blk_idx - 1)
                    nstate_rd = ST_DMA_DONE;  // 마지막 블록 완료
                else
                    nstate_rd = ST_DMA_SYNC;  // 중간 블록: 쓰기 완료 동기 대기
            end
        end
        ST_DMA_SYNC: begin
            ctrl_read_sync = 1;
            // 쓰기 FSM 이 블록 처리를 완료할 때까지 대기
            if(write_done) nstate_rd = ST_DMA;  // 다음 블록 읽기 시작
        end
        ST_DMA_DONE: begin
            ctrl_read_done = 1;
            nstate_rd = ST_IDLE;
        end
    endcase
end

// 읽기 블록 인덱스 카운터 (read_done 마다 증가, 마지막 블록에서 리셋)
always @(posedge clk, negedge rstn) begin
    if(~rstn) req_blk_idx_rd <= 0;
    else begin
        if(read_done) begin
            if(req_blk_idx_rd == max_req_blk_idx - 1)
                req_blk_idx_rd <= 0;               // 마지막 블록 후 리셋
            else
                req_blk_idx_rd <= req_blk_idx_rd + 1;  // 다음 블록으로 이동
        end
    end
end

// 읽기 주소 = 기준 주소 + 블록 인덱스 × 64Byte (= <<6)
assign read_addr = dram_base_addr_rd + {req_blk_idx_rd, 6'b0};

//──────────────────────────────────────────────────────────────
// DMA 쓰기 FSM
//──────────────────────────────────────────────────────────────
// 상태 레지스터
always @(posedge clk, negedge rstn) begin
    if(~rstn) cstate_wr <= ST_IDLE;
    else      cstate_wr <= nstate_wr;
end

// 조합 로직: 다음 상태 + 출력 제어
always @(*) begin
    ctrl_write      = 0;
    ctrl_write_wait = 0;
    ctrl_write_sync = 0;
    ctrl_write_done = 0;
    nstate_wr       = cstate_wr;

    case(cstate_wr)
        ST_IDLE: begin
            // 읽기 DMA 가 한 블록을 완료하면 쓰기 시작
            if(read_done) nstate_wr = ST_DMA;
            else          nstate_wr = ST_IDLE;
        end
        ST_DMA: begin
            // 쓰기 시작 펄스 (axi_dma_wr.start_dma 에 해당)
            ctrl_write = 1;
            nstate_wr  = ST_DMA_WAIT;
        end
        ST_DMA_WAIT: begin
            ctrl_write_wait = 1;
            if(write_done) begin
                if(req_blk_idx_wr == max_req_blk_idx - 1)
                    nstate_wr = ST_DMA_DONE;  // 마지막 블록 완료
                else
                    nstate_wr = ST_DMA_SYNC;  // 중간 블록: 읽기 완료 동기 대기
            end
        end
        ST_DMA_SYNC: begin
            ctrl_write_sync = 1;
            // 읽기 FSM 이 다음 블록 읽기를 완료할 때까지 대기
            if(read_done) nstate_wr = ST_DMA;  // 다음 블록 쓰기 시작
        end
        ST_DMA_DONE: begin
            ctrl_write_done = 1;
            nstate_wr = ST_IDLE;
        end
    endcase
end

// 쓰기 블록 인덱스 카운터 (write_done 마다 증가)
always @(posedge clk, negedge rstn) begin
    if(~rstn) req_blk_idx_wr <= 0;
    else begin
        if(write_done) begin
            if(req_blk_idx_wr == max_req_blk_idx - 1)
                req_blk_idx_wr <= 0;
            else
                req_blk_idx_wr <= req_blk_idx_wr + 1;
        end
    end
end

// 블록 내 쓰기 워드 카운터
//   ctrl_write=1: 새 블록 시작 → 카운터 리셋
//   indata_req_wr=1: 데이터 요청마다 1 증가 (num_trans 에서 리셋)
always @(posedge clk, negedge rstn) begin
    if(~rstn) write_data_cnt <= 0;
    else begin
        if(ctrl_write)
            write_data_cnt <= 0;
        else if(indata_req_wr) begin
            if(write_data_cnt == num_trans - 1)
                write_data_cnt <= 0;
            else
                write_data_cnt <= write_data_cnt + 1;
        end
    end
end

// 쓰기 주소 = 기준 주소 + 블록 인덱스 × 64Byte + 워드 카운터 × 4Byte
assign write_addr = dram_base_addr_wr + {req_blk_idx_wr, 6'b0} + {write_data_cnt, 2'b0};

endmodule
