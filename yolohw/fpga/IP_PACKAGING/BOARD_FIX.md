# fpga_yolohw BD — Nexys A7-100T 보드 정합 수정 가이드

> impl `place_design` 실패 원인 = BD가 **보드파일 없이** 만들어져 MIG DDR2 핀배치 + 클럭 토폴로지가 Nexys A7-100T와 불일치.
> 원본 동작 디자인(`yolohw.tcl` → `design_1`)은 **Digilent 보드파일(`nexys4_ddr`) 기반**이라 핀/클럭이 자동으로 맞았음. → 같은 방식으로 정정.
> 모든 작업 Windows Vivado 2025.x GUI. yolo_engine IP·합성은 이미 성공이므로 **건드리지 않음**.

---

## 0. 현재 확정된 문제

| 항목 | 현재 (틀림) | 정답 (Nexys A7-100T) |
|---|---|---|
| MIG `ddr2 addr[3]` | C4 | **T1** |
| MIG `ddr2 we_n` | D4 | **N2** |
| MIG `ddr2 dq[0]` | A1 | **R7** |
| MIG DDR2 영역 | A~H 행 (엉뚱) | K~V 행 (뱅크 34/35) |
| clk_wiz 입력 | Differential (diff_clock_rtl) | **Single-ended 100MHz, E3** |
| UART rxd/txd | C4/D4 (MIG와 충돌) | C4/D4 (정상 — MIG만 비키면 됨) |

정답 핀 전체 = 대회 제공 `yolohw/fpga/NEXYS_A7_100T.xdc` 21~71행.

---

## 1. STEP 1 — Digilent 보드파일 설치 (1회)

Vivado 2025.x 에 Nexys A7-100T 보드 정의를 설치한다.
- **방법 A (XHub):** Vivado → `Tools > Vivado Store > Boards` → "Nexys A7-100T" 검색 → Install.
- **방법 B (수동):** Digilent `vivado-boards` (github.com/Digilent/vivado-boards) 의 `new/board_files/nexys-a7-100t/` 폴더를
  `<Vivado설치>/data/boards/board_files/` 에 복사.

설치 후 board part 이름 확인 (둘 중 설치된 것):
- `digilentinc.com:nexys-a7-100t:part0:1.x` (신규 명칭) 또는
- `digilentinc.com:nexys4_ddr:part0:1.x` (구 명칭 = 원본 design_1 이 쓴 것)

---

## 2. STEP 2 — fpga_yolohw 프로젝트에 board part 지정

```tcl
open_project {Z:/2026 CAU/AIX2026/git/Yolo_Accelerator/yolohw/fpga/IP_PACKAGING/fpga_yolohw/fpga_yolohw.xpr}
# 설치된 정확한 이름으로 (get_board_parts 로 확인)
get_board_parts *nexys*
set_property board_part digilentinc.com:nexys-a7-100t:part0:1.3 [current_project]
```

---

## 3. STEP 3 — MIG DDR2 핀배치 정정 (핵심)

`open_bd_design` 후 MIG(`mig_7series_0`)를 정정. **2가지 방법 중 택1.**

### 방법 A (권장, 가장 확실) — 보드 기반 재생성
1. BD에서 기존 `mig_7series_0` 우클릭 → Delete (그 전에 연결 메모: `axi_smc_1/M00_AXI`→MIG `S_AXI`, clk_wiz `clk_out1`→`sys_clk_i`, 리셋).
2. **Board 창**(Window > Board)에서 `DDR2 SDRAM` 인터페이스를 캔버스로 드래그 → MIG가 **보드 핀배치로 자동 생성**됨.
3. Run Connection Automation 으로 clk/reset 자동 연결, `S_AXI`는 `axi_smc_1/M00_AXI`에 수동 재연결.

### 방법 B (보드 DDR2 프리셋이 없을 때) — Fixed Pin Out 수동
1. `mig_7series_0` 더블클릭 → MIG wizard → Pin/Bank Selection → **Fixed Pin Out**.
2. `NEXYS_A7_100T.xdc` 21~71행의 핀을 각 DDR2 신호에 입력 (addr[3]=T1, we_n=N2, dq[0]=R7 …). MIG가 뱅크/바이트그룹 유효성 자동 검사.
3. 메모리 부품은 그대로 `MT47H64M16HR-25E`, 200MHz 유지.

> 어느 방법이든 완료 후 MIG xdc 에서 `ddr2_addr[3]`가 **T1**(C4 아님)인지 1회 확인.

---

## 4. STEP 4 — clk_wiz 단일 클럭(E3)으로 변경

1. `clk_wiz_1` 더블클릭 → Clocking Options →
   - **Primary input: Single ended clock capable pin** (현재 Differential).
   - Input freq = 100 MHz.
   - 출력 클럭(현재 `clk_out1` → MIG `sys_clk_i`)은 **주파수/개수 그대로 유지**.
2. BD 외부 포트 `diff_clock_rtl`(clk_p/clk_n) 삭제 → 단일 클럭 입력 포트 1개 생성 → `clk_wiz_1/clk_in1` 에 연결.
   - (보드파일 사용 시 Board 창의 `System Clock` 을 드래그하면 자동.)

---

## 5. STEP 5 — 제약 정리 (system_top.xdc)

`yolohw/fpga/IP_PACKAGING/fpga_yolohw/system_top.xdc`:
- **추가:** `set_property -dict { PACKAGE_PIN E3 IOSTANDARD LVCMOS33 } [get_ports { <단일클럭포트명> }]` + `create_clock -period 10.000 ...`
- **유지:** UART C4/D4, reset, LED. (MIG가 더 이상 C4/D4 안 쓰므로 충돌 해소)
- MIG/클럭을 Board 인터페이스로 연결했으면 핀이 자동 생성되니 중복 지정 주의.

> 참고: 원본은 `NEXYS_A7_100T.xdc` 를 그대로 제약으로 썼음. 포트명만 BD와 맞추면 그 파일 재사용도 가능.

---

## 6. STEP 6 — 재검증 + 비트스트림

```tcl
validate_bd_design
generate_target all [get_files system.bd]
make_wrapper -files [get_files system.bd] -top -force
reset_run synth_1
launch_runs synth_1 -jobs 8 ;  wait_on_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 8 ; wait_on_run impl_1
```

**성공 기준:** `place_design` DRC에 **BIVC-1(뱅크 전압 충돌) / LOC 충돌 없음**, `impl_1 = write_bitstream Complete!`, 산출물 `impl_1/system_wrapper.bit`.

---

## 체크리스트
- [ ] Digilent 보드파일 설치, `get_board_parts *nexys*` 로 이름 확인
- [ ] `set_property board_part ...` 적용
- [ ] MIG `ddr2_addr[3]` = T1, `we_n` = N2 (C4/D4 아님)
- [ ] clk_wiz 입력 Single-ended, diff_clock 포트 제거, E3 연결
- [ ] `validate_bd_design` 경고에 BIVC-1 / NET NULL source 없음
- [ ] `impl_1 write_bitstream Complete!`
