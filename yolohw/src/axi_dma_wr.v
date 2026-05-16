//================================================================
// axi_dma_wr.v — AXI4 마스터 쓰기 DMA 모듈
//
// 역할:
//   yolo_engine 의 추론 결과(OFM, Output Feature Map)를
//   AXI4 버스를 통해 DRAM(DDR2/DDR3)에 기록한다.
//   yolo_engine.v 의 DMA write 경로에 인스턴스화되어 사용된다.
//
// 동작 개요:
//   start_dma=1 을 한 클록 동안 어서트하면 쓰기 DMA 동작 시작.
//   num_trans 개의 32-bit 워드를 start_addr 부터 순서대로 DRAM에 기록.
//   쓰기는 FIXED_BURST_SIZE(=256) 워드 단위의 AXI4 INCR burst 로 분할.
//   indata_req_o=1 일 때 indata 에 유효 데이터를 공급해야 함.
//   마지막 burst 응답 수신 후 done_o=1 을 어서트.
//
// AXI4 버스 채널:
//   AW 채널 (Write Address): M_AWVALID/M_AWREADY 핸드셰이크로 burst 주소 전송
//   W  채널 (Write Data):    M_WVALID/M_WREADY 핸드셰이크로 데이터 전송
//                            M_WLAST = burst 마지막 beat
//                            M_WSTRB = 바이트 enable (32-bit이므로 4'b1111 고정)
//   B  채널 (Write Response):M_BVALID/M_BREADY 핸드셰이크로 응답 수신
//                            M_BRESP = 응답 코드 (2'b00=OKAY)
//
// 6-상태 FSM (st_wr2axi):
//   WR_IDLE  : start_dma 를 기다리는 초기 상태
//              start_dma=1 → WR_PRE 로 전이
//
//   WR_PRE   : burst 시작 전 준비 단계 / 완료 판단
//              q_burst_cnt_wr == num_trans_d 이면 전체 완료 → WR_IDLE (done_o=1)
//              아직 쓸 데이터 있으면 → WR_START
//
//   WR_START : AW 채널에 주소/길이 정보 전송 (ext_awvalid=1)
//              ext_awready=1 이면 핸드셰이크 완료 → WR_SEQ (indata_req_o=1)
//              AWSIZE = SIZE_4B(3'b010, 32-bit), AWBURST=INCR(2'b01)
//
//   WR_SEQ   : W 채널에서 beat 단위로 데이터 전송
//              ext_wready=1 일 때마다 indata를 ext_wdata로 출력
//              beat 카운터(q_beat_cnt_wr) == q_burst_size_wr 이면 마지막 beat
//                → ext_wlast=1, → WR_WAIT
//              아직 마지막이 아니면 indata_req_o=1 (다음 데이터 요청)
//
//   WR_WAIT  : B 채널에서 응답(BRESP) 대기 (ext_bready=1)
//              ext_bvalid=1, BRESP=OKAY(2'b00) 이면:
//                burst 카운터 += q_burst_size_wr_1 → WR_PRE
//              에러이면: beat 카운터 리셋 → WR_PRE (재시도는 WR_START에서)
//
//   WR_BUFF_WAIT: 예약 상태 (현재 bypass됨, WR_START→WR_SEQ 직접 전이)
//
// 버스트 분할 로직:
//   - q_burst_cnt_wr: 지금까지 완료된 누적 워드 수
//   - FIXED_BURST_SIZE=256: 한 번 burst에서 최대 256 워드(1KB) 전송
//   - 마지막 burst에서 잔여 워드 수 < 256 이면 q_burst_size_wr 조정
//
// 입력 데이터 인터페이스:
//   indata_req_o=1 인 클록 다음 사이클에 indata 가 유효해야 함
//   (1-cycle look-ahead 요청 방식)
//
// 파라미터:
//   OUT_BITS_TRANS = 13: num_trans 비트 폭 (최대 8192 워드)
//   AXI_WIDTH_DA   = 32: 데이터 버스 폭 (32-bit 고정)
//================================================================
`timescale 1ns/1ps

module axi_dma_wr(
    //AXI Master Interface
    //Write address channel
    M_AWVALID,    // AW 채널: 주소/제어 유효 (마스터→슬레이브)
    M_AWADDR,     // AW 채널: 쓰기 시작 주소
    M_AWREADY,    // AW 채널: 주소 수락 준비 (슬레이브→마스터)
    M_AWID,       // AW 채널: 트랜잭션 ID (0 고정)
    M_AWLEN,      // AW 채널: burst beat 수 - 1 (0~255)
    M_AWSIZE,     // AW 채널: beat 당 바이트 크기 (3'b010 = 4B)
    M_AWBURST,    // AW 채널: burst 타입 (2'b01 = INCR)
    M_AWLOCK,     // AW 채널: 원자적 접근 (0 고정)
    M_AWCACHE,    // AW 채널: 캐시 속성 (0 고정)
    M_AWPROT,     // AW 채널: 보호 레벨 (0 고정)
    M_AWQOS,      // AW 채널: QoS (최고 우선순위 4'b1111)
    M_AWREGION,   // AW 채널: 리전 (0 고정)
    M_AWUSER,     // AW 채널: 사용자 정의 (0 고정)

    //Write data channel
    M_WVALID,     // W 채널: 쓰기 데이터 유효 (마스터→슬레이브)
    M_WREADY,     // W 채널: 수신 준비 (슬레이브→마스터)
    M_WDATA,      // W 채널: 쓰기 데이터 (32-bit)
    M_WSTRB,      // W 채널: 바이트 스트로브 (4'b1111 = 전체 4바이트 유효)
    M_WLAST,      // W 채널: burst 마지막 beat 표시
    M_WID,        // W 채널: 트랜잭션 ID (0 고정)
    M_WUSER,      // W 채널: 사용자 정의 (0 고정)

    //Write response channel
    M_BVALID,     // B 채널: 응답 유효 (슬레이브→마스터)
    M_BREADY,     // B 채널: 응답 수락 준비 (마스터→슬레이브)
    M_BRESP,      // B 채널: 응답 코드 (2'b00=OKAY)
    M_BID,        // B 채널: 트랜잭션 ID (사용 안 함)
    M_BUSER,      // B 채널: 사용자 정의 (사용 안 함)

    //User interface (yolo_engine.v 와의 인터페이스)
    start_dma,      // 1 클록 펄스: DMA 시작 트리거
    done_o,         // 전체 DMA 완료 플래그 (WR_PRE에서 완료 시 1)
    num_trans,      // 기록할 총 32-bit 워드 수
    start_addr,     // DRAM 쓰기 시작 주소 (바이트 단위)
    indata,         // 쓰기 데이터 입력 (indata_req_o 의 다음 사이클에 유효)
    indata_req_o,   // 데이터 요청 신호 (1=다음 사이클에 indata 유효해야 함)
    fail_check,     // 디버그용: BRESP 에러 발생 시 1
    //User signals
    clk,
    rstn
);
    // ──────────────────────────────────────────────────────────────
    // 파라미터
    // ──────────────────────────────────────────────────────────────
    parameter BITS_TRANS     = 18;  // (미사용, 호환성 유지)
    parameter OUT_BITS_TRANS = 13;  // num_trans 비트 폭 (최대 8192 워드)

    parameter AXI_WIDTH_USER = 1;               // Master User 신호 폭
    parameter AXI_WIDTH_ID   = 4;               // ID 비트 폭
    parameter AXI_WIDTH_AD   = 32;              // 주소 버스 폭
    parameter AXI_WIDTH_DA   = 32;              // 데이터 버스 폭 (32-bit 고정)
    parameter AXI_WIDTH_DS   = (AXI_WIDTH_DA/8); // 스트로브 폭 (= 4)

    // AXI 포트 방향 선언
    output                     M_AWVALID;
    input                      M_AWREADY;
    output [AXI_WIDTH_AD-1:0]  M_AWADDR;
    output [AXI_WIDTH_ID-1:0]  M_AWID;
    output [7:0]               M_AWLEN;
    output [2:0]               M_AWSIZE;
    output [1:0]               M_AWBURST;
    output [1:0]               M_AWLOCK;
    output [3:0]               M_AWCACHE;
    output [2:0]               M_AWPROT;
    output [3:0]               M_AWQOS;
    output [3:0]               M_AWREGION;
    output [3:0]               M_AWUSER;

    output                     M_WVALID;
    input                      M_WREADY;
    output [AXI_WIDTH_DA-1:0]  M_WDATA;
    output [AXI_WIDTH_DS-1:0]  M_WSTRB;
    output                     M_WLAST;
    output [AXI_WIDTH_ID-1:0]  M_WID;
    output [3:0]               M_WUSER;

    input                       M_BVALID;
    output                      M_BREADY;
    input [1:0]                 M_BRESP;
    input [AXI_WIDTH_ID-1:0]    M_BID;
    input                       M_BUSER;

    input                       start_dma;
    output reg                  done_o;
    input [OUT_BITS_TRANS-1:0]  num_trans;
    input [AXI_WIDTH_DA-1:0]    start_addr;
    input [AXI_WIDTH_DA-1:0]    indata;
    output reg                  indata_req_o;
    output reg                  fail_check;
    input clk;
    input rstn;

//──────────────────────────────────────────────────────────────────────
// 내부 상수 (localparam)
//──────────────────────────────────────────────────────────────────────
    localparam FIXED_BURST_SIZE = 256;  // 한 burst 최대 워드 수 (AXI4 max = 256)
    localparam DEFAULT_ID       = 0;    // 트랜잭션 ID (단일 outstanding)

    // AXI beat 크기 인코딩
    localparam SIZE_1B   = 3'b000;  // 1 Byte/beat
    localparam SIZE_2B   = 3'b001;  // 2 Byte/beat
    localparam SIZE_4B   = 3'b010;  // 4 Byte/beat (32-bit 버스에 사용)
    localparam SIZE_8B   = 3'b011;  // 8 Byte/beat (미지원)
    localparam SIZE_16B  = 3'b100;  // 미지원
    localparam SIZE_32B  = 3'b101;  // 미지원
    localparam SIZE_64B  = 3'b110;  // 미지원
    localparam SIZE_128B = 3'b111;  // 미지원

    // AXI write response 코드
    localparam RESP_OKAY   = 2'b00;  // 정상 완료
    localparam RESP_EXOKAY = 2'b01;  // 독점 접근 성공 (미사용)
    localparam RESP_SLVERR = 2'b10;  // 슬레이브 에러
    localparam RESP_DECERR = 2'b11;  // 디코드 에러

    localparam LOG_BURST_SIZE = $clog2(FIXED_BURST_SIZE);  // = 8

//──────────────────────────────────────────────────────────────────────
// 내부 신호 선언 (ext_* : AXI 포트와 FSM 사이 중간 레지스터/와이어)
//──────────────────────────────────────────────────────────────────────
    reg  [AXI_WIDTH_AD-1:0] ext_awaddr ;  // AW 채널 주소
    reg  [7:0]              ext_awlen  ;  // AW 채널 burst 길이 (beat-1)
    reg  [2:0]              ext_awsize ;  // AW 채널 beat 크기
    reg                     ext_awvalid;  // AW 채널 유효
    wire                    ext_awready;  // AW 채널 슬레이브 준비

    reg  [AXI_WIDTH_DA-1:0] ext_wdata  ;  // W 채널 데이터
    reg  [AXI_WIDTH_DS-1:0] ext_wstrb  ;  // W 채널 스트로브
    reg                     ext_wlast  ;  // W 채널 마지막 beat
    reg                     ext_wvalid ;  // W 채널 유효
    wire                    ext_wready ;  // W 채널 슬레이브 준비

    wire [AXI_WIDTH_ID-1:0] ext_bid    ;  // B 채널 ID (미사용)
    wire [1:0]              ext_bresp  ;  // B 채널 응답 코드
    wire                    ext_bvalid ;  // B 채널 유효
    reg                     ext_bready ;  // B 채널 수락 준비

    // AXI 고정 출력 (사이드밴드 신호)
    assign M_AWID     = DEFAULT_ID;
    assign M_WID      = DEFAULT_ID;
    assign M_AWBURST  = 2'b01;   // INCR burst
    assign M_AWLOCK   = 2'b00;   // 비원자적 접근
    assign M_AWCACHE  = 4'b0000; // 캐시 불가 / 버퍼 불가
    assign M_AWPROT   = 3'b000;  // 비보안, 데이터 접근
    assign M_AWQOS    = 4'b1111; // 최고 QoS 우선순위
    assign M_AWREGION = 4'b0000;
    assign M_AWUSER   = 4'b0000;
    assign M_WUSER    = 4'b0000;

    // AXI 포트 ↔ ext_* 연결
    assign M_AWVALID  = ext_awvalid;
    assign M_AWADDR   = ext_awaddr;
    assign M_AWLEN    = ext_awlen;
    assign M_AWSIZE   = ext_awsize;
    assign ext_awready = M_AWREADY;

    assign M_WVALID   = ext_wvalid;
    assign M_WDATA    = ext_wdata;
    assign M_WSTRB    = ext_wstrb;
    assign M_WLAST    = ext_wlast;
    assign ext_wready  = M_WREADY;

    assign ext_bid     = M_BID;
    assign ext_bresp   = M_BRESP;
    assign ext_bvalid  = M_BVALID;
    assign M_BREADY    = ext_bready;

//──────────────────────────────────────────────────────────────────────
// 내부 제어 레지스터
//──────────────────────────────────────────────────────────────────────
    reg [OUT_BITS_TRANS-1:0] num_trans_d;         // start_dma 시점 num_trans 래치
    reg [7:0]  d_beat_cnt_wr, q_beat_cnt_wr;      // burst 내 현재 beat 카운터
    reg [OUT_BITS_TRANS-1:0] d_burst_cnt_wr, q_burst_cnt_wr; // 누적 완료 워드 수
    reg [7:0]  q_burst_size_wr;    // 현재 burst beat 수 - 1 (AWLEN 값)
    reg [8:0]  q_burst_size_wr_1;  // 현재 burst beat 수 (카운터 증분용)
    reg [AXI_WIDTH_AD-1:0] q_ext_addr_wr;  // 현재 burst 시작 주소

    // FSM 상태
    reg [2:0] st_wr2axi, next_st_wr2axi;
    localparam WR_IDLE      = 0,  // 초기 대기
               WR_PRE       = 1,  // burst 준비 / 완료 판단
               WR_START     = 2,  // AW 채널 핸드셰이크
               WR_BUFF_WAIT = 3,  // (예약, 현재 bypass)
               WR_SEQ       = 4,  // W 채널 beat 전송
               WR_WAIT      = 5;  // B 채널 응답 대기

//──────────────────────────────────────────────────────────────────────
// num_trans 래치: start_dma 어서트 시점에 캡처
//──────────────────────────────────────────────────────────────────────
    always @(posedge clk or negedge rstn) begin
        if(!rstn)          num_trans_d <= 'h0;
        else if(start_dma) num_trans_d <= num_trans;
    end

//──────────────────────────────────────────────────────────────────────
// beat / burst 카운터 업데이트 (순차 로직)
//──────────────────────────────────────────────────────────────────────
    always @(posedge clk or negedge rstn) begin
        if(!rstn) begin
            q_beat_cnt_wr  <= 0;
            q_burst_cnt_wr <= 0;
        end
        else begin
            q_beat_cnt_wr  <= d_beat_cnt_wr;
            q_burst_cnt_wr <= d_burst_cnt_wr;
        end
    end

//──────────────────────────────────────────────────────────────────────
// burst 크기 계산
//   - 잔여 워드 < FIXED_BURST_SIZE: 마지막 burst → 잔여 워드 수 사용
//   - 그 외: 중간 burst → FIXED_BURST_SIZE 워드 전송
//──────────────────────────────────────────────────────────────────────
    always @(posedge clk or negedge rstn) begin
        if(!rstn) begin
            q_burst_size_wr   <= 0;
            q_burst_size_wr_1 <= 0;
        end
        else if(q_burst_cnt_wr + FIXED_BURST_SIZE > num_trans_d) begin
            // 마지막 burst: 잔여 워드 수 = num_trans_d의 하위 LOG_BURST_SIZE 비트
            q_burst_size_wr   <= num_trans_d[LOG_BURST_SIZE-1:0] - 1;  // AWLEN = beat-1
            q_burst_size_wr_1 <= num_trans_d[LOG_BURST_SIZE-1:0];       // 카운터 증분값
        end
        else begin
            // 중간 burst: 최대 FIXED_BURST_SIZE 워드
            q_burst_size_wr   <= FIXED_BURST_SIZE - 1;
            q_burst_size_wr_1 <= FIXED_BURST_SIZE;
        end
    end

//──────────────────────────────────────────────────────────────────────
// 현재 burst 시작 주소 업데이트
//   - start_dma: 새 DMA 시작 → start_addr 래치
//   - WR_WAIT→WR_PRE (BRESP=OKAY): 이번 burst 크기(바이트)만큼 주소 증가
//     증가량 = q_burst_size_wr_1 × 4Byte = {q_burst_size_wr_1, 2'b00}
//──────────────────────────────────────────────────────────────────────
    always @(posedge clk or negedge rstn) begin
        if(!rstn)
            q_ext_addr_wr <= 0;
        else if(start_dma)
            q_ext_addr_wr <= start_addr;
        else if((st_wr2axi == WR_WAIT) && (next_st_wr2axi == WR_PRE) && (ext_bresp == RESP_OKAY))
            q_ext_addr_wr <= q_ext_addr_wr + {q_burst_size_wr_1, {2'b00}}; // +N×4 Byte
    end

//──────────────────────────────────────────────────────────────────────
// FSM 상태 레지스터
//──────────────────────────────────────────────────────────────────────
    always @(posedge clk or negedge rstn)
        if(!rstn) st_wr2axi <= WR_IDLE;
        else      st_wr2axi <= next_st_wr2axi;

//──────────────────────────────────────────────────────────────────────
// FSM 조합 로직 (next state + AXI 출력 제어)
//──────────────────────────────────────────────────────────────────────
    always @* begin
        next_st_wr2axi = st_wr2axi;
        d_beat_cnt_wr  = q_beat_cnt_wr;
        d_burst_cnt_wr = q_burst_cnt_wr;

        // 기본값: 모든 AXI 출력 비활성
        indata_req_o = 1'b0;
        ext_awvalid  = 1'b0;
        ext_awaddr   = 0;
        ext_awlen    = 0;
        ext_awsize   = 0;
        ext_wvalid   = 1'b0;
        ext_wdata    = 0;
        ext_wstrb    = 0;
        ext_wlast    = 1'b0;
        ext_bready   = 1'b0;
        done_o       = 1'b0;
        fail_check   = 1'b0;

        case(st_wr2axi)
            default: next_st_wr2axi = WR_IDLE;

            WR_IDLE: begin
                // start_dma 가 들어오면 즉시 WR_PRE로 전이
                if(start_dma) next_st_wr2axi = WR_PRE;
            end

            WR_PRE: begin
                if(q_burst_cnt_wr == num_trans_d) begin
                    // 누적 완료 워드 = 요청 총량 → 전체 DMA 완료
                    d_burst_cnt_wr = 0;       // 카운터 리셋 (다음 DMA 준비)
                    next_st_wr2axi = WR_IDLE;
                    done_o = 1'b1;            // 완료 펄스 출력
                end
                else next_st_wr2axi = WR_START;  // 다음 burst 시작
            end

            WR_START: begin
                // AXI AW 채널: 쓰기 주소/길이 전송
                ext_awvalid = 1'b1;           // 주소 유효 어서트
                ext_awaddr  = q_ext_addr_wr;  // burst 시작 주소
                ext_awlen   = q_burst_size_wr; // beat 수 - 1 (= AWLEN)
                ext_awsize  = SIZE_4B;         // 4Byte/beat (32-bit 버스 폭)
                if(ext_awready) begin
                    // 슬레이브가 주소를 수락하면 데이터 전송 시작
                    indata_req_o   = 1'b1;    // 첫 데이터 요청
                    next_st_wr2axi = WR_SEQ;
                end
            end

            WR_SEQ: begin
                // W 채널: 슬레이브가 준비될 때마다 한 beat씩 전송
                if(ext_wready) begin
                    ext_wvalid = 1'b1;                       // 데이터 유효
                    ext_wdata  = indata;                     // 데이터 입력 연결
                    ext_wstrb  = {AXI_WIDTH_DS{1'b1}};      // 전체 4바이트 유효

                    if(q_burst_size_wr == q_beat_cnt_wr) begin
                        // 마지막 beat: WLAST=1, beat 카운터 리셋, WR_WAIT 전이
                        d_beat_cnt_wr  = 'h0;
                        ext_wlast      = 1'b1;
                        next_st_wr2axi = WR_WAIT;
                    end
                    else begin
                        // 중간 beat: 다음 데이터 요청 후 beat 카운터 증가
                        indata_req_o  = 1'b1;
                        d_beat_cnt_wr = q_beat_cnt_wr + 1'b1;
                    end
                end
            end

            WR_WAIT: begin
                // B 채널: 슬레이브의 응답(BRESP) 대기
                ext_bready = 1'b1;  // 응답 수락 준비
                if(ext_bvalid) begin
                    if(ext_bresp == RESP_OKAY) begin
                        // 정상 완료: burst 카운터 갱신 후 다음 burst 준비
                        d_burst_cnt_wr = q_burst_cnt_wr + q_burst_size_wr_1;
                        d_beat_cnt_wr  = 0;
                        next_st_wr2axi = WR_PRE;
                    end
                    else begin
                        // 응답 에러: beat 카운터만 리셋 후 WR_PRE 재진입
                        // (다음 사이클에 WR_START로 가서 해당 burst 재시도)
                        d_beat_cnt_wr  = 0;
                        next_st_wr2axi = WR_PRE;
                        fail_check     = 1'b1;  // 디버그 플래그
                    end
                end
            end
        endcase
    end

endmodule
