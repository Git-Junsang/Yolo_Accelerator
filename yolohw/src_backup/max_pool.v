//================================================================
// 모듈명: max_pool
// 
// 역할: 2x2 윈도우 내의 4개 픽셀 중 최댓값을 추출하여 출력 해상도를 줄이는 블록
// 
// 동작:
//   1. 풀링 활성화 신호(pool_en)가 0일 때 (Bypass 모드):
//      - 입력되는 픽셀(pixel_in)을 최댓값 비교 없이 다음 클록에 그대로 통과시킴.
//   2. 풀링 활성화 신호(pool_en)가 1일 때 (Pooling 모드):
//      - 유효한 픽셀(pixel_valid)이 들어올 때마다 카운터(cnt)를 0에서 3까지 증가시킴.
//      - cnt = 0: 윈도우의 첫 번째 픽셀이므로, 최댓값 레지스터(max_reg)를 현재 입력값으로 초기화함.
//      - cnt = 1, 2: 현재 입력값(pixel_in)과 레지스터 값(max_reg) 중 더 큰 값을 찾아 레지스터를 업데이트함.
//      - cnt = 3: 윈도우의 마지막 네 번째 픽셀과 기존 최댓값을 비교하여 최종 최댓값을 도출함.
//                 이후 다음 클록에 풀링 결과(pool_out)로 출력함과 동시에 유효 펄스(pool_valid)를 1로 발생시키고,
//                 카운터와 레지스터를 0으로 초기화하여 다음 2x2 윈도우 연산을 준비함.
// 
// 레이턴시: Bypass 시 1 클록 / Pooling 시 4 유효 픽셀당 1 클록 (윈도우 1개당 4 클록)
//================================================================
module max_pool(
    input               clk,
    input               rstn,

    // 제어 신호
    input               pool_en,        // 1=Pooling 동작, 0=Bypass 통과

    // 입력
    input               pixel_valid,    // 입력 픽셀 유효 신호
    input      [7:0]    pixel_in,       // 8bit Unsigned 입력 픽셀 (ReLU 이후)

    // 출력
    output reg [7:0]    pool_out,       // Max 결과 또는 Bypass 원본 출력
    output reg          pool_valid      // 출력 유효 펄스 (1 사이클)
);

//----------------------------------------------------------------------
// 내부 상태 레지스터
//----------------------------------------------------------------------
reg [7:0] max_reg;          // 현재까지의 최댓값을 저장하는 레지스터
reg [1:0] cnt;              // 2x2=4개의 픽셀을 세는 0~3 카운터

//----------------------------------------------------------------------
// 조합 로직: 실시간 최댓값 비교
//----------------------------------------------------------------------
wire [7:0] cur_max;
assign cur_max = (pixel_in > max_reg) ? pixel_in : max_reg;

//----------------------------------------------------------------------
// 순차 로직: 메인 제어 블록
//----------------------------------------------------------------------
always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
        max_reg    <= 8'd0;
        cnt        <= 2'd0;
        pool_out   <= 8'd0;
        pool_valid <= 1'b0;
    end
    else begin
        pool_valid <= 1'b0; 

        if (pixel_valid) begin
            if (!pool_en) begin
                // 1. Bypass 모드: 연산 없이 즉시 출력 레지스터로 전달
                pool_out   <= pixel_in;
                pool_valid <= 1'b1;
            end
            else begin
                // 2. Pooling 모드: 4개 픽셀 중 최댓값 탐색
                case (cnt)
                    2'd0: begin
                        max_reg <= pixel_in;    // 첫 픽셀로 초기화
                        cnt     <= 2'd1;
                    end
                    2'd1: begin
                        max_reg <= cur_max;     // 두 번째 픽셀 비교
                        cnt     <= 2'd2;
                    end
                    2'd2: begin
                        max_reg <= cur_max;     // 세 번째 픽셀 비교
                        cnt     <= 2'd3;
                    end
                    2'd3: begin
                        pool_out   <= cur_max;  // 네 번째 픽셀 비교 후 최종 출력!
                        pool_valid <= 1'b1;
                        cnt        <= 2'd0;     // 카운터 리셋
                        max_reg    <= 8'd0;     // 최댓값 레지스터 리셋
                    end
                endcase
            end
        end
    end
end
endmodule