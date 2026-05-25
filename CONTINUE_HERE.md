# 다른 PC에서 이어가기 (2026-05-25 기준)

> 메모리(.claude)는 PC 전용이라 pull 안 됨. 이 문서 + `HANDOFF_WINDOWS.md`로 이어가세요.

## 현재 작업: yolo_engine 81.25MHz 타이밍 닫기
- 현재 WNS = **−0.175ns @81.25MHz** (거의 닫힘, TNS −0.603 = 소수 endpoint만)
- 클럭은 MIG ui_clk **81.25MHz 고정** (100MHz는 도메인 전환 별도 = 나중)

## RTL 상태 (yolohw/src/)
| 수정 | 상태 |
|------|------|
| 누산기(conv_top row_off) + bias흡수(mac_kern) + dma파이프라인(yolo_engine addr_ofm_byte_r) | ✅ 커밋됨(85cceefc) + 1회 빌드됨 |
| **A: cur_w_half_r** (yolo_engine) | ✅ 적용+빌드(−0.183→−0.175) |
| **뱅크: cur_pool_ifm_fi_byte_r + line_buf 입력 lb_*_r** (yolo_engine) | ✅ 적용, **빌드 대기** ← 여기부터 |

## 핵심 진단 (왜 뱅크인가)
- 워스트 = `conv_phase_r`/`pool_phase_r` **fanout(24804) + route 68%** (logic 깊이 아님!)
- **B(look-ahead 파이프라인)는 부적합** — logic용이라 효과 없고 lah2 조합 더 깊어 악화. **접음.**
- **정답 = 뱅크**: phase 기반 `cur_*` 신호를 레지스터로 → fanout 분산. **값·latency 동일(conv/pool 중 안정) = mAP 안전.**
- whack-a-mole: A로 conv경로(−0.183→−0.094) 잡으니 pool경로(−0.175) 드러남 → 뱅크로 둘 다 공략 중.

## 바로 할 일 (순서)
1. **TB 검증**: `l13_verify_tb` (또는 l0/l13) — line_buf 입력 바꿨으니 OFM 일치 확인 (값-동일이라 PASS 예상)
2. **빌드**: Windows Vivado Tcl Console
   ```tcl
   source {Z:/2026 CAU/AIX2026/git/Yolo_Accelerator/yolohw/fpga/IP_PACKAGING/fpga_yolohw/update_ip_and_build.tcl}
   ```
   (New Project 뜨면 `current_project fpga_yolohw` 로 잡고 `get_runs` 확인)
3. **WNS 확인**: `open_run impl_1; report_timing_summary`
   - **양수 → 81.25MHz working bit 완성** 🎉
   - 음수 → 새 phase 워스트도 **같은 뱅크 방식**으로 (다 값-동일 안전)

## 환경 / 함정
- Vivado 2025(Windows). SoC 프로젝트: `Z:/.../yolohw/fpga/IP_PACKAGING/fpga_yolohw/fpga_yolohw.xpr`
- **New Project 함정**: source 스크립트 후 current_project가 New Project로 바뀜 → `current_project fpga_yolohw` + `get_runs` 로 impl_1 확인 필수
- **'C' 디렉토리 OOC 에러**: 경로 공백(`2026 CAU`) 탓, **비치명적**(synth/impl 완주). 무시.
- 모든 RTL 수정 **값-동일**(fps 불변). `yolohw/src/yolo_engine.v.bak` 백업 있음(커밋 제외).

## 진단 TB (신규, 커밋됨)
- `l0_diag_tb.v` (acc_len=1, col/row look-ahead), `l13_diag_tb.v` (acc_len=64, acc look-ahead) — conv 정렬 cycle trace. baseline PASS + 정렬 확정.

## 다음 큰 단계 (81.25 닫은 후)
- 100MHz 도메인 전환(MIG ui_clk 100MHz) → 보드 fps 실측 (시뮬 N은 dram model 비현실적이라 못 잼).
- 상세: `HANDOFF_WINDOWS.md`.
