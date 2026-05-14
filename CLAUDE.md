# CLAUDE.md — YOLOv2 FPGA Accelerator (베타트론)

본 파일은 중앙대학교 AIX2026 Deep Learning Hardware 설계 경진대회(팀 베타트론)를 위한 Claude Code 의 최우선 작업 가이드입니다. 코드 작성 및 수정 전 반드시 아래 규칙을 숙지하십시오.

## 1. 프로젝트 기본 정보
- 타겟 보드: Nexys A7-100T (Xilinx Artix-7 XC7A100T)
- 최종 목표: 22-layer YOLOv2 모델 전체를 FPGA SoC 로 추론 (최소 5 fps, mAP > 0.2)
- 점수 공식: **Score = 10⁴ / Energy × ReLU(mAP − 0.2) × ReLU(fps − 5)**
- 상세 아키텍처 및 네트워크 구조는 `ARCHITECTURE.md` 참조

## 2. 📍 프로젝트 4-Phase (용어 통일)

| Phase | 내용 | 상태 |
|-------|------|------|
| **Phase 1** | MicroBlaze 제외 RTL 합성 완료 (yolo_engine 단독 22-layer 자동 추론) | ✅ 완료 |
| Phase 2 | TB 일괄 검증 + 정확도 튜닝 (shift 실측, mAP 확인) | 대기 |
| Phase 3 | MicroBlaze + UART + DDR2 통합 | 대기 |
| Phase 4 | 비트스트림 + 보드 데모 + 측정 | 대기 |

현재 진행 상태는 항상 `HANDOFF.md` 와 `.claude/projects/c--AIX-Project/memory/project_current_state.md` 를 확인.

## 3. 🚨 치명적 에러 방지 규칙 (반복 금지)

이전 작업에서 자주 발생한 에러들입니다. 절대 반복하지 마십시오.

1. **FPGA 매크로 토글**: `yolohw/src/user_define_h.v` 의 `` `define FPGA `` 는 **합성 시 활성화 / 시뮬레이션 시 주석 처리**. DSP48/BRAM IP 는 합성 시 반드시 명시적으로 인스턴스화 (a*b+c 추론 사용 금지).
2. **TB 경로 하드코딩**: TB 파일에 절대경로 `C:/yolohw/...` 가 하드코딩되어 있음. 파일 읽기 실패 시 `mklink /J C:\yolohw "C:\AIX Project\yolohw"` 로 정션 생성 또는 경로 수정.
3. **Layer 11 특수 처리**: MaxPool **stride=1**. 다른 maxpool 과 동일하게 처리하면 크기 깨짐. 별도 모듈 `max_pool_s1_unit.v` 사용 (이미 작성됨).
4. **연산 모듈 추가 금지 (Route/Upsample/1×1 Conv)**:
   - Route/Upsample: RTL 연산 모듈 새로 만들지 말고, 컨트롤러(FSM) 의 메모리 주소 제어(DMA) 로만 해결. (단 L18 upsample 만 `upsample_unit.v` 로 전용 모듈화됨 — 2×2 byte 복제가 단순한 DMA 패턴이라 모듈화가 더 효율적이라 판단)
   - 1×1 Conv: 기존 mac_kern (3×3 용) 재사용. `ifm_line_buf` 의 1×1 mode + `conv_top` 의 acc_len 조정만으로 처리.
5. **SystemVerilog 구문 금지**: `fork`, `join_any`, `let` 등은 Vivado plain Verilog 합성에서 실패. `while` 폴링 루프 또는 plain Verilog 로 대체.
6. **디스크 용량 초과 방지**: Vivado 시뮬레이션 시 `log_all_signals` 옵션 반드시 OFF. `.xilwvdat` 파일 폭증 방지.
7. **Bias 부호 확장**: 16-bit hex bias 를 32-bit SPRAM 에 적재 시 단순 zero-extend 아닌 **sign-extend** (`{ {16{bias[15]}}, bias }`).

## 4. 핵심 설계 규칙

- **데이터 표현**: NCHW (CHW byte order), C 레퍼런스와 100% 동일.
- **MAC 파이프라인 latency**: 마지막 vld_i 부터 output_valid 까지 정확히 11 cycle.
- **128-bit 정렬**: 3×3 conv 의 곱셈은 software hex 생성 시점에 0 padding 으로 16 배수 정렬.
- **Descaling 결과**: float 복원 아닌 **0~255 uint8 클리핑**.
- **레이어 파라미터**: `yolo_engine.v` 의 22-layer case table 에 정의. FSM 이 layer_idx 로 참조.
- **MAC 개수**: 144 (= 36 mul × 4 spatial set). 강의자료 + 점수 마진 확보를 위한 선택.
- **DRAM 메모리 맵** (`yolo_engine.v` Phase 1 기준):
  - `ctrl_reg1` = dram_wgt_base (weights + bias 영역)
  - `ctrl_reg2` = dram_ifm_base (input image, L0 IFM)
  - `ctrl_reg3` = dram_ofm_base (모든 layer OFM, per-layer offset 적용)

## 5. 활성 파일 구조 (Phase 1 완료 시점)

```
yolohw/src/    — 활성 RTL (19 파일, 합성 가능)
yolohw/sim/    — 활성 TB (5 파일) + hex 데이터 폴더
yolohw/fpga/   — Vivado 프로젝트 + BMG IP TCL
```

legacy 파일은 `yolohw/src_backup/`, `yolohw/sim_backup/`, `yolohw/_archive/` 에 보존.
**현재 활성 RTL 만 합성 대상**. legacy 파일은 참조용.

## 6. 시뮬레이션 및 빌드 명령어

- **C 골든 레퍼런스 hex 재생성**: `cd skeleton\bin` → `script-wins-aix2024-test-one-quantized.cmd`
- **Vivado 프로젝트 재생성**: `yolohw/fpga/` 에서 `source yolohw.tcl` → `source gen_bram_ips.tcl`
- **합성 + 비트스트림**: `launch_runs synth_1 -jobs 4` → `launch_runs impl_1 -to_step write_bitstream -jobs 4`

## 7. Claude 행동 원칙

1. **수정 전 파일 전체 읽기**: Edit/Write 전에 해당 모듈의 .v 파일을 Read 도구로 확인. 수정된 코드는 스니펫 아닌 전체 파일로 제공.
2. **한국어 존댓말**: 설명은 한국어 존댓말. 코드 내 주석은 한국어/영어 혼용 가능.
3. **점진적 제안**: 한 번에 한 변경 + 이유 명시. 큰 구조 변경 시 사용자 확인.
4. **신호 / 포트 동기화**: `yolo_engine.v` / `user_define_h.v` / 관련 TB 를 일관성 있게 동시 갱신.
5. **TB 는 마지막에 일괄 검증** — 사용자가 명시적으로 TB phase 진입을 지시할 때까지 매 작업마다 TB 만들지 말 것.
6. **Placeholder 지양** — "별도 phase" 라는 핑계로 핵심 모듈을 placeholder 로 두지 말 것. 합성 가능한 실제 동작 구조로 구현.
7. **점수 최적화 의식** — 144-MAC 유지, 1×1 conv 의 mac_kern 재사용, Energy 절감 직결 선택.
