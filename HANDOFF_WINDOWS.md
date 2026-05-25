# Yolo Accelerator — Windows Vivado 타이밍 작업 핸드오프

> 이 문서는 **Windows에서 실행되는 Claude Code**에게 현재 상황을 전달하기 위한 것입니다.
> 지금까지 RTL 작업은 Linux code-server에서 했고, Vivado(Windows)는 사람이 수동으로 돌렸습니다.
> 이제 Windows Claude가 **Vivado를 batch 모드로 직접 제어**해서 타이밍 클로징(특히 floorplan 시행착오)을 자동화하는 것이 목표입니다.

---

## 0. 당신(Windows Claude)이 할 일

- `vivado -mode batch -source <script>.tcl` 로 **impl 재실행 / floorplan(Pblock) / 타이밍 리포트**를 자동 반복
- 빌드 후 `*_timing_summary_routed.rpt` / `runme.log` 를 읽어 **WNS·워스트 경로** 파악
- floorplan 영역(Pblock)을 utilization·WNS 보고 **자동 튜닝** (사람이 GUI로 하던 시행착오를 대신)
- 빌드는 오래 걸리니(synth ~15분, impl ~15~20분) **background로 돌리고 결과를 읽는** 방식

**Vivado 경로 예시**: `D:/ProgramFiles/2025.2/Vivado/bin/vivado` (실제 경로 확인 필요)

---

## 1. 프로젝트 개요

- **목표**: 22-layer YOLOv2 를 FPGA SoC 로 추론. Nexys A7-100T (Xilinx Artix-7 **XC7A100T**)
- **점수 공식**: `Score = 10⁴ / Energy × ReLU(mAP − 0.2) × ReLU(fps − 5)`
  - **fps ≤ 5 또는 mAP ≤ 0.2 이면 점수 0** (게이트)
  - `fps = 동작주파수 / N` (N = 추론 총 cycle 수)
- **"100MHz 고정" 규칙은 문서에 없음** — 제출 체크리스트는 `@XXXMHz`(동작주파수 자유 명시). 81.25MHz도 합법. 단 fps가 클럭 비례라 100MHz가 점수 유리.

---

## 2. 환경 / 경로 (Windows 기준)

| 항목 | 경로 |
|------|------|
| **SoC 프로젝트 (비트스트림 타겟)** | `Z:/2026 CAU/AIX2026/git/Yolo_Accelerator/yolohw/fpga/IP_PACKAGING/fpga_yolohw/fpga_yolohw.xpr` |
| RTL 소스 | `Z:/.../yolohw/src/*.v` |
| 시뮬 전용 프로젝트 (엔진 단독) | `Z:/.../yolohw/fpga/vivado_yolohw/` (재생성: `yolohw/fpga/create_project_25.tcl`) |
| timing 리포트 | `.../fpga_yolohw/fpga_yolohw.runs/impl_1/system_wrapper_timing_summary_routed.rpt` |
| impl 로그 | `.../fpga_yolohw.runs/impl_1/runme.log` |
| RTL→IP 반영+빌드 스크립트 | `.../fpga_yolohw/update_ip_and_build.tcl` |
| BD fix 스크립트들 | `.../fpga_yolohw/fix_*.tcl` |

- **시뮬 검증은 Vivado 2025 사용** (2021은 X 처리 달라 chain ±1 LSB mismatch).
- yolo_engine RTL 은 **IP 로 패키징**되어 SoC 에 들어감. **RTL 을 바꾸면** `update_ip_and_build.tcl` 로 (src→IP repo 복사 → 재패키징 → synth → impl) 반영해야 함. 그냥 .v 만 바꾸면 빌드에 반영 안 됨.

---

## 3. 현재까지 한 일 (타이밍 최적화 이력)

이 설계는 **첫 implementation** 이라 100MHz 타이밍 클로징이 안 돼 있었음. yolo 로직 전체가 **MIG 가 만든 ui_clk = `clk_pll_i_1` ≈ 81.25MHz** 도메인에서 돈다 (아직 100MHz 도메인 아님).

**적용한 RTL 최적화 (전부 TB 패스, git commit `85cceefc`):**
1. `conv_top.v` — ifm_line_buf 주소 곱셈(`i_acc_cyc*i_w_blocks`)을 `row_off` **누산기**로 대체 (DSP 제거, 값·지연 동일)
2. `mac_kern.v` — `bias` 를 accumulator 첫 사이클에 흡수 → `post_process` 의 `(acc_result+bias)` 32-bit 덧셈(CARRY4) 제거
3. `yolo_engine.v` — `dma_wr_start_addr`(`addr_ofm_byte`) **2-stage 파이프라인** (conv 도는 동안 미리 계산 → latency 불변)
4. BD — 외부 reset 포트 2개(`reset`/`reset_0`) 충돌(12-1411) → `fix_reset_merge.tcl` 로 `reset_0` 단일화

**결과 WNS @81.25MHz: −2.614 → −0.183ns** (실패 endpoint 809 → 소수)

> 원칙: 모든 RTL 수정은 **값·latency 동일**(fps 불변)으로 함. 곱셈 주소 파이프라인은 "사용 전 여유 사이클이 있는 곳"에만 적용 (없으면 누산기). RTL 바꾸면 chain TB(l13/l20)로 mAP 직결 검증.

---

## 4. 현재 문제 (마지막 −0.183ns)

- **WNS −0.183ns @81.25MHz** (거의 닫힘, 1.5% 초과). `[Timing 38-282]` timing fail (비트는 나오지만 보드 오작동).
- **워스트 경로 2종:**
  1. `conv_phase_r → u_line_buf BRAM 주소(ADDRBWRADDR)` : −0.183ns, **route 68%**, 13단
  2. `pool_phase_r → dma_rd_start_addr(addr_pool_ifm 곱셈)` : −0.152ns
- **근본 원인**: Device view 확인 결과 **conv 로직(파랑)은 상단(X0Y3/X1Y3), line_buf BRAM(빨강)은 중하단(X0Y2/X1Y1~Y2)** 으로 멀리 떨어져 배선(route)이 8ns나 됨.

**부가 경고 (보드 전 정리 필요, 지금 빌드는 안 막음):**
- methodology `TIMING-2/4/6/7` : `clk_pll_i_1`(MIG ui_clk) ↔ `clk_wiz` 클럭 간 CDC 경고. `set_clock_groups -asynchronous` 로 정리.
- `[Common 17-1257] Failed to create directory 'C'` (OOC synth) : **비치명적, 무시.** 경로 공백(`Z:/2026 CAU`)으로 synth 시작 시 임시 디렉토리명이 `C`로 잘려 1회 ERROR. 하지만 dlmb/mig OOC runme.log 확인 결과 **"Synthesis finished with 0 errors" + dcp 생성 + impl 완주(−0.183)**. Design Runs 패널의 ERROR는 status 잔여 표시일 뿐 합성/impl 정상. 근본해결=프로젝트 경로 공백 제거(비권장, 위험).

---

## 5. 하고 싶은 것 (우선순위)

### A. 81.25MHz 닫기 (−0.183 → 양수) ← 지금 단계
route-dominated 경로라 **배치(placement)** 로 해결:
1. **impl 재시도** (시드 변경, 가장 빠름. −0.183은 작아서 재배치만으로 넘어갈 확률 높음):
   ```tcl
   open_project {Z:/2026 CAU/AIX2026/git/Yolo_Accelerator/yolohw/fpga/IP_PACKAGING/fpga_yolohw/fpga_yolohw.xpr}
   reset_run impl_1
   launch_runs impl_1 -to_step write_bitstream -jobs 8
   wait_on_run impl_1
   open_run impl_1
   report_timing_summary
   ```
2. 안 되면 **floorplan** — conv+line_buf 를 BRAM 영역에 모음:
   ```tcl
   create_pblock pblock_conv
   add_cells_to_pblock [get_pblocks pblock_conv] \
     [get_cells {system_i/yolo_engine_0/inst/u_conv system_i/yolo_engine_0/inst/u_line_buf}]
   resize_pblock [get_pblocks pblock_conv] -add {CLOCKREGION_X0Y1:CLOCKREGION_X1Y2}
   reset_run impl_1; launch_runs impl_1 -to_step write_bitstream -jobs 8; wait_on_run impl_1
   ```
   - Pblock 영역은 **넉넉히 크게 시작**(place 실패 방지) → utilization 70~85% 확인 → WNS 보고 좁혀가며 conv↔BRAM 모으기.
   - Pblock 크기는 **에너지와 무관**(빈 영역 전력 0). 너무 크면 "모으는 효과"만 약해짐.
   - utilization 확인: `report_utilization -pblocks [get_pblocks pblock_conv]`

### B. 100MHz 도메인 전환
- yolo 를 100MHz 도메인으로: MIG ui_clk 를 100MHz(메모리 200MHz, 2:1)로 재설정, **또는** yolo 를 `clk_wiz` 100MHz 출력에 물리고 MIG 와는 SmartConnect CDC.
- 예산 10ns (현 12.3ns 보다 −2.3ns 빡빡) → 워스트 폭증 예상.
- 이때 `set_clock_groups -asynchronous` 로 CDC 정리.

### C. 100MHz 타이밍 닫기
- 남은 곱셈 주소(전부 `index × byte` 패턴) 를 **값-동일** 파이프라인/누산으로:
  `addr_pool_ifm`(1837), `addr_wgt_fi`(1727), `addr_pool_ofm`(1840), rp 주소들(1854-1860).
- 주의: dma_rd 주소들은 인덱스 증가 **직후 사용**(여유 1사이클) → 2-stage 파이프라인 불가 → **누산기** 필요. 단 `fi_r` 갱신 지점이 12곳이라 동기화 까다로움.
- route-dominated 경로는 floorplan(A의 Pblock 재활용).

### D. 보드 fps 실측 (Phase 3/4)
- **시뮬로 N(추론 cycle) 측정 불가**: `sim_dram_model` 이 실제 DDR2 보다 수천 배 느린 비현실적 모델 (l0 단독이 sim 683M cycle). conv 만 5.7M 으로 확실, 나머지(DMA 오버헤드)는 보드 DDR2 대역폭에 좌우.
- MicroBlaze+DDR2 통합 → 보드에서 **N·fps 실측**이 "81.25 충분 / 100MHz 필수 / MAC 증설 필요" 를 확정.
- 참고: DSP 240개 중 144 사용 → 평가기준이 "240 DSP 최대 활용(dual mult 480)" 권장. fps 부족 시 **DSP dual(한 DSP 2 곱셈 packing)** 으로 conv 처리량 2배 카드 있음 (단 conv 가 병목일 때만 효과 — 보드 실측 후 판단).

---

## 6. 반복 함정 (꼭 주의)

1. **"New Project" 함정**: `source ...update_ip_and_build.tcl` 등 실행 후 `current_project` 가 `{New Project}` 로 바뀜. → `get_runs` 가 빈 값이면 `open_project {.../fpga_yolohw.xpr}` 또는 `current_project fpga_yolohw` 로 잡고, **`get_runs` 가 `synth_1 impl_1` 출력하는지 반드시 확인** 후 `set_property strategy` 등 실행.
2. **strategy 변경 주의**: 이전에 `Performance_ExtraTimingOpt` / `ExplorePostRoutePhysOpt` / `max_fanout=50` 모두 효과 없거나 역효과(−0.1→−1.6 악화). **전략은 logic 깊이/route 를 못 잡음 → RTL·floorplan 이 정공법.** 기본(`Vivado Implementation Defaults`)이 무난.
3. **38-282 timing fail** = 비트는 생성되지만 보드 오작동. 무시 금지.
4. **클럭은 아직 81.25 유지** — A 단계까진 클럭 안 바꿈. RTL/배치만. 100MHz 전환은 B.
5. **RTL 수정 = 값·latency 동일 필수** + chain TB(l13/l20) 재검증 (mAP 직결).
6. **OOC 'C' 디렉토리** 에러로 synth 막히면 경로 공백 문제 — `.xpr`/캐시 경로 확인 필요.

---

## 7. 당장의 액션 (요약)

1. `fpga_yolohw.xpr` 열기 → `get_runs` 로 `impl_1` 확인
2. **impl 재시도**부터 (5-A-1) → WNS 읽기
3. 양수면 → **81.25 working bit 완성** (현재 목표 달성)
4. 여전히 음수면 → **floorplan**(5-A-2), utilization·WNS 보며 영역 자동 튜닝
5. 닫히면 → B(100MHz 도메인) 검토

> 핵심 한 줄: **지금은 81.25MHz 에서 −0.183ns 를 닫는 게 목표. impl 재시도 → 안 되면 conv+line_buf floorplan. 그 다음 100MHz 도메인 전환 → 보드 fps 실측.**
