# IP_PACKAGING 진단 및 비트스트림 전 수정 가이드

> 2026-05-24 분석. `IP_PACKAGING.md`(설계 가이드)의 **현재 상태 점검 + 수정 절차** 보조 문서.
> 모든 Vivado 작업은 **Windows Vivado 2025.1** (SMB `Z:` 드라이브)에서 수행.
> Linux `/data/2026 CAU/...` == Windows `Z:/2026 CAU/...` 동일 파일.

---

## 1. 진단 요약 (왜 지금은 비트스트림이 안 되는가)

| # | 심각도 | 문제 | 근거 |
|---|--------|------|------|
| 1 | 🔴 Blocking | yolo_engine IP 가 내부 BRAM/DSP IP 를 **서브코어로 포함하지 않음** → OOC 합성에서 `module 'dpram_2048x128_tdp' not found` | `system_yolo_engine_0_3_synth_1/runme.log`, packaged `ipshared/709b/src/` 에 .v 만 존재 |
| 2 | 🔴 Blocking | 이 프로젝트의 BRAM IP 세트가 **구버전 RTL 기준** — 현재 RTL 이 쓰는 `dpram_4096x72`, `spram_2560x32` 가 **없음** | RTL 인스턴스 추적 vs `fpga_yolohw.srcs/sources_1/ip/` 등록 IP 비교 |
| 3 | 🔴 Blocking | 리패키징에 필요한 `component.xml`(IP repo)이 **공유폴더에 없음** | `find component.xml` 결과 없음. `.xpr` IPRepoPath 깨짐 |
| 4 | 🟡 Warning | `network_done_led` / `o_network_done` 외부 포트가 NULL source → **GND 묶임** (완료 LED 안 켜짐) | `vivado.log` BD 41-166 |
| 5 | 🟢 무해 | `M_ARLOCK/M_AWLOCK` 2-bit vs SmartConnect 1-bit width mismatch | AXI4 lock 은 1-bit, 하위비트만 연결 = 정상 |
| 6 | 🟢 Info | 모든 경로가 타 PC(`C:/Users/trump`, `.Xil`=`CJH-laptop`) 하드코딩 | → 본 작업에서 .tcl 2개 수정 완료 |

### 합성에 실제 필요한 IP 코어 (RTL top-down 추적 결과)

| IP | 인스턴스 | 비고 |
|----|----------|------|
| `xbip_dsp48_macro_0` | `mul.v:53` (×144) | DSP48 곱셈기 |
| `dpram_4096x72` | `gbuff_param.v:68` | weight buffer (write72/read288) |
| `spram_2560x32` | `gbuff_param.v:86` | bias/shift buffer |
| `dpram_2048x128_tdp` | `ifm_line_buf.v:171` (×4) | IFM line buffer |
| `dpram_65536x32` | `yolo_engine.v:1693` | OFM buffer (※ gen_bram 주석은 '구'로 표기하나 실제 인스턴스됨) |

> 재패키징 스크립트는 안전하게 `gen_bram_ips.tcl` 의 **BRAM 7종 전부 + xbip = 8종**을 서브코어로 포함합니다. 과포함은 자원 0 (미인스턴스 시 합성 제외), 누락만 치명적이기 때문입니다.

---

## 2. 수정 절차

### STEP A — 경로 수정 (✅ 완료)

- `update_ip_and_build.tcl`, `repackage_only.tcl` 의 경로를 `Z:/2026 CAU/.../IP_PACKAGING/...` 로 변경 완료.
- IP repo 위치 = `Z:/2026 CAU/AIX2026/git/Yolo_Accelerator/yolohw/fpga/IP_PACKAGING/yolo_engine_ip` (STEP B 에서 생성).

### STEP B — yolo_engine IP 재패키징 (서브코어 포함) · 최초 1회

**방법 1 (권장, 안정적): TCL 스크립트**

Windows Vivado 2025.1 TCL 콘솔에서:
```tcl
source {Z:/2026 CAU/AIX2026/git/Yolo_Accelerator/yolohw/fpga/IP_PACKAGING/package_yolo_engine_ip.tcl}
```
→ `IP_PACKAGING/yolo_engine_ip/component.xml` 생성. 스크립트 메시지로 오류 유무 확인.

**방법 2 (GUI 대안): Create and Package New IP**

1. 새 RTL 프로젝트 생성 (part `xc7a100tcsg324-1`), `yolohw/src/*.v` 19개 추가, top = `yolo_engine`.
2. IP Catalog 에서 BRAM/DSP IP 생성 — `source gen_bram_ips.tcl` + `xbip_dsp48_macro_0.xci` import.
3. `Tools > Create and Package New IP > Package your current project`,
   - 패키지 위치 = `Z:/.../IP_PACKAGING/yolo_engine_ip`
   - Vendor `xilinx.com` / Library `user` / Name `yolo_engine` / Version `1.0`
4. **Ports and Interfaces** 탭에서 `S_AXI`(AXI4-Lite Slave), `M`(AXI4 Master), `clk`/`rstn` 연관이 올바른지 확인.
5. **File Groups** 에 BRAM/DSP IP 가 subcore 로 잡혔는지 확인 → `Review and Package` → `Package IP`.

### STEP C — 시스템 통합 + 비트스트림

```tcl
cd {Z:/2026 CAU/AIX2026/git/Yolo_Accelerator/yolohw/fpga/IP_PACKAGING/fpga_yolohw}
source update_ip_and_build.tcl
```
이 스크립트가: ① RTL→IP repo 복사 ② 리패키징 ③ IP catalog 갱신 + `upgrade_ip` + `validate_bd_design` + wrapper ④ 합성→구현→비트스트림.

> RTL 만 바꾼 이후의 반복 빌드는 STEP B 없이 이 스크립트만 다시 실행하면 됩니다 (IP repo 가 이미 존재).

### STEP D — LED 포트 재연결 확인 (Warning #4)

`validate_bd_design` 후 BD 에서 `yolo_engine_0/network_done_led`, `/o_network_done` 핀이 외부 포트 `network_done_led_0`, `o_network_done_0` 로 **실제 연결**되었는지 확인.
- 현재 RTL `yolo_engine.v:115-116` 에 두 출력 포트가 존재하므로, 새 IP upgrade 후 이름 기준 자동 재연결되는 것이 정상.
- 만약 여전히 `Source ... NULL / grounded` 경고가 나오면 BD 에서 수동으로 핀→포트를 다시 그어주고 재검증.

---

## 3. 비트스트림 전 최종 체크리스트

- [ ] `package_yolo_engine_ip.tcl` 실행 → `yolo_engine_ip/component.xml` 생성, 에러 0
- [ ] IP File Groups 에 BRAM 4종(`dpram_4096x72`, `spram_2560x32`, `dpram_2048x128_tdp`, `dpram_65536x32`) + `xbip_dsp48_macro_0` subcore 포함 확인
- [ ] `user_define_h.v` 의 `` `define FPGA `` **활성**(주석 해제) 상태 — 합성용 (현재 활성 ✓)
- [ ] `update_ip_and_build.tcl` 의 4개 경로가 `Z:/...` 로 맞는지 확인
- [ ] `upgrade_ip` 후 `validate_bd_design` 경고에 BD 41-166(NULL source) **없음**
- [ ] `system_yolo_engine_0_3_synth_1` OOC 합성 성공 (`module not found` 0)
- [ ] `synth_1` Complete → `impl_1 write_bitstream` Complete
- [ ] 산출물: `fpga_yolohw.runs/impl_1/system_wrapper.bit`

---

## 4. 참고: 환경/버전

- Vivado **2025.1**, part `xc7a100tcsg324-1` (Nexys A7-100T)
- IP VLNV: `xilinx.com:user:yolo_engine:1.0`
- BD 내 인스턴스: `system_yolo_engine_0_3`
- 제약: `system_top.xdc` (UART C4/D4, LED H17/K15, BTNC N17) + MIG 자동 핀
