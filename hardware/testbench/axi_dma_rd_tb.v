`timescale 1ns / 1ps
//----------------------------------------------------------------+
// axi_dma_rd_tb.v — axi_dma_rd Phase 3 격리 검증
//
// 검증 목표:
//   - AXI4 AR / R 핸드셰이크
//   - FIXED_BURST_SIZE=256 단위 burst 분할
//   - 마지막 burst 의 잔여 워드 처리 (num_trans % 256)
//   - data_o / data_vld_o 의 1-cycle 지연
//   - done_o 1-cycle 펄스
//   - 데이터 무결성 (DUT 가 수신한 워드 ↔ DRAM 모델의 해당 주소)
//
// TB 구성:
//   ┌──────────────┐     AR     ┌─────────────┐
//   │  axi_dma_rd  │ ─────────► │ AXI Slave   │ — DRAM[]
//   │   (DUT)      │ ◄───────── │   BFM       │
//   └──────────────┘      R     └─────────────┘
//
// 시나리오:
//   A: num_trans=64        — 1 burst, 잔여 64 워드
//   B: num_trans=256       — 1 burst, 정확히 한 burst
//   C: num_trans=300       — 2 burst (256 + 44)
//   D: num_trans=600       — 3 burst (256 + 256 + 88)
//----------------------------------------------------------------+
`include "user_define_h.v"

module axi_dma_rd_tb;

    parameter CLK_PERIOD = 10;
    reg clk, rstn;
    initial begin clk = 1'b0; forever #(CLK_PERIOD/2) clk = ~clk; end

    //--------------------------------------------------------------
    // AXI 신호
    //--------------------------------------------------------------
    wire         M_ARVALID;
    wire         M_ARREADY;
    wire [31:0]  M_ARADDR;
    wire [3:0]   M_ARID;
    wire [7:0]   M_ARLEN;
    wire [2:0]   M_ARSIZE;
    wire [1:0]   M_ARBURST;
    wire [1:0]   M_ARLOCK;
    wire [3:0]   M_ARCACHE;
    wire [2:0]   M_ARPROT;
    wire [3:0]   M_ARQOS;
    wire [3:0]   M_ARREGION;
    wire [3:0]   M_ARUSER;

    wire         M_RVALID;
    wire         M_RREADY;
    wire [31:0]  M_RDATA;
    wire         M_RLAST;
    wire [3:0]   M_RID;
    wire [3:0]   M_RUSER;
    wire [1:0]   M_RRESP;

    //--------------------------------------------------------------
    // DUT 제어
    //--------------------------------------------------------------
    reg          start_dma;
    reg  [17:0]  num_trans;
    reg  [31:0]  start_addr;
    wire [31:0]  data_o;
    wire         data_vld_o;
    wire [17:0]  data_cnt_o;
    wire         done_o;

    axi_dma_rd u_dut (
        .M_ARVALID(M_ARVALID), .M_ARREADY(M_ARREADY),
        .M_ARADDR(M_ARADDR), .M_ARID(M_ARID), .M_ARLEN(M_ARLEN),
        .M_ARSIZE(M_ARSIZE), .M_ARBURST(M_ARBURST), .M_ARLOCK(M_ARLOCK),
        .M_ARCACHE(M_ARCACHE), .M_ARPROT(M_ARPROT), .M_ARQOS(M_ARQOS),
        .M_ARREGION(M_ARREGION), .M_ARUSER(M_ARUSER),
        .M_RVALID(M_RVALID), .M_RREADY(M_RREADY),
        .M_RDATA(M_RDATA), .M_RLAST(M_RLAST),
        .M_RID(M_RID), .M_RUSER(M_RUSER), .M_RRESP(M_RRESP),
        .start_dma(start_dma), .num_trans(num_trans), .start_addr(start_addr),
        .data_o(data_o), .data_vld_o(data_vld_o), .data_cnt_o(data_cnt_o),
        .done_o(done_o),
        .clk(clk), .rstn(rstn)
    );

    //--------------------------------------------------------------
    // AXI Slave BFM
    //   - 한 outstanding transaction 가정
    //   - AR 수락 즉시 R 채널 beat 생성 시작
    //   - DRAM 모델: 16384 워드 (64KB)
    //   - 데이터: dram[i] = i (단순 인덱스 패턴)
    //--------------------------------------------------------------
    localparam integer DRAM_DEPTH = 16384;
    reg [31:0] dram [0:DRAM_DEPTH-1];

    reg        s_arready_r;
    reg        s_rvalid_r;
    reg [31:0] s_rdata_r;
    reg        s_rlast_r;
    reg [1:0]  s_rresp_r;

    assign M_ARREADY = s_arready_r;
    assign M_RVALID  = s_rvalid_r;
    assign M_RDATA   = s_rdata_r;
    assign M_RLAST   = s_rlast_r;
    assign M_RRESP   = s_rresp_r;
    assign M_RID     = 4'd0;
    assign M_RUSER   = 4'd0;

    // 슬레이브 FSM
    localparam S_IDLE = 1'b0, S_BUSY = 1'b1;
    reg        s_state_r;
    reg [31:0] s_burst_addr_r;   // 다음 beat 의 워드 주소
    reg [7:0]  s_beat_left_r;    // 남은 beat 수 - 1 (= ARLEN 의 잔여)

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            s_state_r      <= S_IDLE;
            s_arready_r    <= 1'b1;
            s_rvalid_r     <= 1'b0;
            s_rdata_r      <= 32'd0;
            s_rlast_r      <= 1'b0;
            s_rresp_r      <= 2'b00;
            s_burst_addr_r <= 32'd0;
            s_beat_left_r  <= 8'd0;
        end else begin
            case (s_state_r)
                S_IDLE: begin
                    // R 채널 출력 deassert
                    s_rvalid_r <= 1'b0;
                    s_rlast_r  <= 1'b0;
                    s_rresp_r  <= 2'b00;
                    s_arready_r <= 1'b1;
                    // AR 핸드셰이크 감지
                    if (M_ARVALID && s_arready_r) begin
                        s_burst_addr_r <= M_ARADDR[31:2];   // byte → word
                        s_beat_left_r  <= M_ARLEN;          // beat 수 - 1
                        s_state_r      <= S_BUSY;
                        s_arready_r    <= 1'b0;
                    end
                end

                S_BUSY: begin
                    // R 채널: 매 cycle 한 beat 송신
                    s_rvalid_r <= 1'b1;
                    s_rdata_r  <= (s_burst_addr_r < DRAM_DEPTH) ? dram[s_burst_addr_r] : 32'hDEADBEEF;
                    s_rlast_r  <= (s_beat_left_r == 8'd0);
                    s_rresp_r  <= 2'b00;
                    if (M_RREADY) begin
                        if (s_beat_left_r == 8'd0) begin
                            // 마지막 beat 수락 완료 — 다음 cycle 에 IDLE 로 전이
                            // (rvalid/rlast 는 IDLE 진입 cycle 에 deassert)
                            s_state_r <= S_IDLE;
                        end else begin
                            s_beat_left_r  <= s_beat_left_r - 8'd1;
                            s_burst_addr_r <= s_burst_addr_r + 32'd1;
                        end
                    end
                end
            endcase
        end
    end

    //--------------------------------------------------------------
    // Stimulus / Verify
    //--------------------------------------------------------------
    integer i, j;
    integer mismatch_total;
    reg [17:0] words_received;
    reg [31:0] expected_word;

    // 수신 데이터 캡처 + 즉시 비교
    integer s_mm;
    always @(posedge clk) begin
        if (data_vld_o) begin
            expected_word = dram[(start_addr[31:2]) + words_received];
            if (data_o !== expected_word) begin
                if (s_mm < 8) begin
                    $display("[MISMATCH] word#%0d (addr_word=%0d): got=0x%08h exp=0x%08h",
                        words_received,
                        (start_addr[31:2]) + words_received,
                        data_o, expected_word);
                end
                s_mm = s_mm + 1;
            end
            words_received = words_received + 18'd1;
        end
    end

    task automatic run_scenario;
        input [17:0]      n_trans;
        input [31:0]      base_byte_addr;
        input integer     scenario_id;
        integer expected_bursts;
        integer last_burst_size;
        integer t0;
        begin
            words_received = 18'd0;
            s_mm           = 0;

            // 예상 burst 분석
            expected_bursts = (n_trans + 255) / 256;
            last_burst_size = n_trans - (expected_bursts-1)*256;

            $display("============================================================");
            $display("[Scenario %0d] num_trans=%0d  start_byte=0x%08h",
                scenario_id, n_trans, base_byte_addr);
            $display("              expected: %0d burst (last=%0d words)",
                expected_bursts, last_burst_size);
            $display("============================================================");

            @(posedge clk);
            num_trans  <= n_trans;
            start_addr <= base_byte_addr;
            start_dma  <= 1'b1;
            @(posedge clk);
            start_dma  <= 1'b0;

            t0 = $time;
            wait (done_o == 1'b1);
            @(posedge clk);

            // 추가 cycle 대기 — data_vld_o 마지막 latch
            #(2*CLK_PERIOD);

            $display("[Scenario %0d] received %0d / %0d words   mismatches=%0d   elapsed=%0d ns",
                scenario_id, words_received, n_trans, s_mm, $time - t0);

            if (words_received !== n_trans)
                $display("[Scenario %0d] *** WORD COUNT MISMATCH ***", scenario_id);

            if (s_mm == 0 && words_received == n_trans)
                $display("[Scenario %0d] *** PASSED ***", scenario_id);
            else begin
                $display("[Scenario %0d] *** FAILED ***", scenario_id);
                mismatch_total = mismatch_total + s_mm + (words_received !== n_trans ? 1 : 0);
            end
        end
    endtask

    //--------------------------------------------------------------
    // Main
    //--------------------------------------------------------------
    initial begin
        rstn       = 1'b0;
        start_dma  = 1'b0;
        num_trans  = 18'd0;
        start_addr = 32'd0;
        mismatch_total = 0;

        // DRAM 초기화: dram[i] = i (단순 패턴, 0xDEADBEEF 와 구분되도록)
        for (i = 0; i < DRAM_DEPTH; i = i + 1) dram[i] = i;

        #(8*CLK_PERIOD) rstn = 1'b1;
        #(4*CLK_PERIOD);

        run_scenario(18'd64,   32'h0000_0000, 0);    // A: 1 burst short
        run_scenario(18'd256,  32'h0000_1000, 1);    // B: 1 burst exact (start offset 1KB)
        run_scenario(18'd300,  32'h0000_2000, 2);    // C: 2 bursts (256 + 44)
        run_scenario(18'd600,  32'h0000_4000, 3);    // D: 3 bursts (256+256+88)

        $display("============================================================");
        if (mismatch_total == 0)
            $display("[axi_dma_rd_tb] *** ALL PASSED *** (A + B + C + D)");
        else
            $display("[axi_dma_rd_tb] *** FAILED *** total mismatches = %0d", mismatch_total);
        $display("============================================================");

        #(20*CLK_PERIOD) $finish;
    end

    initial begin
        #(10_000_000 * CLK_PERIOD);
        $display("[axi_dma_rd_tb] *** TIMEOUT ***");
        $finish;
    end

endmodule
