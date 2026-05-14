`timescale 1ns / 1ps

//================================================================
// 모듈명: accumulator
// 
// 역할: MAC 연산 결과를 지정된 횟수만큼 누적하는 하드웨어 블록
// 
// 동작:
//   1. 데이터 유효 신호(vld_i)가 1(HIGH)로 들어오는 매 사이클마다 연산을 수행함.
//   2. 내부 누적 카운터(cycle_cnt)가 0일 때: 
//      - 첫 번째 데이터이므로 기존 값을 무시하고, 새로운 입력(mac_result)으로 누적 레지스터(acc_out)를 초기화함.
//   3. 내부 누적 카운터(cycle_cnt)가 0보다 클 때: 
//      - 기존 누적 레지스터(acc_out) 값에 새로운 입력(mac_result)을 부호 있는 수(Signed)로 취급하여 더함.
//   4. 카운터가 목표 누적 횟수(num_cycles - 1)에 도달했을 때:
//      - 다음 클록에 누적 완료 펄스(acc_done)를 딱 1사이클 동안 1(HIGH)로 출력함.
//      - 내부 카운터를 다시 0으로 초기화하여 다음 새로운 누적 작업을 준비함.
// 
// 레이턴시: num_cycles 클록
//================================================================

module accumulator (
    input                clk,         
    input                rstn,        // Active-low 리셋
    input                vld_i,       // 데이터 유효 신호
    input signed [19:0]  mac_result,  // MAC 연산 결과
    input        [7:0]   num_cycles,  // 총 누적 횟수
    output reg signed [31:0] acc_out, // 누적 완료 결과
    output reg           acc_done     // 누적 완료 펄스 (1 사이클)
);

reg [7:0] cycle_cnt; 

always @(posedge clk, negedge rstn) begin
    if (!rstn) begin
        acc_out   <= 0;
        cycle_cnt <= 0;
        acc_done  <= 0;
    end
    else begin
        acc_done <= 0; 

        if (vld_i) begin
            
            // 1. 누적 연산
            if (cycle_cnt == 0)
                acc_out <= $signed(mac_result);
            else
                acc_out <= $signed(acc_out) + $signed(mac_result);
            
            // 2. 카운터 및 완료 제어
            if (cycle_cnt == num_cycles - 1) begin
                acc_done  <= 1; 
                cycle_cnt <= 0; 
            end
            else begin
                cycle_cnt <= cycle_cnt + 1; 
            end
        end
    end
end
endmodule