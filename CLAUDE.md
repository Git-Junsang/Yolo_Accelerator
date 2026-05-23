# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

본 파일은 중앙대학교 AIX2026 Deep Learning Hardware 설계 경진대회(팀 베타트론)를 위한 Claude Code 의 최우선 작업 가이드입니다. 코드 작성 및 수정 전 반드시 아래 규칙을 숙지하십시오.

---

## 1. 프로젝트 기본 정보

- 타겟 보드: Nexys A7-100T (Xilinx Artix-7 XC7A100T)
- 최종 목표: 22-layer YOLOv2 모델 전체를 FPGA SoC 로 추론 (최소 5 fps, mAP > 0.2)
- 점수 공식: **Score = 10⁴ / Energy × ReLU(mAP − 0.2) × ReLU(fps − 5)**
- 상세 아키텍처 및 네트워크 구조는 `ARCHITECTURE.md` 참조

---

## 2. 개발 환경 구성 (중요)

이 프로젝트는 **두 개의 실행 환경**이 혼재합니다.

| 작업 | 실행 환경 | 경로 |
|------|----------|------|
| **skeleton C 코드 빌드 / hex 생성** | **Linux code-server** (여기) | `/data/2026 CAU/AIX2026/git/Yolo_Accelerator/` |
| **Vivado 합성 / 시뮬레이션** | **Windows (Vivado GUI)** | `Z:\2026 CAU\AIX2026\git\Yolo_Accelerator\` (SMB Z 드라이브) |
| **RTL 파일 편집** | Linux code-server (여기) | 동일 파일을 양쪽에서 공유 |

- Linux ↔ Windows 는 **SMB 공유 (Z 드라이브 매핑)** 로 동일 파일시스템에 접근.
- Claude Code 는 **Linux code-server** 에서 실행되므로, 쉘 명령은 Linux 명령 사용.
- Vivado TCL 콘솔 명령은 Windows 에서 직접 실행 (Claude Code 에서 실행 불가).
- TB hex 데이터 경로가 Windows 절대경로로 하드코딩된 경우 Linux 경로로 수정 또는 symlink 생성.
- **시뮬레이션 검증은 Vivado 2025 사용** (필수). Vivado 2021 은 uninitialized memory(X) 처리가 2025 와 달라, chain 검증에서 동일 RTL/데이터인데도 ±1 LSB 비결정성(mismatch)이 발생함 (§4-8 참조). 2025 프로젝트 생성: `yolohw/fpga/create_project_25.tcl`.

---

## 3. 📍 프로젝트 4-Phase (용어 통일)

| Phase | 내용 | 상태 |
|-------|------|------|
| **Phase 1** | MicroBlaze 제외 RTL 합성 완료 (yolo_engine 단독 22-layer 자동 추론) | ✅ 완료 |
| **Phase 2** | TB 일괄 검증 + 정확도 튜닝 (shift 실측, mAP 확인) | ✅ 완료 |
| Phase 3 | MicroBlaze + UART + DDR2 통합 | 대기 |
| Phase 4 | 비트스트림 + 보드 데모 + 측정 | 대기 |

현재 진행 상태는 항상 `.claude/projects/c--AIX-Project/memory/project_current_state.md` 를 확인.

---

## 4. 🚨 치명적 에러 방지 규칙 (반복 금지)

이전 작업에서 자주 발생한 에러들입니다. 절대 반복하지 마십시오.

1. **FPGA 매크로 토글**: `yolohw/src/user_define_h.v` 의 `` `define FPGA `` 는 **합성 시 활성화 / 시뮬레이션 시 주석 처리**. DSP48/BRAM IP 는 합성 시 반드시 명시적으로 인스턴스화 (a*b+c 추론 사용 금지).
2. **TB 경로 하드코딩**: TB 파일에 절대경로 (예: `C:/yolohw/...`) 가 있을 수 있음. Linux 에서 시뮬레이션 시 `/data/2026 CAU/...` 경로로 수정. Windows Vivado 시뮬레이션 시에는 Z 드라이브 경로 또는 symlink 사용.
3. **Layer 11 특수 처리**: MaxPool **stride=1**. 다른 maxpool 과 동일하게 처리하면 크기 깨짐. 별도 모듈 `max_pool_s1_unit.v` 사용 (이미 작성됨).
4. **연산 모듈 추가 금지 (Route/Upsample/1×1 Conv)**:
   - Route/Upsample: RTL 연산 모듈 새로 만들지 말고, 컨트롤러(FSM) 의 메모리 주소 제어(DMA) 로만 해결. (단 L18 upsample 만 `upsample_unit.v` 로 전용 모듈화됨)
   - 1×1 Conv: 기존 mac_kern (3×3 용) 재사용. `ifm_line_buf` 의 1×1 mode + `conv_top` 의 acc_len 조정만으로 처리.
5. **SystemVerilog 구문 금지**: `fork`, `join_any`, `let` 등은 Vivado plain Verilog 합성에서 실패. `while` 폴링 루프 또는 plain Verilog 로 대체.
6. **디스크 용량 초과 방지**: Vivado 시뮬레이션 시 `log_all_signals` 옵션 반드시 OFF. `.xilwvdat` 파일 폭증 방지.
7. **Bias 부호 확장**: 16-bit hex bias 를 32-bit SPRAM 에 적재 시 단순 zero-extend 아닌 **sign-extend** (`{ {16{bias[15]}}, bias }`).
8. **sim 메모리 0 초기화 + Vivado 2025 검증**: sim behavioral 메모리(`dpram_wrapper`/`spram_wrapper`/`ifm_line_buf`/`gbuff_param` 의 `ifdef FPGA` else 영역의 reg 배열 + read latency reg)는 반드시 `initial` 로 0 초기화. 미초기화 시 chain 검증에서 시뮬레이터 버전(2021 vs 2025)마다 X 전파가 달라 ±1 LSB mismatch 발생 (RTL 버그 아님). 0 초기화는 실제 FPGA BRAM(전원 인가 시 0)과 일치하며, `initial` 은 sim 전용이라 합성/fps/Energy 에 영향 없음.

---

## 5. 핵심 설계 규칙

- **데이터 표현**: NCHW (CHW byte order), C 레퍼런스와 100% 동일.
- **MAC 파이프라인 latency**: 마지막 vld_i 부터 output_valid 까지 정확히 11 cycle.
- **128-bit 정렬**: 3×3 conv 의 곱셈은 software hex 생성 시점에 0 padding 으로 16 배수 정렬.
- **Descaling 결과**: float 복원 아닌 **0~255 uint8 클리핑**.
- **레이어 파라미터**: `yolo_engine.v` 의 22-layer case table 에 정의. FSM 이 layer_idx 로 참조.
- **MAC 개수**: 144 (= 36 mul × 4 spatial set).
- **DRAM 메모리 맵** (`yolo_engine.v` Phase 1 기준):
  - `ctrl_reg1` = dram_wgt_base (weights + bias 영역)
  - `ctrl_reg2` = dram_ifm_base (input image, L0 IFM)
  - `ctrl_reg3` = dram_ofm_base (모든 layer OFM, per-layer offset 적용)

---

## 6. 활성 파일 구조 (Phase 3 완료 시점)

```
yolohw/src/        — 활성 RTL (19 .v: yolo_engine + 17 서브모듈 + define.v stub)
yolohw/testbench/  — 활성 TB (l0~l20 verify + 블록 TB) + hex 데이터(inout_data_sw) + sim_dram_model
yolohw/sim/        — iverilog 컴파일 출력 전용 (.gitignore, 빌드 산출물)
yolohw/firmware/   — host.py (Host PC UART 클라이언트)
yolohw/fpga/       — Vivado 프로젝트(2025) + BMG IP TCL + Vitis firmware
skeleton/          — C 골든 레퍼런스 + 양자화 hex 생성기 (Linux에서 빌드)
documents/         — 강의자료 / 논문 / 참고 자료
.recycle_bin/      — 소프트 삭제 보관함 (.recycle_bin/REASON.md 참조)
```

**`yolohw/src/` 전부 합성 대상** — legacy 파일 없음. `define.v` 는 `mul.v` 참조용 include stub (실제 매크로는 `user_define_h.v`). 산술 multiplier 는 `mul.v` 단일 (mul_dual.v 등 없음).

---

## 7. 빌드 및 실행 명령어

### skeleton C 레퍼런스 빌드 (Linux code-server 에서 실행)

```bash
# 프로젝트 루트 기준
cd skeleton
make                    # ./bin/darknet 생성
cd bin/dataset
python make_list_cur.py # 테스트 이미지 경로 갱신 (최초 1회)
```

### 양자화 hex 파일 생성 (Linux code-server 에서 실행)

```bash
cd skeleton/bin
# 단일 이미지 추론 + hex 저장 (-save_params 플래그 주목)
./darknet detector test yolohw.names aix2024.cfg aix2024.weights \
  -thresh 0.24 test01.jpg -out_filename test01-det-quantized \
  -quantized -save_params

# 전체 테스트셋 mAP (양자화)
sh script-unix-aix2024-test-all-quantized.sh
```

생성된 hex 파일 위치: `skeleton/bin/log_param/`
- `CONV{NN}_param_weight.hex` — 8-bit 양자화 가중치
- `CONV{NN}_param_biases.hex` — 16-bit bias
- `CONV{NN}_param_scales.hex` — shift 스케일 (RTL shift 파라미터 결정에 사용)

### Vivado 관련 명령 (Windows Vivado TCL 콘솔에서 실행)

```tcl
# Vivado 프로젝트 재생성
source yolohw.tcl
source gen_bram_ips.tcl

# 합성 + 비트스트림
launch_runs synth_1 -jobs 4
launch_runs impl_1 -to_step write_bitstream -jobs 4
```

---

## 8. Claude 행동 원칙

1. **수정 전 파일 전체 읽기**: Edit/Write 전에 해당 모듈의 .v 파일을 Read 도구로 확인.
2. **한국어 존댓말**: 설명은 한국어 존댓말. 코드 내 주석은 한국어/영어 혼용 가능.
3. **점진적 제안**: 한 번에 한 변경 + 이유 명시. 큰 구조 변경 시 사용자 확인.
4. **신호 / 포트 동기화**: `yolo_engine.v` / `user_define_h.v` / 관련 TB 를 일관성 있게 동시 갱신.
5. **TB 는 마지막에 일괄 검증** — 사용자가 명시적으로 TB phase 진입을 지시할 때까지 매 작업마다 TB 만들지 말 것.
6. **Placeholder 지양** — "별도 phase" 라는 핑계로 핵심 모듈을 placeholder 로 두지 말 것. 합성 가능한 실제 동작 구조로 구현.
7. **점수 최적화 의식** — 144-MAC 유지, 1×1 conv 의 mac_kern 재사용, Energy 절감 직결 선택.
8. **환경 구분**: 쉘 명령은 Linux 기준으로 제시. Vivado TCL 명령은 Windows 에서 직접 실행해야 함을 명시.
