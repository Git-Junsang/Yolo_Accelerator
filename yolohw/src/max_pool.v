//================================================================
// max_pool.v — [LEGACY] 단일 픽셀 스트림 2×2 Max Pooling 모듈
//
// ⚠️  이 파일은 레거시(legacy) 파일입니다.
//     현재 프로젝트에서는 사용하지 않으며 Vivado 소스 목록에 포함하지 마십시오.
//     대체 모듈:
//       - max_pool_unit.v    : stride-2 maxpool (Layer 1,3,5,7,9 사용)
//       - max_pool_s1_unit.v : stride-1 maxpool (Layer 11 전용)
//
// 원래 역할:
//   단일 픽셀 스트림(pixel_in, pixel_valid) 인터페이스로 입력되는 8-bit 픽셀에 대해
//   2×2=4 픽셀 윈도우 내 최댓값을 추출. Bypass 모드도 지원.
//
//   pool_en=0 (Bypass): pixel_in → pool_out (1 사이클 지연)
//   pool_en=1 (Pooling): 4개 픽셀 수신 후 최댓값 출력 (4 사이클 per 출력)
//
// 현재 프로젝트와의 차이:
//   현재 YOLOv2 가속기는 4-pixel packed 32-bit 버스를 사용하므로
//   이 모듈의 1-pixel 스트림 인터페이스와 맞지 않음.
//   max_pool_unit.v 가 packed 데이터를 처리하는 올바른 대체 모듈.
//================================================================
module max_pool(
    input               clk,
    input               rstn,

    // 제어 신호
    input               pool_en,        // 1=Pooling 동작, 0=Bypass 통과

    // 입력
    input               pixel_valid,    // 입력 픽셀 유효 신호
    input      [7:0]    pixel_in,       // 8-bit Unsigned 입력 픽셀 (ReLU 이후)

    // 출력
    output reg [7:0]    pool_out,       // Max 결과 또는 Bypass 원본 출력
    output reg          pool_valid      // 출력 유효 펄스 (1 사이클)
);

//──────────────────────────────────────────────────────────────
// 내부 상태 레지스터
//──────────────────────────────────────────────────────────────
reg [7:0] max_reg;  // 현재까지의 최댓값 레지스터
reg [1:0] cnt;      // 2×2=4픽셀 카운터 (0~3 순환)

//──────────────────────────────────────────────────────────────
// 조합 로직: 현재 입력 vs 누적 최댓값 실시간 비교
//──────────────────────────────────────────────────────────────
wire [7:0] cur_max;
assign cur_max = (pixel_in > max_reg) ? pixel_in : max_reg;

//──────────────────────────────────────────────────────────────
// 순차 로직: Max Pooling FSM
//
// Bypass 모드 (pool_en=0):
//   pixel_valid=1 마다 pixel_in 을 pool_out 에 1 사이클 지연하여 출력.
//   pool_valid=1 동시 어서트.
//
// Pooling 모드 (pool_en=1):
//   cnt=0: 윈도우 첫 픽셀 → max_reg 초기화
//   cnt=1: 두 번째 픽셀 → cur_max 로 max_reg 업데이트
//   cnt=2: 세 번째 픽셀 → cur_max 로 max_reg 업데이트
//   cnt=3: 네 번째 픽셀 → cur_max 를 pool_out 으로 출력, pool_valid=1, 카운터 리셋
//──────────────────────────────────────────────────────────────
always @(posedge clk or negedge rstn) begin
    if(!rstn) begin
        max_reg    <= 8'd0;
        cnt        <= 2'd0;
        pool_out   <= 8'd0;
        pool_valid <= 1'b0;
    end
    else begin
        pool_valid <= 1'b0;  // 기본값: 출력 비유효 (매 사이클 리셋)

        if(pixel_valid) begin
            if(!pool_en) begin
                // Bypass 모드: 입력을 그대로 1 사이클 후 출력
                pool_out   <= pixel_in;
                pool_valid <= 1'b1;
            end
            else begin
                // Pooling 모드: 2×2 윈도우 내 최댓값 탐색
                case(cnt)
                    2'd0: begin
                        max_reg <= pixel_in;  // 첫 픽셀로 최댓값 레지스터 초기화
                        cnt     <= 2'd1;
                    end
                    2'd1: begin
                        max_reg <= cur_max;   // 두 번째 픽셀: 현재 최댓값 갱신
                        cnt     <= 2'd2;
                    end
                    2'd2: begin
                        max_reg <= cur_max;   // 세 번째 픽셀: 현재 최댓값 갱신
                        cnt     <= 2'd3;
                    end
                    2'd3: begin
                        pool_out   <= cur_max; // 네 번째 픽셀: 최종 최댓값 출력
                        pool_valid <= 1'b1;
                        cnt        <= 2'd0;    // 카운터 리셋 (다음 2×2 윈도우 준비)
                        max_reg    <= 8'd0;    // 최댓값 레지스터 초기화
                    end
                endcase
            end
        end
    end
end

endmodule
