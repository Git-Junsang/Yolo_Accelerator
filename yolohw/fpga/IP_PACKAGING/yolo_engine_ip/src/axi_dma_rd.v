//================================================================
// axi_dma_rd.v — AXI4 마스터 읽기 DMA 모듈
//
// 역할:
//   DRAM(DDR2/DDR3)에서 가중치(Weight)·Bias 또는 입력 특징맵(IFM)을
//   AXI4 버스를 통해 읽어 내부 BRAM/로직에 공급한다.
//   yolo_engine.v 의 DMA read 경로에 인스턴스화되어 사용된다.
//
// 동작 개요:
//   start_dma=1 을 한 클록 동안 어서트하면 읽기 DMA 동작 시작.
//   num_trans 개의 32-bit 워드를 start_addr 부터 순서대로 읽어
//   data_o / data_vld_o 로 출력한다.
//   읽기는 FIXED_BURST_SIZE(=256) 워드 단위의 AXI4 INCR burst 로 분할.
//   마지막 burst 완료 시 done_o=1 을 한 클록 어서트.
//
// AXI4 버스 채널:
//   AR 채널 (Read Address): M_ARVALID/M_ARREADY 핸드셰이크로 burst 주소 전송
//   R  채널 (Read Data):    M_RVALID/M_RREADY 핸드셰이크로 데이터 수신
//                           M_RLAST = burst의 마지막 beat 표시
//                           M_RRESP = 응답 코드 (2'b00=OKAY)
//
// 5-상태 FSM (st_rdaxi):
//   RD_IDLE  : start_dma_d 를 기다리는 초기 상태
//              start_dma_d=1 → RD_PRE 로 전이
//
//   RD_PRE   : burst 시작 전 준비 단계
//              남은 워드 수 확인 (q_burst_cnt_rd == num_trans_d 이면 완료 → RD_IDLE)
//              아직 읽을 데이터 있으면 → RD_START
//
//   RD_START : AXI AR 채널에 주소/길이 정보 전송 (ext_arvalid=1)
//              M_ARREADY=1 이 되면 핸드셰이크 완료 → RD_SEQ
//              매 burst 의 시작 주소 (q_ext_addr_rd), 길이 (q_burst_size_rd) 설정
//              ARSIZE=3'b010 (4Byte, 32-bit 버스 폭 일치)
//              ARBURST=2'b01 (INCR burst, 주소 자동 증가)
//
//   RD_SEQ   : R 채널에서 데이터 수신 대기 (ext_rready=1 항시 고정)
//              ext_rlast_r=1 (burst 마지막 beat 후 1 사이클) 이면:
//                - RRESP=OKAY(2'b00) → RD_WAIT
//                - RRESP 에러         → RD_START (해당 burst 재시도)
//
//   RD_WAIT  : burst 완료 후 burst 카운터 갱신 (q_burst_cnt_rd += q_burst_size_rd_1)
//              무조건 RD_PRE 로 복귀 (다음 burst 준비 또는 완료 확인)
//
// 버스트 분할 로직:
//   - q_burst_cnt_rd: 지금까지 완료된 누적 워드 수
//   - FIXED_BURST_SIZE=256: 한 번 burst 에서 최대 256 워드(1KB) 전송
//   - 마지막 burst에서 잔여 워드 수 < 256 이면 q_burst_size_rd 를 조정
//   - last_trans=1: 현재 burst 가 마지막 burst 임을 나타냄
//
// 출력:
//   data_o     : 수신 데이터 (1 사이클 지연, ext_rdata 레지스터)
//   data_vld_o : data_o 유효 여부 (ext_rvalid 레지스터)
//   data_cnt_o : 현재 burst 내 수신 워드 카운터
//   done_o     : 전체 DMA 완료 (last_trans & ext_rlast & RRESP=OKAY)
//
// 파라미터:
//   BITS_TRANS    = 18 : num_trans / data_cnt 의 비트 폭 (최대 262144 워드 = 1MB)
//   AXI_WIDTH_AD  = 32 : 주소 버스 폭
//   AXI_WIDTH_DA  = 32 : 데이터 버스 폭 (32-bit 고정)
//================================================================
module axi_dma_rd(
    //AXI Master Interface
    //Read address channel
    M_ARVALID,    // AR 채널: 주소/제어 유효 (마스터→슬레이브)
    M_ARREADY,    // AR 채널: 주소 수락 준비 (슬레이브→마스터)
    M_ARADDR,     // AR 채널: 읽기 시작 주소
    M_ARID,       // AR 채널: 트랜잭션 ID (고정 0)
    M_ARLEN,      // AR 채널: burst beat 수 - 1 (0~255)
    M_ARSIZE,     // AR 채널: beat 당 바이트 크기 (3'b010 = 4B)
    M_ARBURST,    // AR 채널: burst 타입 (2'b01 = INCR)
    M_ARLOCK,     // AR 채널: 원자적 접근 (미사용, 0 고정)
    M_ARCACHE,    // AR 채널: 캐시 속성 (미사용, 0 고정)
    M_ARPROT,     // AR 채널: 보호 레벨 (미사용, 0 고정)
    M_ARQOS,      // AR 채널: QoS (최고 우선순위 4'b1111)
    M_ARREGION,   // AR 채널: 리전 (미사용, 0 고정)
    M_ARUSER,     // AR 채널: 사용자 정의 (미사용, 0 고정)

    //Read data channel
    M_RVALID,     // R 채널: 읽기 데이터 유효 (슬레이브→마스터)
    M_RREADY,     // R 채널: 데이터 수신 준비 (마스터→슬레이브, 항시 1)
    M_RDATA,      // R 채널: 읽기 데이터 (32-bit)
    M_RLAST,      // R 채널: burst 마지막 beat 표시
    M_RID,        // R 채널: 트랜잭션 ID (사용 안 함)
    M_RUSER,      // R 채널: 사용자 정의 (사용 안 함)
    M_RRESP,      // R 채널: 응답 코드 (2'b00=OKAY)

    //Functional Ports (yolo_engine.v 와의 인터페이스)
    start_dma,    // 1 클록 펄스: DMA 시작 트리거
    num_trans,    // 읽을 총 32-bit 워드 수
    start_addr,   // DRAM 읽기 시작 주소 (바이트 단위)
    data_o,       // 출력 데이터 (1 사이클 지연)
    data_vld_o,   // data_o 유효 플래그
    data_cnt_o,   // 누적 수신 워드 카운터
    done_o,       // 전체 DMA 완료 플래그 (1 클록 펄스)

    //Global signals
    clk, rstn
);
    // ──────────────────────────────────────────────────────────────
    // 파라미터
    // ──────────────────────────────────────────────────────────────
    parameter BITS_TRANS     = 18;  // num_trans 비트 폭 (최대 262144 = 1M words)
    parameter OUT_BITS_TRANS = 13;  // (미사용, 호환성 유지)

    parameter AXI_WIDTH_USER = 1;               // Master User 신호 폭
    parameter AXI_WIDTH_ID   = 4;               // ID 비트 폭
    parameter AXI_WIDTH_AD   = 32;              // 주소 버스 폭
    parameter AXI_WIDTH_DA   = 32;              // 데이터 버스 폭
    parameter AXI_WIDTH_DS   = (AXI_WIDTH_DA/8);// 스트로브 폭 (= 4)

    // 한 AXI burst에서 전송하는 최대 워드 수 (AXI4 최대 = 256 beats)
    localparam FIXED_BURST_SIZE = 256;
    localparam LOG_BURST_SIZE   = $clog2(FIXED_BURST_SIZE);  // = 8

//──────────────────────────────────────────────────────────────────────
// 포트 선언
//──────────────────────────────────────────────────────────────────────
    // AXI Read Address 채널 (마스터 출력)
    output                      M_ARVALID;
    input                       M_ARREADY;
    output  [AXI_WIDTH_AD-1:0]  M_ARADDR;
    output  [AXI_WIDTH_ID-1:0]  M_ARID;
    output  [7:0]               M_ARLEN;    // = burst beat 수 - 1
    output  [2:0]               M_ARSIZE;   // 3'b010 = 4Byte/beat
    output  [1:0]               M_ARBURST;  // 2'b01 = INCR
    output  [1:0]               M_ARLOCK;
    output  [3:0]               M_ARCACHE;
    output  [2:0]               M_ARPROT;
    output  [3:0]               M_ARQOS;
    output  [3:0]               M_ARREGION;
    output  [3:0]               M_ARUSER;

    // AXI Read Data 채널 (마스터 입력)
    input                       M_RVALID;
    output                      M_RREADY;   // 항시 1 (back-pressure 없음)
    input   [AXI_WIDTH_DA-1:0]  M_RDATA;
    input                       M_RLAST;
    input   [AXI_WIDTH_ID-1:0]  M_RID;
    input  [3:0]                M_RUSER;
    input   [1:0]               M_RRESP;    // 2'b00 = OKAY

    // 기능 포트
    input                           start_dma;
    input [BITS_TRANS-1:0]          num_trans;
    input [AXI_WIDTH_AD-1:0]        start_addr;
    output reg [AXI_WIDTH_DA-1:0]   data_o;
    output reg                      data_vld_o;
    output reg [BITS_TRANS-1:0]     data_cnt_o;
    output reg                      done_o;

    // 글로벌 신호
    input               clk;
    input               rstn;

//──────────────────────────────────────────────────────────────────────
// AXI 고정 출력 (사용하지 않는 사이드밴드 신호를 0으로 고정)
//──────────────────────────────────────────────────────────────────────
    assign M_ARID     = 3'd0;    // 트랜잭션 ID (단일 outstanding)
    assign M_ARLOCK   = 2'd0;    // 비원자적 접근
    assign M_ARCACHE  = 4'd0;    // 캐시 불가 / 버퍼 불가
    assign M_ARPROT   = 3'd0;    // 비보안, 데이터 접근
    assign M_ARQOS    = 4'b1111; // 최고 QoS 우선순위
    assign M_ARREGION = 4'd0;
    assign M_ARUSER   = 4'd0;

//──────────────────────────────────────────────────────────────────────
// 내부 신호 선언 (ext_* : AXI 포트와 FSM 사이 중간 레지스터/와이어)
//──────────────────────────────────────────────────────────────────────
    reg     [AXI_WIDTH_AD-1:0]  ext_araddr ;  // AR 채널 주소
    reg     [AXI_WIDTH_AD-1:0]  ext_arlen  ;  // AR 채널 burst 길이 (beat-1)
    reg     [2:0]               ext_arsize ;  // AR 채널 beat 크기
    reg     [1:0]               ext_arburst;  // AR 채널 burst 타입
    reg                         ext_arvalid;  // AR 채널 유효
    wire                        ext_arready;  // AR 채널 슬레이브 준비
    wire    [AXI_WIDTH_DA-1:0]  ext_rdata  ;  // R 채널 데이터
    wire    [1:0]               ext_rresp  ;  // R 채널 응답
    wire                        ext_rlast  ;  // R 채널 마지막 beat
    wire                        ext_rvalid ;  // R 채널 유효
    wire                        ext_rready ;  // R 채널 준비 (항시 1)

    // AXI 포트 ↔ ext_* 연결
    assign  M_ARVALID  = ext_arvalid;
    assign  M_ARADDR   = ext_araddr;
    assign  M_ARLEN    = ext_arlen;
    assign  M_ARSIZE   = ext_arsize;
    assign  M_ARBURST  = ext_arburst;
    assign  ext_arready = M_ARREADY;

    assign  ext_rdata  = M_RDATA;
    assign  ext_rresp  = M_RRESP;
    assign  ext_rlast  = M_RLAST;
    assign  ext_rvalid = M_RVALID;
    assign  M_RREADY   = ext_rready;

    // ext_rready = 1: 데이터가 도착하면 즉시 수락 (back-pressure 없음)
    assign ext_rready = 1'b1;

    // rlast 래치: M_RLAST는 beat 단위 신호이므로 1 사이클 지연해서 사용
    // (FSM이 RD_SEQ→RD_WAIT 전이를 한 클록 후에 처리하기 위함)
    reg ext_rlast_r;
    always @(posedge clk or negedge rstn)
        if(!rstn) ext_rlast_r <= 'h0;
        else      ext_rlast_r <= ext_rlast & ext_rvalid & ext_rready;

    // rresp 래치: rlast와 동기를 맞추기 위해 1사이클 지연
    reg [1:0] ext_rresp_r;
    always @(posedge clk or negedge rstn)
        if(!rstn) ext_rresp_r <= 'h0;
        else      ext_rresp_r <= ext_rresp;

//──────────────────────────────────────────────────────────────────────
// 내부 제어 레지스터
//──────────────────────────────────────────────────────────────────────
    reg                         last_trans;         // 현재 burst가 마지막 burst 여부
    reg [7:0]                   q_burst_size_rd;    // 현재 burst beat 수 - 1 (ARLEN 값)
    reg [8:0]                   q_burst_size_rd_1;  // 현재 burst beat 수 (카운터 증분용)
    reg [AXI_WIDTH_AD-1:0]      q_ext_addr_rd;      // 현재 burst 시작 주소

    reg [2:0] st_rdaxi, next_st_rdaxi;  // FSM 현재/다음 상태
    reg [BITS_TRANS-1:0] num_trans_d;   // start_dma 시점에 래치한 num_trans
    reg [BITS_TRANS-1:0] data_cnt;      // 현재 burst 내 수신 워드 인덱스
    reg [BITS_TRANS-1:0] d_burst_cnt_rd, q_burst_cnt_rd;  // 누적 완료 워드 수

    // start_dma 1 사이클 지연: FSM이 start_dma 다음 사이클에 상태 전이
    reg start_dma_d;
    always @(posedge clk or negedge rstn)
        if(!rstn) start_dma_d <= 'b0;
        else      start_dma_d <= start_dma;

    // num_trans 래치: start_dma가 어서트된 사이클에 num_trans 캡처
    always @(posedge clk or negedge rstn)
        if(!rstn)          num_trans_d <= 'h0;
        else if(start_dma) num_trans_d <= num_trans;

//──────────────────────────────────────────────────────────────────────
// burst 카운터 업데이트 (순차 로직)
//──────────────────────────────────────────────────────────────────────
    always @(posedge clk or negedge rstn)
        if(!rstn) q_burst_cnt_rd <= 0;
        else      q_burst_cnt_rd <= d_burst_cnt_rd;

//──────────────────────────────────────────────────────────────────────
// burst 크기 / last_trans 계산
//   - q_burst_cnt_rd + FIXED_BURST_SIZE > num_trans_d: 마지막 burst (잔여 < 256)
//   - q_burst_cnt_rd + FIXED_BURST_SIZE = num_trans_d: 정확히 마지막 burst
//   - 그 외: 중간 burst (FIXED_BURST_SIZE 워드 전송)
//──────────────────────────────────────────────────────────────────────
    always @(posedge clk or negedge rstn) begin
        if(!rstn) begin
            q_burst_size_rd   <= 0;
            q_burst_size_rd_1 <= 0;
            last_trans        <= 1'b0;
        end
        else if(q_burst_cnt_rd + FIXED_BURST_SIZE > num_trans_d) begin
            // 마지막 burst: 잔여 워드 수 = num_trans_d의 하위 LOG_BURST_SIZE 비트
            q_burst_size_rd   <= num_trans_d[LOG_BURST_SIZE-1:0] - 1;  // ARLEN = beat-1
            q_burst_size_rd_1 <= num_trans_d[LOG_BURST_SIZE-1:0];       // 카운터 증분값
            if(st_rdaxi == RD_SEQ) last_trans <= 1'b1;
            else                   last_trans <= 1'b0;
        end
        else if(q_burst_cnt_rd + FIXED_BURST_SIZE == num_trans_d) begin
            // 마지막 burst: 정확히 256 워드 남은 경우
            q_burst_size_rd   <= FIXED_BURST_SIZE - 1;
            q_burst_size_rd_1 <= FIXED_BURST_SIZE;
            if(st_rdaxi == RD_SEQ) last_trans <= 1'b1;
            else                   last_trans <= 1'b0;
        end
        else begin
            // 중간 burst: FIXED_BURST_SIZE 워드 전송
            q_burst_size_rd   <= FIXED_BURST_SIZE - 1;
            q_burst_size_rd_1 <= FIXED_BURST_SIZE;
            last_trans        <= 1'b0;
        end
    end

//──────────────────────────────────────────────────────────────────────
// 현재 burst 시작 주소 업데이트
//   - start_dma: 새 DMA 시작 → start_addr 래치
//   - RD_WAIT→RD_PRE 전이 시: 이전 burst 크기(바이트)만큼 주소 증가
//     증가량 = FIXED_BURST_SIZE × 4Byte = {FIXED_BURST_SIZE, 2'b00}
//──────────────────────────────────────────────────────────────────────
    always @(posedge clk or negedge rstn) begin
        if(!rstn)
            q_ext_addr_rd <= 0;
        else if(start_dma)
            q_ext_addr_rd <= start_addr;
        else if((st_rdaxi == RD_WAIT) && (next_st_rdaxi == RD_PRE))
            q_ext_addr_rd <= q_ext_addr_rd + {FIXED_BURST_SIZE, {2'b00}}; // +1024 Byte
    end

//──────────────────────────────────────────────────────────────────────
// FSM 상태 레지스터
//──────────────────────────────────────────────────────────────────────
    localparam RD_IDLE  = 0,  // 초기 대기
               RD_PRE   = 1,  // burst 시작 준비 / 완료 판단
               RD_START = 2,  // AR 채널 핸드셰이크
               RD_SEQ   = 3,  // R 채널 데이터 수신 대기
               RD_WAIT  = 4;  // burst 완료 후 카운터 갱신

    always @(posedge clk or negedge rstn)
        if(!rstn) st_rdaxi <= RD_IDLE;
        else      st_rdaxi <= next_st_rdaxi;

//──────────────────────────────────────────────────────────────────────
// FSM 조합 로직 (next state + AXI 출력 제어)
//──────────────────────────────────────────────────────────────────────
    always @(*) begin
        next_st_rdaxi = st_rdaxi;
        d_burst_cnt_rd = q_burst_cnt_rd;

        // AXI AR 채널 기본값 (비활성)
        ext_araddr  = 0;
        ext_arlen   = 0;
        ext_arsize  = 0;
        ext_arburst = 0;
        ext_arvalid = 1'b0;

        case(st_rdaxi)
            default: next_st_rdaxi = RD_IDLE;

            RD_IDLE: begin
                // start_dma의 1 사이클 지연 버전(start_dma_d)을 검출하여 시작
                if(start_dma_d) next_st_rdaxi = RD_PRE;
            end

            RD_PRE: begin
                if(q_burst_cnt_rd == num_trans_d) begin
                    // 누적 완료 워드 = 요청 총량 → 전체 DMA 완료
                    d_burst_cnt_rd = 0;           // 카운터 리셋 (다음 DMA를 위해)
                    next_st_rdaxi  = RD_IDLE;
                end
                else next_st_rdaxi = RD_START;   // 다음 burst 시작
            end

            RD_START: begin
                // AXI AR 채널: 주소/길이 정보 전송
                if(ext_arready) begin
                    ext_arvalid = 1'b1;
                    ext_araddr  = q_ext_addr_rd;  // burst 시작 주소
                    ext_arlen   = q_burst_size_rd; // beat 수 - 1 (= ARLEN)
                    ext_arsize  = 3'b010;          // 4Byte / beat
                    ext_arburst = 2'b01;           // INCR burst (주소 자동 증가)
                    next_st_rdaxi = RD_SEQ;
                end
            end

            RD_SEQ: begin
                // ext_rlast_r: burst 마지막 beat 수신 후 1사이클 지연
                if(ext_rlast_r) begin
                    if(ext_rresp_r == 2'b00)     // RESP_OKAY
                        next_st_rdaxi = RD_WAIT;
                    else                          // 응답 에러 → 해당 burst 재시도
                        next_st_rdaxi = RD_START;
                end
            end

            RD_WAIT: begin
                // burst 완료: 카운터에 이번 burst 워드 수를 더한 후 RD_PRE로 복귀
                d_burst_cnt_rd = q_burst_cnt_rd + q_burst_size_rd_1;
                next_st_rdaxi  = RD_PRE;
            end
        endcase
    end

//──────────────────────────────────────────────────────────────────────
// 출력 레지스터 (1 사이클 지연으로 안정화)
//──────────────────────────────────────────────────────────────────────
    always @(posedge clk or negedge rstn) begin
        if(!rstn) begin
            data_cnt_o <= 'h0;
            data_o     <= 'h0;
            data_vld_o <= 'h0;
        end
        else begin
            data_cnt_o <= data_cnt;    // 현재 burst 내 수신 워드 인덱스
            data_o     <= ext_rdata;   // 수신 데이터 (1 사이클 지연)
            data_vld_o <= ext_rvalid;  // 데이터 유효 (1 사이클 지연)
        end
    end

    // done_o: 마지막 burst의 마지막 beat에서 OKAY 응답 수신 시 1 사이클 펄스
    always @(posedge clk or negedge rstn) begin
        if(!rstn)
            done_o <= 'h0;
        else
            done_o <= last_trans && ext_rlast && (ext_rresp == 2'b00);
    end

//──────────────────────────────────────────────────────────────────────
// data_cnt: burst 내 수신 워드 인덱스
//   - RD_START 진입 시: 현재 burst 기준 주소(q_burst_cnt_rd)로 리셋
//   - ext_rvalid=1 일 때마다 1씩 증가
//──────────────────────────────────────────────────────────────────────
    always @(posedge clk or negedge rstn) begin
        if(!rstn)
            data_cnt <= 'h0;
        else begin
            if(st_rdaxi == RD_START)  data_cnt <= q_burst_cnt_rd;
            else if(ext_rvalid)       data_cnt <= data_cnt + 'h1;
        end
    end

endmodule
