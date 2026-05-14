# AIX2026 베타트론 — 세션 핸드오프 문서

## 📍 현재 위치: **Phase 1 완료** (MicroBlaze 제외 RTL 합성 완료)

본 문서는 Claude Code 계정 변경 또는 세션 컨텍스트 손실 시 다음 세션이 이어 작업할 수 있도록 작성된 핸드오프 노트입니다. `CLAUDE.md` + `ARCHITECTURE.md` + `.claude/projects/c--AIX-Project/memory/` 의 메모리 파일들과 함께 읽으면 됩니다.

---

## 🗂️ 프로젝트 4-Phase 정의 (용어 통일)

| Phase | 내용 | 상태 |
|-------|------|------|
| **Phase 1** | **MicroBlaze 제외 RTL 합성 완료** (yolo_engine 단독 22-layer 자동 추론) | ✅ **완료** |
| Phase 2 | TB 일괄 검증 + 정확도 튜닝 (shift 실측, mAP 확인) | ⏳ 대기 |
| Phase 3 | MicroBlaze + UART + DDR2 통합 (Vivado block design + SDK firmware) | ⏳ 대기 |
| Phase 4 | 비트스트림 작성 + 보드 데모 + 측정 (fps/Energy/mAP) | ⏳ 대기 |

---

## ✅ Phase 1 완료 RTL — yolohw/src/ (19 활성 파일)

### 9차시 — 산술 building blocks
- `mul.v` / `mul_dual.v` — 8-bit signed multiplier (DSP48 추론)
- `add_tree_36in.v` — 36 입력 signed adder tree
- `mac_stack.v` — 36 mul × 4 spatial set → 4 partial sum
- `mac_kern.v` — mac_stack + 4 accumulator + 4 post_process → 한 cycle 4 픽셀
- `post_process.v` — bias + ReLU + shift + UINT8 clip

### 10차시 — 메모리 / 버퍼
- `gbuff_param.v` — weight 72/288 비대칭 + bias 32-bit single port
- `spram_wrapper.v` / `dpram_wrapper.v` — BRAM IP wrapper
- `yolohw/fpga/gen_bram_ips.tcl` — BMG IP 생성 스크립트 (dpram_4096x72, spram_2560x32, dpram_2048x128_tdp)

### 11차시 — 라인 버퍼 + Conv
- `ifm_line_buf.v` — 4 line cyclic buffer, 3×3 / 1×1 mode packing, row/col boundary padding, DMA write port
- `conv_top.v` — 자체 FSM (IDLE→LOAD→RUN→DRAIN→NEXT→DONE) + output stationary loop + BRAM 1-cycle latency 정렬

### 12차시 — Top integration
- `yolo_engine.v` — 22-layer FSM top 모듈 (14-state)
  - AXI4-Lite slave (`yolo_engine_axi.v`)
  - AXI master read (`axi_dma_rd.v`, BITS_TRANS=20) — IFM/Weight/Bias 멀티플렉싱
  - AXI master write (`axi_dma_wr.v`, OUT_BITS_TRANS=20) — OFM store
  - 4-word → 128-bit assembler (width adapter)
  - IFM DMA write cyclic line mapping
  - Per-layer DRAM offset 테이블 (L0~L20)
  - 5-way OFM dpram port mux (conv / pool / s1_pool / upsample / DMA store)
  - 22-layer parameter case table + layer-specific shift 1차 추정값
- `max_pool_unit.v` — stride-2 BRAM-aware FSM (i_total_in_words 20-bit)
- `max_pool_s1_unit.v` — stride-1 maxpool (L11 전용, 2×2 same-padding sliding window)
- `upsample_unit.v` — 2× nearest neighbor (L18 전용)

---

## 🧪 Phase 1 TB — yolohw/sim/ (5 활성 파일)

| TB | 검증 대상 | 비고 |
|----|----------|------|
| `conv_top_tb.v` | conv_top + mac_kern + gbuff_param + ifm_line_buf 통합 | L0 hex 적재 → row 0 OFM 비교 |
| `max_pool_unit_tb.v` | max_pool_unit (stride-2) | 합성 패턴 + SW reference 비교 |
| `max_pool_s1_unit_tb.v` | max_pool_s1_unit (L11) | 합성 패턴 + SW reference 비교 |
| `upsample_unit_tb.v` | upsample_unit (L18) | 합성 패턴 + SW reference 비교 |
| `yolo_engine_tb.v` | full integration (내장 4 MB DRAM 모델) | Phase 2 진입 시 layer offset 갱신 필요 |

**TB 실행 전제 조건**: `yolohw/src/user_define_h.v` 의 `` `define FPGA `` 줄을 시뮬레이션 시 주석 처리 (합성 시 활성화).

---

## ⏭️ Phase 2 — 남은 작업

### TB 일괄 검증 (사용자 직접 지시 시 진행)
- 블록 단위 TB 4 개 실행 → mismatch 발생 시 RTL 수정
- `yolo_engine_tb.v` 의 DRAM 적재 로직 + 비교 로직을 per-layer offset 에 맞춰 갱신
- L0 부터 22-layer 전체 OFM 골든 비교

### 정확도 튜닝
- **Shift 실측 적용**: layer table 의 13~16 1차 추정값을 `CONV*_param_scales.hex` 측정 후 정밀화
- **L0~L4 IFM sliding window**: 큰 layer 의 전체 row 검증을 위한 DMA reload 인터리브 추가 (선택)

### Software-side 책임 (별도 도구로 처리)
- **DRAM 사전 배치**: weight / bias / IFM 을 yolo_engine.v 의 layer offset table 에 정확히 매칭하여 적재
- **L19 concat**: L8 OFM 을 L18 OFM 직후 위치에 16384 word 복사

---

## ⏭️ Phase 3 — MicroBlaze 통합 (TB 통과 후)

- Vivado block design 에 MicroBlaze MCS + UART + DDR2 MIG + yolo_engine 통합
- SDK firmware: skeleton 의 `yolo_head` + NMS C 코드 재활용
- AXI bus: MicroBlaze ↔ yolo_engine (AXI-Lite slave) + 양쪽 ↔ DDR2 (AXI master 공유)

---

## ⏭️ Phase 4 — 보드 데모 + 측정

- 합성 + 비트스트림: `launch_runs synth_1 -jobs 4 ; launch_runs impl_1 -to_step write_bitstream -jobs 4`
- 100 장 테스트셋 mAP + fps + 전력 측정
- 점수 공식 적용: **Score = 10⁴ / Energy × ReLU(mAP − 0.2) × ReLU(fps − 5)**

---

## 📋 사용자 핵심 지시 (반드시 준수)

1. **TB 는 RTL 완성 후 일괄 검증** — 매 작업 단계마다 TB 만들지 말 것
2. **Placeholder 지양** — 핵심 모듈은 실제 동작 가능 구조로 구현
3. **점수 최적화 의식** — 144-MAC, 1×1 conv 의 mac_kern 재사용 등 점수 직결 선택
4. **한국어 존댓말**, **점진적 제안** (한 번에 한 변경 + 이유)
5. **CLAUDE.md 치명적 규칙 7 가지** 반드시 준수

---

## 🗂️ 디렉토리 구조 (Phase 1 완료 시점, 정리됨)

```
c:\AIX Project\
├── ARCHITECTURE.md          (네트워크 + 모듈 다이어그램)
├── CLAUDE.md                (작업 가이드 + 치명적 규칙)
├── HANDOFF.md               (본 문서)
├── skeleton/                (C 골든 레퍼런스, hex 파일 생성기)
├── 참고자료/                (사용자 자료)
└── yolohw/
    ├── fpga/                ★ Vivado 프로젝트 + BMG IP TCL
    ├── src/                 ★ 활성 RTL (19 파일)
    ├── sim/                 ★ 활성 TB (5 파일) + hex 데이터 폴더
    ├── src_backup/          📦 legacy RTL (cnn_ctrl, max_pool, axi_dma_ctrl 등)
    ├── sim_backup/          📦 legacy TB (구버전 *_tb.v 등)
    └── _archive/            📦 arxiv_screenshots, claude_web_legacy
```

---

## 🚀 다음 세션 시작 시 권장 첫 명령

```
@CLAUDE.md 와 @HANDOFF.md, @ARCHITECTURE.md 를 읽고
.claude/projects/c--AIX-Project/memory/project_current_state.md 확인 후
Phase 2 (TB 일괄 검증) 부터 진행해주세요.
```

또는 다른 단계를 명시:
```
Phase 3 (MicroBlaze 통합) Vivado block design 다이어그램 정리부터 시작해주세요.
```
