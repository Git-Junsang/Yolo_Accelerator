# AIX2026 베타트론 — 세션 핸드오프 문서

## 2026-05-14 기준 RTL **Phase 5 완료** (MicroBlaze 제외 22-layer RTL 완성)

본 문서는 Claude Code 계정 변경 시 컨텍스트 손실에 대비한 핸드오프 노트입니다. 다음 세션은 이 문서 + `CLAUDE.md` + `.claude/projects/c--AIX-Project/memory/` 의 메모리 파일들을 읽고 이어서 작업할 수 있습니다.

---

## ✅ 완료된 RTL (yolohw/src/, 합성 가능 구조)

### 9차시 — 산술 building blocks
- `mul.v` / `mul_dual.v` — 8-bit signed multiplier (DSP48 추론)
- `add_tree_36in.v` — 36 입력 signed adder tree
- `mac_stack.v` — 36 mul × 4 spatial set → 4 partial sum
- `mac_kern.v` — mac_stack + 4 accumulator + 4 post_process → 한 cycle 4 픽셀
- `post_process.v` — bias + ReLU + shift + UINT8 clip

### 10차시 — 메모리 / 버퍼
- `gbuff_param.v` — weight (72/288 비대칭) + bias (32-bit single port)
- `spram_wrapper.v` / `dpram_wrapper.v` — BRAM IP wrapper
- `yolohw/fpga/gen_bram_ips.tcl` — BMG IP 생성 스크립트 (dpram_4096x72, spram_2560x32, dpram_2048x128_tdp 등)

### 11차시 — 라인 버퍼 + Conv
- `ifm_line_buf.v` — Phase 4:
  - 4 × dpram_2048x128_tdp (True Dual Port)
  - cyclic row mapping (i_rb 기반 base_line + ln_y mod 4)
  - column 정렬 offset mux (0..3)
  - row/col boundary padding
  - 3×3 mode 36-byte packing + 1×1 mode 4-byte packing
  - DMA write port (line + addr)
- `conv_top.v` — 자체 FSM (IDLE→LOAD→RUN→DRAIN→NEXT→DONE) + output stationary loop + BRAM latency 정렬

### 12차시 — Top integration (Phase 5 완료)
- `yolo_engine.v` — **Phase 5** top 모듈:
  - AXI4-Lite slave (`yolo_engine_axi.v`)
  - AXI master read (`axi_dma_rd.v`, BITS_TRANS=20) — IFM/Weight/Bias 멀티플렉싱
  - AXI master write (`axi_dma_wr.v`, OUT_BITS_TRANS=20) — OFM store
  - 4-word → 128-bit assembler (width adapter)
  - IFM DMA write cyclic line mapping
  - **Per-layer DRAM offset 테이블** (L0..L20)
  - **14-state top FSM** + s1_pool/upsample/route 분기
  - **5-way OFM dpram port mux** (conv/pool/s1_pool/upsample/DMA store)
  - 22-layer parameter case table + layer-specific shift
- `max_pool_unit.v` — stride-2 BRAM-aware FSM (i_total_in_words 20-bit)
- `max_pool_s1_unit.v` — **NEW** stride-1 maxpool (L11 전용, 2×2 same-padding)
- `upsample_unit.v` — **NEW** 2× nearest neighbor (L18 전용)

---

## ✅ Phase 5 에서 완료된 항목

| 항목 | 상태 |
|------|------|
| Layer 11 stride-1 maxpool | ✅ max_pool_s1_unit.v |
| Upsample (L18) | ✅ upsample_unit.v |
| Route (L16/19) FSM 처리 | ✅ ST_INIT 에서 skip (software 가 DRAM concat 사전 처리) |
| axi_dma_rd BITS_TRANS 확장 | ✅ 18 → 20 (1M word = 4MB max) |
| axi_dma_wr OUT_BITS_TRANS 확장 | ✅ 13 → 20 |
| Per-layer DRAM offset | ✅ L0..L20 명시 |
| Pool total_in_r 폭 확장 | ✅ 18 → 20 bit |

---

## ⚠️ 남은 작업 (사용자 직접 지시 시)

### 최종 단계 — TB 일괄 검증
- `yolohw/sim/yolo_engine_tb.v` (Phase 4 시점 작성) 가 4 MB behavioral DRAM 모델 보유
- Phase 5 변경에 따라 DRAM 적재 로직 + 비교 로직을 layer offset 에 맞춰 갱신 필요
- L0 부터 시작하여 각 layer 의 OFM 골든 비교

### Software-side 책임
- **DRAM 사전 배치**: weight/bias/IFM 을 Phase 5 의 layer offset table 에 정확히 매칭
- **L19 concat**: L8 OFM 을 L18 OFM 직후에 채움 (16384 word 복사)
- **Shift 실측 갱신**: layer table 의 13~16 추정값 → scales.hex 로 측정 후 적용

### MicroBlaze + UART + DDR2 (별도 phase)
- 본 RTL 은 MicroBlaze 없이 자동 추론 가능 (ap_start → network_done)
- MicroBlaze 는 ctrl_reg1/2/3 설정 + ap_start trigger + 결과 후처리만 담당

### 선택 사항 (현재 동작은 가능, 최적화)
- IFM DMA sliding window — 큰 layer (L0..L4) 의 전체 row 검증을 원할 때
- OFM dpram 확장 또는 streaming-out — L0 conv OFM 262K word vs dpram 65K 한계

---

## 📋 사용자 핵심 지시 (반드시 준수)

1. **TB 는 RTL 완성 후 일괄 검증** — 매 작업 단계마다 TB 만들지 말 것
2. **Placeholder 지양** — 핵심 모듈은 실제 동작 가능 구조로 구현
3. **점수 최적화** — 144-MAC + 1×1 conv 의 3×3 재사용 등 점수 직결 선택
4. **한국어 존댓말**, **점진적 제안** (한 번에 한 변경 + 이유)
5. **CLAUDE.md 의 치명적 규칙** 7 가지 (FPGA 매크로, TB 경로, Layer 11, Route/Upsample 금지, SV 금지, 디스크, Bias sign-extend)

---

## 🗂️ 파일 구조

`yolohw/src/` — 22 RTL 파일
`yolohw/sim/` — TB (Phase 4 호환 yolo_engine_tb.v 보유)
`yolohw/fpga/` — Vivado 프로젝트 + BMG IP TCL
`yolohw/src_backup/` — deprecated 파일 (예전 Tier 1 스캐폴드)
`skeleton/bin/` — C 골든 레퍼런스 + hex 파일
`skeleton/bin/script-wins-aix2024-test-one-quantized.cmd` — hex 재생성

---

## 🚀 다음 세션 시작 시 권장 첫 명령

```
@CLAUDE.md 를 읽고, @HANDOFF.md 와 .claude/projects/c--AIX-Project/memory/ 의 메모리 파일들을 확인한 후, project_current_state.md 의 "다음 세션 시작 시 첫 작업" 항목부터 진행해주세요.
```

또는 구체적으로:
```
yolohw/src/yolo_engine.v 를 읽고, L11 stride-1 maxpool 모듈 (max_pool_s1_unit.v) 을 신규 작성하여 통합해주세요.
```
