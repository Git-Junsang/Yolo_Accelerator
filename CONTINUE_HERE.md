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
| ~~뱅크: cur_pool_ifm_fi_byte_r + line_buf lb_*_r~~ | ❌ **역효과(−1.847), 되돌림.** RTL fanout 수정은 placement 악화 → 접음. **A만 = −0.175 가 최선** |

## 핵심 진단 (왜 뱅크인가)
- 워스트 = `conv_phase_r`/`pool_phase_r` **fanout(24804) + route 68%** (logic 깊이 아님!)
- **B(look-ahead 파이프라인)는 부적합** — logic용이라 효과 없고 lah2 조합 더 깊어 악화. **접음.**
- **정답 = 뱅크**: phase 기반 `cur_*` 신호를 레지스터로 → fanout 분산. **값·latency 동일(conv/pool 중 안정) = mAP 안전.**
- whack-a-mole: A로 conv경로(−0.183→−0.094) 잡으니 pool경로(−0.175) 드러남 → 뱅크로 둘 다 공략 중.

## 바로 할 일 (RTL 접음 → impl 로 −0.175 closing)
현재 A만 적용 = **WNS −0.175 @81.25** (TNS −0.603, 거의 닫힘). 워스트는 route/fanout이라
**impl(배치)** 로 공략 (RTL fanout 수정은 뱅크·B 모두 역효과 확인됨 → ⚠️ 하지 말 것):
1. **impl 전략+시드** (Windows Vivado Tcl):
   ```tcl
   current_project fpga_yolohw
   set_property strategy Performance_Explore [get_runs impl_1]
   reset_run impl_1
   launch_runs impl_1 -to_step write_bitstream -jobs 8 ; wait_on_run impl_1
   open_run impl_1 ; report_timing_summary
   ```
   안 되면 다른 전략(Performance_ExtraTimingOpt / RefinePlacement) 또는 시드 변경 반복.
2. **floorplan**: conv + dma 로직만(BRAM 제외, BRAM 96% 포화) Pblock 으로 근접 배치.
3. 양수 → **81.25MHz working bit 완성**. (이후 100MHz 도메인 전환은 HANDOFF 참조)

> ⚠️ 핵심 교훈: 워스트가 route/fanout(logic 깊이 아님)이라 **RTL 로 fanout 건드리면 placement 악화**.
>   누산기/bias/dma(logic 깊이)는 RTL 로 성공했지만, 이 잔여 −0.175 는 impl/floorplan 영역.

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
