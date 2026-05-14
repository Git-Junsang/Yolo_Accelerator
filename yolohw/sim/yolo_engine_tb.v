`timescale 1ns / 1ns
//----------------------------------------------------------------+
// yolo_engine_tb.v — Lecture-aligned end-to-end TB (Phase 4)
//
// 구조:
//   - DUT: yolo_engine (AXI master + slave)
//   - DRAM model: behavioral 4 MB reg array + simple AXI slave responder
//   - TB 가 hex 를 읽어 padding 후 DRAM 에 적재 → ap_start → network_done wait → OFM 검증
//
// 전제 조건:
//   - user_define_h.v 의 `define FPGA 줄을 시뮬레이션 시 주석 처리.
//----------------------------------------------------------------+
`include "user_define_h.v"

module yolo_engine_tb;

`ifdef FPGA
    initial begin
        $display("[TB][FATAL] FPGA macro is enabled. Comment out `define FPGA in user_define_h.v.");
        $finish;
    end
`else

    parameter CLK_PERIOD = 10;
    reg clk;
    reg rstn;

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    //--------------------------------------------------------------
    // AXI4-Lite slave (tied — TB 가 직접 slv_reg force)
    //--------------------------------------------------------------
    wire [3:0]  S_AWADDR  = 4'd0;
    wire [2:0]  S_AWPROT  = 3'd0;
    wire        S_AWVALID = 1'b0;
    wire        S_AWREADY;
    wire [31:0] S_WDATA   = 32'd0;
    wire [3:0]  S_WSTRB   = 4'd0;
    wire        S_WVALID  = 1'b0;
    wire        S_WREADY;
    wire [1:0]  S_BRESP;
    wire        S_BVALID;
    wire        S_BREADY  = 1'b1;
    wire [3:0]  S_ARADDR  = 4'd0;
    wire [2:0]  S_ARPROT  = 3'd0;
    wire        S_ARVALID = 1'b0;
    wire        S_ARREADY;
    wire [31:0] S_RDATA;
    wire [1:0]  S_RRESP;
    wire        S_RVALID;
    wire        S_RREADY  = 1'b1;

    //--------------------------------------------------------------
    // AXI4 master (DUT) — TB DRAM 모델로 연결
    //--------------------------------------------------------------
    wire        M_ARVALID, M_ARREADY;
    wire [31:0] M_ARADDR;
    wire [3:0]  M_ARID;
    wire [7:0]  M_ARLEN;
    wire [2:0]  M_ARSIZE;
    wire [1:0]  M_ARBURST, M_ARLOCK;
    wire [3:0]  M_ARCACHE;
    wire [2:0]  M_ARPROT;
    wire [3:0]  M_ARQOS, M_ARREGION, M_ARUSER;
    wire        M_RVALID, M_RREADY, M_RLAST;
    wire [31:0] M_RDATA;
    wire [3:0]  M_RID, M_RUSER;
    wire [1:0]  M_RRESP;
    wire        M_AWVALID, M_AWREADY;
    wire [31:0] M_AWADDR;
    wire [3:0]  M_AWID;
    wire [7:0]  M_AWLEN;
    wire [2:0]  M_AWSIZE;
    wire [1:0]  M_AWBURST, M_AWLOCK;
    wire [3:0]  M_AWCACHE;
    wire [2:0]  M_AWPROT;
    wire [3:0]  M_AWQOS, M_AWREGION, M_AWUSER;
    wire        M_WVALID, M_WREADY, M_WLAST;
    wire [31:0] M_WDATA;
    wire [3:0]  M_WSTRB, M_WID, M_WUSER;
    wire        M_BVALID, M_BREADY;
    wire [1:0]  M_BRESP;
    wire [3:0]  M_BID;
    wire        M_BUSER;

    wire        network_done, network_done_led;

    //--------------------------------------------------------------
    // DUT
    //--------------------------------------------------------------
    yolo_engine #(
        .C_S_AXI_DATA_WIDTH(32),
        .C_S_AXI_ADDR_WIDTH(4),
        .AXI_M_WIDTH_AD(32),
        .AXI_M_WIDTH_DA(32),
        .AXI_M_WIDTH_ID(4)
    ) u_yolo_engine (
        .clk(clk), .rstn(rstn),
        .S_AXI_AWADDR(S_AWADDR), .S_AXI_AWPROT(S_AWPROT),
        .S_AXI_AWVALID(S_AWVALID), .S_AXI_AWREADY(S_AWREADY),
        .S_AXI_WDATA(S_WDATA), .S_AXI_WSTRB(S_WSTRB),
        .S_AXI_WVALID(S_WVALID), .S_AXI_WREADY(S_WREADY),
        .S_AXI_BRESP(S_BRESP), .S_AXI_BVALID(S_BVALID),
        .S_AXI_BREADY(S_BREADY),
        .S_AXI_ARADDR(S_ARADDR), .S_AXI_ARPROT(S_ARPROT),
        .S_AXI_ARVALID(S_ARVALID), .S_AXI_ARREADY(S_ARREADY),
        .S_AXI_RDATA(S_RDATA), .S_AXI_RRESP(S_RRESP),
        .S_AXI_RVALID(S_RVALID), .S_AXI_RREADY(S_RREADY),
        // AXI master
        .M_ARVALID(M_ARVALID), .M_ARREADY(M_ARREADY), .M_ARADDR(M_ARADDR),
        .M_ARID(M_ARID), .M_ARLEN(M_ARLEN), .M_ARSIZE(M_ARSIZE),
        .M_ARBURST(M_ARBURST), .M_ARLOCK(M_ARLOCK), .M_ARCACHE(M_ARCACHE),
        .M_ARPROT(M_ARPROT), .M_ARQOS(M_ARQOS), .M_ARREGION(M_ARREGION), .M_ARUSER(M_ARUSER),
        .M_RVALID(M_RVALID), .M_RREADY(M_RREADY), .M_RDATA(M_RDATA),
        .M_RLAST(M_RLAST), .M_RID(M_RID), .M_RUSER(M_RUSER), .M_RRESP(M_RRESP),
        .M_AWVALID(M_AWVALID), .M_AWREADY(M_AWREADY), .M_AWADDR(M_AWADDR),
        .M_AWID(M_AWID), .M_AWLEN(M_AWLEN), .M_AWSIZE(M_AWSIZE),
        .M_AWBURST(M_AWBURST), .M_AWLOCK(M_AWLOCK), .M_AWCACHE(M_AWCACHE),
        .M_AWPROT(M_AWPROT), .M_AWQOS(M_AWQOS), .M_AWREGION(M_AWREGION), .M_AWUSER(M_AWUSER),
        .M_WVALID(M_WVALID), .M_WREADY(M_WREADY), .M_WDATA(M_WDATA),
        .M_WSTRB(M_WSTRB), .M_WLAST(M_WLAST), .M_WID(M_WID), .M_WUSER(M_WUSER),
        .M_BVALID(M_BVALID), .M_BREADY(M_BREADY), .M_BRESP(M_BRESP),
        .M_BID(M_BID), .M_BUSER(M_BUSER),
        .o_network_done(network_done),
        .network_done_led(network_done_led)
    );

    /* verilator lint_off UNUSED */
    wire _unused_done_led = network_done_led;
    /* verilator lint_on UNUSED */

    //==============================================================
    // Behavioral DRAM 모델 (1 MB, 32-bit word, AXI slave)
    //   - Burst read: ARVALID 받으면 burst length 동안 RDATA 출력
    //   - Burst write: AWVALID + WVALID → 메모리에 write
    //==============================================================
    localparam integer DRAM_WORDS = 1024 * 1024;  // 4 MB
    reg [31:0] dram [0:DRAM_WORDS-1];

    // Read FSM
    reg        rd_busy_r;
    reg [31:0] rd_addr_r;
    reg [7:0]  rd_beat_r;
    reg [7:0]  rd_len_r;
    reg [3:0]  rd_id_r;

    assign M_ARREADY = !rd_busy_r;
    assign M_RVALID  = rd_busy_r;
    assign M_RDATA   = rd_busy_r ? dram[rd_addr_r[23:2]] : 32'd0;
    assign M_RLAST   = rd_busy_r && (rd_beat_r == rd_len_r);
    assign M_RID     = rd_id_r;
    assign M_RUSER   = 4'd0;
    assign M_RRESP   = 2'b00;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            rd_busy_r <= 1'b0;
            rd_addr_r <= 32'd0;
            rd_beat_r <= 8'd0;
            rd_len_r  <= 8'd0;
            rd_id_r   <= 4'd0;
        end else begin
            if (!rd_busy_r) begin
                if (M_ARVALID) begin
                    rd_busy_r <= 1'b1;
                    rd_addr_r <= M_ARADDR;
                    rd_len_r  <= M_ARLEN;
                    rd_beat_r <= 8'd0;
                    rd_id_r   <= M_ARID;
                end
            end else begin
                if (M_RREADY) begin
                    if (rd_beat_r == rd_len_r) begin
                        rd_busy_r <= 1'b0;
                    end else begin
                        rd_addr_r <= rd_addr_r + 32'd4;
                        rd_beat_r <= rd_beat_r + 8'd1;
                    end
                end
            end
        end
    end

    // Write FSM
    reg        wr_addr_busy_r;
    reg        wr_data_busy_r;
    reg [31:0] wr_addr_r;
    reg [7:0]  wr_beat_r;
    reg [7:0]  wr_len_r;
    reg [3:0]  wr_id_r;
    reg        wr_resp_pending_r;

    assign M_AWREADY = !wr_addr_busy_r;
    assign M_WREADY  = wr_data_busy_r;
    assign M_BVALID  = wr_resp_pending_r;
    assign M_BRESP   = 2'b00;
    assign M_BID     = wr_id_r;
    assign M_BUSER   = 1'b0;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            wr_addr_busy_r    <= 1'b0;
            wr_data_busy_r    <= 1'b0;
            wr_addr_r         <= 32'd0;
            wr_beat_r         <= 8'd0;
            wr_len_r          <= 8'd0;
            wr_id_r           <= 4'd0;
            wr_resp_pending_r <= 1'b0;
        end else begin
            // Address phase
            if (!wr_addr_busy_r) begin
                if (M_AWVALID) begin
                    wr_addr_busy_r <= 1'b1;
                    wr_addr_r      <= M_AWADDR;
                    wr_len_r       <= M_AWLEN;
                    wr_beat_r      <= 8'd0;
                    wr_id_r        <= M_AWID;
                    wr_data_busy_r <= 1'b1;
                end
            end

            // Data phase
            if (wr_data_busy_r && M_WVALID) begin
                dram[wr_addr_r[23:2]] <= M_WDATA;
                if (M_WLAST) begin
                    wr_data_busy_r    <= 1'b0;
                    wr_addr_busy_r    <= 1'b0;
                    wr_resp_pending_r <= 1'b1;
                end else begin
                    wr_addr_r <= wr_addr_r + 32'd4;
                    wr_beat_r <= wr_beat_r + 8'd1;
                end
            end

            // Response phase
            if (wr_resp_pending_r && M_BREADY) begin
                wr_resp_pending_r <= 1'b0;
            end
        end
    end

    //==============================================================
    // L0 파라미터 + hex 로딩 + DRAM 적재
    //==============================================================
    localparam integer L0_CI         = 3;
    localparam integer L0_CO         = 16;
    localparam integer L0_H          = 256;
    localparam integer L0_W          = 256;
    localparam integer L0_OFM_H_HALF = L0_H / 2;
    localparam integer L0_OFM_W_HALF = L0_W / 2;
    localparam integer L0_W_BLOCKS   = L0_W / 4;     // = 64
    localparam integer L0_IFM_BYTES  = L0_H * L0_W * L0_CI;

    parameter IFM_HEX  = "C:/yolohw/sim/inout_data_sw/log_feamap/CONV00_input.hex";
    parameter WGT_HEX  = "C:/yolohw/sim/inout_data_sw/log_param/CONV00_param_weight.hex";
    parameter BIAS_HEX = "C:/yolohw/sim/inout_data_sw/log_param/CONV00_param_biases.hex";
    parameter OFM_HEX  = "C:/yolohw/sim/inout_data_sw/log_feamap/CONV00_output.hex";

    // DRAM 적재 base 주소 (32-bit word index)
    localparam integer BASE_WGT_BYTE   = 32'h0000_0000;
    localparam integer BASE_BIAS_BYTE  = 32'h0001_0000;     // weight + 64 KB
    localparam integer BASE_IFM_BYTE   = 32'h0010_0000;     // 1 MB offset
    localparam integer BASE_OFM_BYTE   = 32'h0020_0000;     // 2 MB offset

    reg [7:0]  ifm_raw  [0:L0_IFM_BYTES-1];
    reg [7:0]  wgt_raw  [0:L0_CO*L0_CI*9-1];
    reg [15:0] bias_raw [0:L0_CO-1];

    integer f, ci, k, row, col_b, col_l, ch_l, b;
    integer base_word;

    function [7:0] ifm_byte;
        input integer c;
        input integer h;
        input integer w;
        integer idx;
        begin
            if (c < 0 || c >= L0_CI || h < 0 || h >= L0_H || w < 0 || w >= L0_W) ifm_byte = 8'd0;
            else begin
                idx = c * L0_H * L0_W + h * L0_W + w;
                ifm_byte = ifm_raw[idx];
            end
        end
    endfunction

    function [7:0] wgt_byte;
        input integer ff;
        input integer cc;
        input integer kk;
        begin
            if (cc >= L0_CI) wgt_byte = 8'd0;
            else             wgt_byte = wgt_raw[ff * 27 + cc * 9 + kk];
        end
    endfunction

    //==============================================================
    // 초기화
    //==============================================================
    integer dram_idx;
    reg [127:0] wgt_slot_128;
    reg [127:0] ifm_entry_128;

    initial begin
        // Reset
        rstn = 1'b0;

        // DRAM clear
        for (dram_idx = 0; dram_idx < DRAM_WORDS; dram_idx = dram_idx + 1)
            dram[dram_idx] = 32'd0;

        // 1) Hex 파일 로드
        $display("[TB] Loading IFM  : %s", IFM_HEX);   $readmemh(IFM_HEX,  ifm_raw);
        $display("[TB] Loading WGT  : %s", WGT_HEX);   $readmemh(WGT_HEX,  wgt_raw);
        $display("[TB] Loading BIAS : %s", BIAS_HEX);  $readmemh(BIAS_HEX, bias_raw);

        // 2) Weight → DRAM (16-byte padded slot, 4 slot per filter, 4 word per slot)
        //    filter f, slot s ∈ {0..3}, word w ∈ {0..3}
        //    slot 0..2 = ci 0..2 kernel (9 byte each, 7 byte pad)
        //    slot 3   = ch3 zero pad
        for (f = 0; f < L0_CO; f = f + 1) begin
            for (ci = 0; ci < 4; ci = ci + 1) begin
                wgt_slot_128 = 128'd0;
                for (k = 0; k < 9; k = k + 1) begin
                    wgt_slot_128[k*8 +: 8] = wgt_byte(f, ci, k);
                end
                // 4 × 32-bit word per slot
                base_word = (BASE_WGT_BYTE >> 2) + (f * 16) + (ci * 4);
                dram[base_word + 0] = wgt_slot_128[31: 0];
                dram[base_word + 1] = wgt_slot_128[63:32];
                dram[base_word + 2] = wgt_slot_128[95:64];
                dram[base_word + 3] = wgt_slot_128[127:96];
            end
        end
        $display("[TB] Weight loaded to DRAM @ 0x%08x (%0d words)", BASE_WGT_BYTE, L0_CO*16);

        // 3) Bias → DRAM (32-bit per filter, sign-extended)
        for (f = 0; f < L0_CO; f = f + 1) begin
            base_word = (BASE_BIAS_BYTE >> 2) + f;
            dram[base_word] = { {16{bias_raw[f][15]}}, bias_raw[f] };
        end
        $display("[TB] Bias   loaded to DRAM @ 0x%08x (%0d words)", BASE_BIAS_BYTE, L0_CO);

        // 4) IFM → DRAM (128-bit entry × H × W_blocks × ci_groups)
        //    For L0: ci_groups = 1. entry layout: 4 col × 4 ch packed.
        //    DRAM order: row-major (entries within row first, then row++).
        //    각 entry → 4 × 32-bit word.
        for (row = 0; row < L0_H; row = row + 1) begin
            for (col_b = 0; col_b < L0_W_BLOCKS; col_b = col_b + 1) begin
                ifm_entry_128 = 128'd0;
                for (col_l = 0; col_l < 4; col_l = col_l + 1) begin
                    for (ch_l = 0; ch_l < 4; ch_l = ch_l + 1) begin
                        b = col_l * 4 + ch_l;
                        ifm_entry_128[b*8 +: 8] = ifm_byte(ch_l, row, col_b * 4 + col_l);
                    end
                end
                base_word = (BASE_IFM_BYTE >> 2) + (row * L0_W_BLOCKS + col_b) * 4;
                dram[base_word + 0] = ifm_entry_128[31: 0];
                dram[base_word + 1] = ifm_entry_128[63:32];
                dram[base_word + 2] = ifm_entry_128[95:64];
                dram[base_word + 3] = ifm_entry_128[127:96];
            end
        end
        $display("[TB] IFM    loaded to DRAM @ 0x%08x (%0d words)",
                 BASE_IFM_BYTE, L0_H * L0_W_BLOCKS * 4);

        // 5) Set ctrl_reg base addresses (force AXI slave registers)
        //    ctrl_reg1 = dram_wgt_base
        //    ctrl_reg2 = dram_ifm_base
        //    ctrl_reg3 = dram_ofm_base
        force u_yolo_engine.u_axi.slv_reg1 = BASE_WGT_BYTE;
        force u_yolo_engine.u_axi.slv_reg2 = BASE_IFM_BYTE;
        force u_yolo_engine.u_axi.slv_reg3 = BASE_OFM_BYTE;

        // 6) Release reset
        #(8*CLK_PERIOD) rstn = 1'b1;
        #(4*CLK_PERIOD);

        // 7) Assert ap_start
        @(posedge clk);
        force u_yolo_engine.u_axi.slv_reg0 = 32'd1;
        $display("[TB] ap_start asserted @ t=%0t", $time);

        @(posedge clk);
        @(posedge clk);
        force u_yolo_engine.u_axi.slv_reg0 = 32'd0;

        // 8) Wait network_done (or timeout)
        $display("[TB] Waiting for network_done...");
        wait (network_done == 1'b1);
        $display("[TB] network_done received @ t=%0t", $time);

        // 9) (TB 일괄 검증 phase) — OFM 비교 로직은 추후 확장
        $display("[TB] DRAM OFM region first 16 words:");
        for (dram_idx = 0; dram_idx < 16; dram_idx = dram_idx + 1) begin
            $display("    OFM[0x%08x] = 0x%08x",
                     BASE_OFM_BYTE + dram_idx*4,
                     dram[(BASE_OFM_BYTE >> 2) + dram_idx]);
        end

        #(10*CLK_PERIOD) $finish;
    end

    //--------------------------------------------------------------
    // Watchdog
    //--------------------------------------------------------------
    initial begin
        #(200_000_000 * CLK_PERIOD);
        $display("[TB] *** TIMEOUT ***");
        $finish;
    end

    //--------------------------------------------------------------
    // Progress display
    //--------------------------------------------------------------
    reg [3:0] prev_top_state;
    always @(posedge clk) begin
        if (rstn) begin
            if (u_yolo_engine.top_state !== prev_top_state) begin
                $display("[TB][%0t] layer=%0d  top_state %0d→%0d",
                         $time,
                         u_yolo_engine.layer_idx,
                         prev_top_state,
                         u_yolo_engine.top_state);
                prev_top_state <= u_yolo_engine.top_state;
            end
        end else begin
            prev_top_state <= 4'd15;
        end
    end

`endif  // !FPGA

endmodule
