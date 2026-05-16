`timescale 1 ns / 1 ps
//================================================================
// yolo_engine_axi.v — AXI4-Lite 슬레이브 인터페이스 모듈
//
// 역할:
//   MicroBlaze(또는 외부 마스터)가 AXI4-Lite 버스를 통해
//   yolo_engine의 제어 레지스터를 읽고 쓸 수 있게 한다.
//   Vivado AXI4-Lite 슬레이브 IP 템플릿 기반으로 작성됨.
//
// 레지스터 맵 (AXI4-Lite 주소 offset, 32-bit):
//   offset 0x0 → slv_reg0 = ctrl_reg0
//     [0]    : ap_start  — 1을 쓰면 yolo_engine 추론 시작
//     [1]    : (예약)
//     [31:2] : 읽기 시 network_done 비트(bit1)가 반영됨
//              → MicroBlaze는 bit1을 polling하여 추론 완료 감지
//   offset 0x4 → slv_reg1 = ctrl_reg1 = dram_wgt_base
//     가중치(Weight)+Bias 가 저장된 DRAM 시작 주소 (바이트)
//   offset 0x8 → slv_reg2 = ctrl_reg2 = dram_ifm_base
//     입력 특징맵(IFM, Layer 0 이미지) DRAM 주소 (바이트)
//   offset 0xC → slv_reg3 = ctrl_reg3 = dram_ofm_base
//     출력 특징맵(OFM) 저장 DRAM 주소 (바이트, 레이어 offset 적용)
//
// 읽기 시 slv_reg0 특수 처리:
//   reg_data_out = {slv_reg0[31:2], network_done, slv_reg0[0]}
//   → bit[1]에 network_done 신호를 삽입하여 소프트웨어가 완료를 polling 가능
//
// AXI4-Lite 쓰기 동작:
//   1. AWVALID & WVALID & aw_en 이 모두 어서트되면 axi_awready & axi_wready 생성
//   2. slv_reg_wren = awready & wready & awvalid & wvalid
//   3. axi_awaddr[ADDR_LSB+OPT_MEM_ADDR_BITS : ADDR_LSB] 로 레지스터 선택
//      (ADDR_LSB=2이므로 주소[3:2]가 레지스터 인덱스)
//   4. 바이트 스트로브(WSTRB) 단위로 slv_reg 바이트 업데이트
//   5. BVALID & BREADY 핸드셰이크로 쓰기 응답 전송
//
// AXI4-Lite 읽기 동작:
//   1. ARVALID 어서트 → axi_arready 1 사이클 후 axi_araddr 래치
//   2. slv_reg_rden = arready & arvalid & ~rvalid
//   3. reg_data_out 조합 로직에서 레지스터 주소 디코딩
//   4. RVALID & RREADY 핸드셰이크로 데이터 전송
//
// 파라미터:
//   C_S_AXI_DATA_WIDTH = 32 : 데이터 버스 폭
//   C_S_AXI_ADDR_WIDTH = 4  : 주소 버스 폭 (4비트 → 최대 0~0xF, 레지스터 4개)
//
// 포트 (추가된 사용자 포트):
//   ctrl_reg0~3    : slv_reg0~3 의 직접 출력 → yolo_engine.v에서 제어에 사용
//   network_done   : 추론 완료 신호 (yolo_engine.v에서 입력, slv_reg0 읽기에 삽입)
//   network_done_led: LED 표시용 (현재 미사용, 포트만 선언)
//================================================================

module yolo_engine_axi #
(
    // Users to add parameters here

    // User parameters ends
    // Do not modify the parameters beyond this line

    // S_AXI 데이터 버스 폭 (32-bit 고정)
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    // S_AXI 주소 버스 폭 (4-bit: 최대 0~0xF → 레지스터 4개)
    parameter integer C_S_AXI_ADDR_WIDTH = 4
)
(
    // Users to add ports here
    output wire [31:0] ctrl_reg0,      // slv_reg0: ap_start 등 제어 비트
    output wire [31:0] ctrl_reg1,      // slv_reg1: dram_wgt_base (가중치 DRAM 주소)
    output wire [31:0] ctrl_reg2,      // slv_reg2: dram_ifm_base (IFM DRAM 주소)
    output wire [31:0] ctrl_reg3,      // slv_reg3: dram_ofm_base (OFM DRAM 주소)
    input  wire network_done,          // 추론 완료 신호 → ctrl_reg0 읽기 bit[1]에 삽입
    input  wire network_done_led,      // LED 표시용 (현재 미사용)
    // User ports ends
    // Do not modify the ports beyond this line

    // AXI4-Lite 슬레이브 인터페이스
    input wire  S_AXI_ACLK,       // 버스 클록
    input wire  S_AXI_ARESETN,    // 버스 리셋 (Active Low)

    // Write address channel
    input wire [C_S_AXI_ADDR_WIDTH-1 : 0] S_AXI_AWADDR,   // 쓰기 주소
    input wire [2 : 0] S_AXI_AWPROT,                       // 보호 레벨 (미사용)
    input wire  S_AXI_AWVALID,                              // 주소 유효
    output wire  S_AXI_AWREADY,                             // 주소 수락 준비

    // Write data channel
    input wire [C_S_AXI_DATA_WIDTH-1 : 0] S_AXI_WDATA,    // 쓰기 데이터
    input wire [(C_S_AXI_DATA_WIDTH/8)-1 : 0] S_AXI_WSTRB,// 바이트 스트로브
    input wire  S_AXI_WVALID,                               // 데이터 유효
    output wire  S_AXI_WREADY,                              // 데이터 수락 준비

    // Write response channel
    output wire [1 : 0] S_AXI_BRESP,   // 쓰기 응답 (2'b00 = OKAY)
    output wire  S_AXI_BVALID,         // 응답 유효
    input wire  S_AXI_BREADY,          // 응답 수락 (마스터 준비)

    // Read address channel
    input wire [C_S_AXI_ADDR_WIDTH-1 : 0] S_AXI_ARADDR,   // 읽기 주소
    input wire [2 : 0] S_AXI_ARPROT,                       // 보호 레벨 (미사용)
    input wire  S_AXI_ARVALID,                              // 주소 유효
    output wire  S_AXI_ARREADY,                             // 주소 수락 준비

    // Read data channel
    output wire [C_S_AXI_DATA_WIDTH-1 : 0] S_AXI_RDATA,   // 읽기 데이터
    output wire [1 : 0] S_AXI_RRESP,                       // 읽기 응답 (2'b00 = OKAY)
    output wire  S_AXI_RVALID,                              // 데이터 유효
    input wire  S_AXI_RREADY                                // 데이터 수락 (마스터 준비)
);

// ──────────────────────────────────────────────────────────────────────
// AXI4-Lite 내부 레지스터 선언
// ──────────────────────────────────────────────────────────────────────
    reg [C_S_AXI_ADDR_WIDTH-1 : 0] axi_awaddr;  // 쓰기 주소 래치
    reg  axi_awready;  // AWREADY 레지스터
    reg  axi_wready;   // WREADY 레지스터
    reg [1 : 0] axi_bresp;   // BRESP 레지스터 (항상 2'b00)
    reg  axi_bvalid;   // BVALID 레지스터
    reg [C_S_AXI_ADDR_WIDTH-1 : 0] axi_araddr;  // 읽기 주소 래치
    reg  axi_arready;  // ARREADY 레지스터
    reg [C_S_AXI_DATA_WIDTH-1 : 0] axi_rdata;   // 읽기 데이터 레지스터
    reg [1 : 0] axi_rresp;   // RRESP 레지스터 (항상 2'b00)
    reg  axi_rvalid;   // RVALID 레지스터

    // ADDR_LSB: 32-bit 버스이므로 하위 2비트(바이트 offset) 제거 후 워드 인덱스 추출
    //   예) addr=0x4 → addr[3:2]=2'b01 → slv_reg1
    localparam integer ADDR_LSB = (C_S_AXI_DATA_WIDTH/32) + 1;  // = 2
    localparam integer OPT_MEM_ADDR_BITS = 1;  // 레지스터 인덱스 비트 수 (2개 비트 → 4개 레지스터)

    // 슬레이브 레지스터 4개 (각 32-bit)
    reg [C_S_AXI_DATA_WIDTH-1:0] slv_reg0;  // ctrl_reg0: ap_start[0] 등
    reg [C_S_AXI_DATA_WIDTH-1:0] slv_reg1;  // ctrl_reg1: dram_wgt_base
    reg [C_S_AXI_DATA_WIDTH-1:0] slv_reg2;  // ctrl_reg2: dram_ifm_base
    reg [C_S_AXI_DATA_WIDTH-1:0] slv_reg3;  // ctrl_reg3: dram_ofm_base

    wire slv_reg_rden;  // 읽기 enable (조합 로직)
    wire slv_reg_wren;  // 쓰기 enable (조합 로직)
    reg [C_S_AXI_DATA_WIDTH-1:0] reg_data_out;  // 읽기 데이터 선택 결과
    integer byte_index;  // 바이트 스트로브 루프 변수
    reg aw_en;  // AW 채널 enable (한 번에 하나의 outstanding write만 허용)

// ──────────────────────────────────────────────────────────────────────
// AXI 포트 연결
// ──────────────────────────────────────────────────────────────────────
    assign S_AXI_AWREADY = axi_awready;
    assign S_AXI_WREADY  = axi_wready;
    assign S_AXI_BRESP   = axi_bresp;
    assign S_AXI_BVALID  = axi_bvalid;
    assign S_AXI_ARREADY = axi_arready;
    assign S_AXI_RDATA   = axi_rdata;
    assign S_AXI_RRESP   = axi_rresp;
    assign S_AXI_RVALID  = axi_rvalid;

// ──────────────────────────────────────────────────────────────────────
// axi_awready 생성 로직
//   AWVALID & WVALID & aw_en 세 조건이 모두 1일 때 1 사이클 동안 어서트.
//   aw_en: 이전 쓰기가 완료(BREADY & BVALID)될 때까지 새 쓰기 차단.
//          → outstanding write transaction이 2개 이상 발생하지 않도록 보장.
// ──────────────────────────────────────────────────────────────────────
    always @(posedge S_AXI_ACLK) begin
        if(S_AXI_ARESETN == 1'b0) begin
            axi_awready <= 1'b0;
            aw_en <= 1'b1;  // 리셋 후 새 쓰기 허용
        end
        else begin
            if(~axi_awready && S_AXI_AWVALID && S_AXI_WVALID && aw_en) begin
                // 주소 & 데이터 동시 유효: awready 한 사이클 어서트, aw_en 잠금
                axi_awready <= 1'b1;
                aw_en <= 1'b0;
            end
            else if(S_AXI_BREADY && axi_bvalid) begin
                // 마스터가 쓰기 응답을 수락하면 다음 쓰기 허용
                aw_en <= 1'b1;
                axi_awready <= 1'b0;
            end
            else begin
                axi_awready <= 1'b0;  // 그 외: 1 사이클만 어서트 후 해제
            end
        end
    end

// ──────────────────────────────────────────────────────────────────────
// axi_awaddr 래치
//   AWVALID & WVALID & aw_en 동시 충족 시 주소를 내부 레지스터에 저장.
//   slv_reg_wren에서 이 래치된 주소로 레지스터 선택.
// ──────────────────────────────────────────────────────────────────────
    always @(posedge S_AXI_ACLK) begin
        if(S_AXI_ARESETN == 1'b0)
            axi_awaddr <= 0;
        else begin
            if(~axi_awready && S_AXI_AWVALID && S_AXI_WVALID && aw_en)
                axi_awaddr <= S_AXI_AWADDR;  // 주소 캡처
        end
    end

// ──────────────────────────────────────────────────────────────────────
// axi_wready 생성 로직
//   AWVALID & WVALID & aw_en 세 조건이 모두 1일 때 1 사이클 동안 어서트.
//   axi_awready와 동일한 조건이지만 독립 레지스터로 관리.
// ──────────────────────────────────────────────────────────────────────
    always @(posedge S_AXI_ACLK) begin
        if(S_AXI_ARESETN == 1'b0)
            axi_wready <= 1'b0;
        else begin
            if(~axi_wready && S_AXI_WVALID && S_AXI_AWVALID && aw_en)
                axi_wready <= 1'b1;
            else
                axi_wready <= 1'b0;
        end
    end

// ──────────────────────────────────────────────────────────────────────
// 슬레이브 레지스터 쓰기 로직
//   slv_reg_wren: awready & wready & awvalid & wvalid 모두 어서트 시 1
//   axi_awaddr[ADDR_LSB+OPT_MEM_ADDR_BITS : ADDR_LSB] = 주소[3:2]
//     → 2'h0: slv_reg0 (ctrl_reg0)
//     → 2'h1: slv_reg1 (dram_wgt_base)
//     → 2'h2: slv_reg2 (dram_ifm_base)
//     → 2'h3: slv_reg3 (dram_ofm_base)
//   WSTRB: 바이트 단위로 적용 (1비트 = 1바이트 enable)
// ──────────────────────────────────────────────────────────────────────
    assign slv_reg_wren = axi_wready && S_AXI_WVALID && axi_awready && S_AXI_AWVALID;

    always @(posedge S_AXI_ACLK) begin
        if(S_AXI_ARESETN == 1'b0) begin
            slv_reg0 <= 0;
            slv_reg1 <= 0;
            slv_reg2 <= 0;
            slv_reg3 <= 0;
        end
        else begin
            if(slv_reg_wren) begin
                case(axi_awaddr[ADDR_LSB+OPT_MEM_ADDR_BITS : ADDR_LSB])
                    2'h0:  // ctrl_reg0: ap_start 등
                        for(byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1)
                            if(S_AXI_WSTRB[byte_index] == 1)
                                slv_reg0[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];

                    2'h1:  // ctrl_reg1: dram_wgt_base (가중치+Bias DRAM 주소)
                        for(byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1)
                            if(S_AXI_WSTRB[byte_index] == 1)
                                slv_reg1[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];

                    2'h2:  // ctrl_reg2: dram_ifm_base (Layer 0 IFM DRAM 주소)
                        for(byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1)
                            if(S_AXI_WSTRB[byte_index] == 1)
                                slv_reg2[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];

                    2'h3:  // ctrl_reg3: dram_ofm_base (OFM 저장 DRAM 주소)
                        for(byte_index = 0; byte_index <= (C_S_AXI_DATA_WIDTH/8)-1; byte_index = byte_index+1)
                            if(S_AXI_WSTRB[byte_index] == 1)
                                slv_reg3[(byte_index*8) +: 8] <= S_AXI_WDATA[(byte_index*8) +: 8];

                    default: begin
                        slv_reg0 <= slv_reg0;
                        slv_reg1 <= slv_reg1;
                        slv_reg2 <= slv_reg2;
                        slv_reg3 <= slv_reg3;
                    end
                endcase
            end
        end
    end

// ──────────────────────────────────────────────────────────────────────
// 쓰기 응답 로직 (B 채널)
//   awready & wready & awvalid & wvalid 이 모두 1이면 BVALID 어서트.
//   마스터가 BREADY를 어서트하면 BVALID 해제 (1 사이클 응답).
//   BRESP = 2'b00 (OKAY) 고정.
// ──────────────────────────────────────────────────────────────────────
    always @(posedge S_AXI_ACLK) begin
        if(S_AXI_ARESETN == 1'b0) begin
            axi_bvalid <= 0;
            axi_bresp  <= 2'b0;
        end
        else begin
            if(axi_awready && S_AXI_AWVALID && ~axi_bvalid && axi_wready && S_AXI_WVALID) begin
                axi_bvalid <= 1'b1;
                axi_bresp  <= 2'b0;  // OKAY 응답
            end
            else begin
                if(S_AXI_BREADY && axi_bvalid)
                    axi_bvalid <= 1'b0;  // 마스터가 응답 수락 → BVALID 해제
            end
        end
    end

// ──────────────────────────────────────────────────────────────────────
// 읽기 주소 준비 (AR 채널)
//   ARVALID 어서트 시 1 사이클 동안 ARREADY 어서트 + 주소 래치.
// ──────────────────────────────────────────────────────────────────────
    always @(posedge S_AXI_ACLK) begin
        if(S_AXI_ARESETN == 1'b0) begin
            axi_arready <= 1'b0;
            axi_araddr  <= 32'b0;
        end
        else begin
            if(~axi_arready && S_AXI_ARVALID) begin
                axi_arready <= 1'b1;
                axi_araddr  <= S_AXI_ARADDR;  // 읽기 주소 캡처
            end
            else begin
                axi_arready <= 1'b0;  // 1 사이클만 어서트
            end
        end
    end

// ──────────────────────────────────────────────────────────────────────
// 읽기 데이터 유효 (RVALID) 생성
//   arready & arvalid 핸드셰이크 성공 → 다음 사이클에 RVALID 어서트.
//   마스터가 RREADY를 어서트하면 RVALID 해제.
//   RRESP = 2'b00 (OKAY) 고정.
// ──────────────────────────────────────────────────────────────────────
    always @(posedge S_AXI_ACLK) begin
        if(S_AXI_ARESETN == 1'b0) begin
            axi_rvalid <= 0;
            axi_rresp  <= 0;
        end
        else begin
            if(axi_arready && S_AXI_ARVALID && ~axi_rvalid) begin
                axi_rvalid <= 1'b1;
                axi_rresp  <= 2'b0;  // OKAY 응답
            end
            else if(axi_rvalid && S_AXI_RREADY) begin
                axi_rvalid <= 1'b0;  // 마스터가 데이터 수락 → RVALID 해제
            end
        end
    end

// ──────────────────────────────────────────────────────────────────────
// 읽기 레지스터 선택 (조합 로직)
//   axi_araddr[3:2] (= 주소[ADDR_LSB+OPT_MEM_ADDR_BITS : ADDR_LSB])로 레지스터 선택.
//
//   slv_reg0 읽기 특수 처리:
//     reg_data_out = {slv_reg0[31:2], network_done, slv_reg0[0]}
//     → bit[1] 에 network_done 삽입 (소프트웨어 polling 용)
//     → bit[0] 은 ap_start (쓴 값 그대로 반환)
// ──────────────────────────────────────────────────────────────────────
    assign slv_reg_rden = axi_arready & S_AXI_ARVALID & ~axi_rvalid;

    always @(*) begin
        case(axi_araddr[ADDR_LSB+OPT_MEM_ADDR_BITS : ADDR_LSB])
            2'h0:    reg_data_out <= {slv_reg0[31:2], network_done, slv_reg0[0]};
                     // bit[1] = network_done: 추론 완료 상태를 소프트웨어에 반영
            2'h1:    reg_data_out <= slv_reg1;  // dram_wgt_base
            2'h2:    reg_data_out <= slv_reg2;  // dram_ifm_base
            2'h3:    reg_data_out <= slv_reg3;  // dram_ofm_base
            default: reg_data_out <= 0;
        endcase
    end

// ──────────────────────────────────────────────────────────────────────
// 읽기 데이터 레지스터 업데이트
//   slv_reg_rden=1 일 때 reg_data_out 을 axi_rdata 에 캡처.
// ──────────────────────────────────────────────────────────────────────
    always @(posedge S_AXI_ACLK) begin
        if(S_AXI_ARESETN == 1'b0)
            axi_rdata <= 0;
        else begin
            if(slv_reg_rden)
                axi_rdata <= reg_data_out;  // 레지스터 읽기 데이터 래치
        end
    end

// ──────────────────────────────────────────────────────────────────────
// 사용자 로직: 슬레이브 레지스터 → yolo_engine.v 출력
//   slv_reg0~3 를 ctrl_reg0~3 으로 직접 연결.
//   yolo_engine.v 는 이 신호를 사용하여:
//     ctrl_reg0[0] = ap_start  → 추론 시작
//     ctrl_reg1    = dram_wgt_base → 가중치 DMA 주소
//     ctrl_reg2    = dram_ifm_base → IFM DMA 주소
//     ctrl_reg3    = dram_ofm_base → OFM DMA 목적지 주소
// ──────────────────────────────────────────────────────────────────────
    assign ctrl_reg0 = slv_reg0;
    assign ctrl_reg1 = slv_reg1;
    assign ctrl_reg2 = slv_reg2;
    assign ctrl_reg3 = slv_reg3;

endmodule
