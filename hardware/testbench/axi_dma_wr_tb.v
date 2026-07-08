`timescale 1ns / 1ps
//----------------------------------------------------------------+
// axi_dma_wr_tb.v — axi_dma_wr Phase 3 격리 검증
//
// 검증 목표:
//   - AXI4 AW / W / B 핸드셰이크
//   - FIXED_BURST_SIZE=256 단위 burst 분할
//   - 마지막 burst 잔여 워드 처리
//   - indata_req_o 의 1-cycle look-ahead 데이터 요청
//   - WLAST = burst 의 마지막 beat 정확히 위치
//   - BRESP=OKAY 수신 후 burst 카운터 증가
//   - done_o 1-cycle 펄스 (전체 완료 시)
//   - 데이터 무결성 (DRAM 모델에 정확히 기록된 워드 ↔ TB 가 공급한 데이터)
//
// 시나리오:
//   A: num_trans=64        — 1 burst short
//   B: num_trans=256       — 1 burst exact
//   C: num_trans=300       — 2 burst (256 + 44)
//   D: num_trans=600       — 3 burst (256 + 256 + 88)
//----------------------------------------------------------------+
`include "user_define_h.v"

module axi_dma_wr_tb;

    parameter CLK_PERIOD = 10;
    reg clk, rstn;
    initial begin clk = 1'b0; forever #(CLK_PERIOD/2) clk = ~clk; end

    //--------------------------------------------------------------
    // AXI 신호
    //--------------------------------------------------------------
    wire         M_AWVALID;
    wire [31:0]  M_AWADDR;
    wire         M_AWREADY;
    wire [3:0]   M_AWID;
    wire [7:0]   M_AWLEN;
    wire [2:0]   M_AWSIZE;
    wire [1:0]   M_AWBURST;
    wire [1:0]   M_AWLOCK;
    wire [3:0]   M_AWCACHE;
    wire [2:0]   M_AWPROT;
    wire [3:0]   M_AWQOS;
    wire [3:0]   M_AWREGION;
    wire [3:0]   M_AWUSER;

    wire         M_WVALID;
    wire         M_WREADY;
    wire [31:0]  M_WDATA;
    wire [3:0]   M_WSTRB;
    wire         M_WLAST;
    wire [3:0]   M_WID;
    wire [3:0]   M_WUSER;

    wire         M_BVALID;
    wire         M_BREADY;
    wire [1:0]   M_BRESP;
    wire [3:0]   M_BID;
    wire         M_BUSER;

    //--------------------------------------------------------------
    // DUT 제어
    //--------------------------------------------------------------
    reg          start_dma;
    wire         done_o;
    reg  [12:0]  num_trans;
    reg  [31:0]  start_addr;
    reg  [31:0]  indata_r;
    wire         indata_req_o;
    wire         fail_check;

    axi_dma_wr u_dut (
        .M_AWVALID(M_AWVALID), .M_AWADDR(M_AWADDR), .M_AWREADY(M_AWREADY),
        .M_AWID(M_AWID), .M_AWLEN(M_AWLEN), .M_AWSIZE(M_AWSIZE),
        .M_AWBURST(M_AWBURST), .M_AWLOCK(M_AWLOCK), .M_AWCACHE(M_AWCACHE),
        .M_AWPROT(M_AWPROT), .M_AWQOS(M_AWQOS),
        .M_AWREGION(M_AWREGION), .M_AWUSER(M_AWUSER),
        .M_WVALID(M_WVALID), .M_WREADY(M_WREADY), .M_WDATA(M_WDATA),
        .M_WSTRB(M_WSTRB), .M_WLAST(M_WLAST),
        .M_WID(M_WID), .M_WUSER(M_WUSER),
        .M_BVALID(M_BVALID), .M_BREADY(M_BREADY), .M_BRESP(M_BRESP),
        .M_BID(M_BID), .M_BUSER(M_BUSER),
        .start_dma(start_dma), .done_o(done_o),
        .num_trans(num_trans), .start_addr(start_addr),
        .indata(indata_r), .indata_req_o(indata_req_o),
        .fail_check(fail_check),
        .clk(clk), .rstn(rstn)
    );

    //--------------------------------------------------------------
    // AXI Slave BFM
    //   - AW: 항시 ready, 수락 후 burst 정보 캡처
    //   - W : 항시 ready, beat 도착 시 DRAM 에 기록 (addr++)
    //   - B : WLAST 도착 후 1 cycle 뒤 BVALID=1, RESP=OKAY
    //--------------------------------------------------------------
    localparam integer DRAM_DEPTH = 16384;
    reg [31:0] dram [0:DRAM_DEPTH-1];

    reg        s_awready_r;
    reg        s_wready_r;
    reg        s_bvalid_r;
    reg [1:0]  s_bresp_r;

    assign M_AWREADY = s_awready_r;
    assign M_WREADY  = s_wready_r;
    assign M_BVALID  = s_bvalid_r;
    assign M_BRESP   = s_bresp_r;
    assign M_BID     = 4'd0;
    assign M_BUSER   = 1'b0;

    reg [31:0] s_wr_addr_r;        // 다음 W beat 가 기록될 워드 주소
    reg        s_busy_r;
    reg        s_wlast_seen_r;     // WLAST 수신 직후 1-cycle 표시

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            s_awready_r    <= 1'b1;
            s_wready_r     <= 1'b1;     // 항시 ready (단순 BFM)
            s_bvalid_r     <= 1'b0;
            s_bresp_r      <= 2'b00;
            s_wr_addr_r    <= 32'd0;
            s_busy_r       <= 1'b0;
            s_wlast_seen_r <= 1'b0;
        end else begin
            // B 채널: 1-cycle 후 deassert
            if (s_bvalid_r && M_BREADY) begin
                s_bvalid_r  <= 1'b0;
            end

            // AW 수락 → burst 캡처
            if (M_AWVALID && s_awready_r && !s_busy_r) begin
                s_wr_addr_r <= {M_AWADDR[31:2], 2'b00} >> 2;  // byte → word addr
                s_busy_r    <= 1'b1;
                s_awready_r <= 1'b0;
            end

            // W beat 수신 → DRAM 기록
            if (s_busy_r && M_WVALID && s_wready_r) begin
                if (s_wr_addr_r < DRAM_DEPTH)
                    dram[s_wr_addr_r] <= M_WDATA;
                s_wr_addr_r <= s_wr_addr_r + 32'd1;
                if (M_WLAST) begin
                    s_wlast_seen_r <= 1'b1;
                    s_busy_r       <= 1'b0;
                end
            end

            // WLAST 수신 다음 cycle 에 BVALID=1
            if (s_wlast_seen_r) begin
                s_bvalid_r     <= 1'b1;
                s_bresp_r      <= 2'b00;
                s_wlast_seen_r <= 1'b0;
                s_awready_r    <= 1'b1;     // 다음 burst 수락 가능
            end
        end
    end

    //--------------------------------------------------------------
    // TB-side data source (indata)
    //   - indata_req_o 가 high 인 cycle 다음에 indata 가 valid 해야 함.
    //   - 패턴: word i (write 시퀀스 내 i번째) → 0xAA000000 | i
    //--------------------------------------------------------------
    reg [12:0] words_sent_r;       // indata_req_o 발생 카운터
    reg [12:0] words_committed_r;  // 실제 W 채널로 나간 워드 수

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            indata_r          <= 32'd0;
            words_sent_r      <= 13'd0;
            words_committed_r <= 13'd0;
        end else begin
            if (indata_req_o) begin
                // 다음 사이클 indata = pattern(words_sent_r)
                indata_r     <= 32'hAA00_0000 | {19'd0, words_sent_r};
                words_sent_r <= words_sent_r + 13'd1;
            end
            if (M_WVALID && s_wready_r)
                words_committed_r <= words_committed_r + 13'd1;
        end
    end

    //--------------------------------------------------------------
    // 시나리오
    //--------------------------------------------------------------
    integer mismatch_total;

    task automatic run_scenario;
        input [12:0]  n_trans;
        input [31:0]  base_byte_addr;
        input integer scenario_id;
        integer i, mm;
        integer base_word_addr;
        reg [31:0] expected_word;
        reg [31:0] got_word;
        integer expected_bursts, last_burst_size;
        integer t0;
        begin
            // Reset 데이터 카운터 (DRAM 은 유지 — 시나리오마다 다른 영역 사용)
            @(posedge clk);
            words_sent_r      <= 13'd0;
            words_committed_r <= 13'd0;

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
            #(2*CLK_PERIOD);

            // Pattern 검증 — DUT 에서 본 i번째 indata_req_o 마다 idx 가 증가하므로
            // dram[base_word + i] 가 pattern(i) 와 같아야 함.
            //   ※ DUT 가 첫 indata_req_o 를 WR_START 에 1회, 이후 WR_SEQ 에서 burst 당
            //     (burst_size-1) 회 발사 → 총 num_trans 회.
            //
            //   indata 가 1-cycle 지연으로 들어오므로 words_sent_r 는 실제로 사용된
            //   pattern idx 의 다음 값까지 셈. words_committed_r = 실제 commit 수.
            base_word_addr = base_byte_addr >> 2;
            mm = 0;
            for (i = 0; i < n_trans; i = i + 1) begin
                expected_word = 32'hAA00_0000 | i;
                got_word      = dram[base_word_addr + i];
                if (got_word !== expected_word) begin
                    if (mm < 8) begin
                        $display("[Scenario %0d MISMATCH] dram[%0d] = 0x%08h  expected 0x%08h",
                            scenario_id, base_word_addr + i, got_word, expected_word);
                    end
                    mm = mm + 1;
                end
            end

            $display("[Scenario %0d] indata_req_count=%0d  committed=%0d  mismatches=%0d  elapsed=%0d ns",
                scenario_id, words_sent_r, words_committed_r, mm, $time - t0);

            if (mm == 0 && words_committed_r == n_trans)
                $display("[Scenario %0d] *** PASSED ***", scenario_id);
            else begin
                $display("[Scenario %0d] *** FAILED ***", scenario_id);
                mismatch_total = mismatch_total + mm + (words_committed_r !== n_trans ? 1 : 0);
            end
        end
    endtask

    //--------------------------------------------------------------
    // Main
    //--------------------------------------------------------------
    integer di;
    initial begin
        rstn       = 1'b0;
        start_dma  = 1'b0;
        num_trans  = 13'd0;
        start_addr = 32'd0;
        indata_r   = 32'd0;
        mismatch_total = 0;

        for (di = 0; di < DRAM_DEPTH; di = di + 1) dram[di] = 32'h0;

        #(8*CLK_PERIOD) rstn = 1'b1;
        #(4*CLK_PERIOD);

        run_scenario(13'd64,   32'h0000_0000, 0);
        run_scenario(13'd256,  32'h0000_1000, 1);
        run_scenario(13'd300,  32'h0000_2000, 2);
        run_scenario(13'd600,  32'h0000_4000, 3);

        $display("============================================================");
        if (mismatch_total == 0)
            $display("[axi_dma_wr_tb] *** ALL PASSED *** (A + B + C + D)");
        else
            $display("[axi_dma_wr_tb] *** FAILED *** total mismatches = %0d", mismatch_total);
        $display("============================================================");

        #(20*CLK_PERIOD) $finish;
    end

    initial begin
        #(10_000_000 * CLK_PERIOD);
        $display("[axi_dma_wr_tb] *** TIMEOUT ***");
        $finish;
    end

endmodule
