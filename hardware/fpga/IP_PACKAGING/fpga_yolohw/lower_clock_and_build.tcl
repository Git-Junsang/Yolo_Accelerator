# ============================================================
#  lower_clock_and_build.tcl   (Windows Vivado 2025 TCL 콘솔)
# ------------------------------------------------------------
#  목적: yolo 가 물린 MIG ui_clk(clk_pll_i_1)=81.25MHz 를 낮춰
#        타이밍을 "깨끗이"(WNS 양수) 닫고 동작 비트스트림을 만든다.
#        (A-only RTL 기준 WNS −0.175@81.25 → 클럭 인하로 양수)
#
#  배경(왜 MIG 인가):
#    - yolo_engine_0/clk + axi_smc_1/aclk + axi_smc/aclk1 이 전부 MIG ui_clk
#      "단일 도메인" → ui_clk 만 늦추면 재배선·새 CDC 없이 일관되게 느려진다.
#    - ui_clk[MHz] = (1e6 / TimePeriod_ps) / 4   (PHY 4:1)
#        3077 → 81.250 (현재)   | period 12.308ns
#        3125 → 80.000          | 12.500ns  (공격적, 여유 작음)
#        3200 → 78.125          | 12.800ns  (권장: 여유 ~+0.3ns, fps −3.8%)
#        3300 → 75.758          | 13.200ns  (안전)
#        3333 → 75.000          | 13.333ns  (가장 안전, 메모리 300MHz=정석값)
#    - DDR2(MT47H64M16HR-25E, 정격 400MHz)는 정격 이하라 늦추는 방향 안전
#      (DLL 최소 ~125MHz 한참 위).
#
#  ★ 중요: 디스크의 마지막 impl 은 "뱅크 역효과(−1.847)" 잔재다. RTL 은 A-only 로
#     되돌려 커밋됐으므로, 이 스크립트는 update_ip_and_build.tcl 을 재사용해
#     A-only RTL 로 IP 를 "재패키징"한 뒤 빌드한다. (안 그러면 −1.847 에서 시작)
#
#  ▶▶ MIG 재설정은 스크립트(prj 편집) 시도 + GUI 폴백 2-경로다.
#     빌드(40분) 낭비 방지를 위해, 빌드 후 routed 리포트 Clock Summary 의
#     clk_pll_i_1 주파수가 실제로 바뀌었는지 반드시 확인할 것.
#     ※ MIG 7-series 는 set_property 로 재설정 불가. prj 편집이 안 먹으면
#        아래 GUI 절차로 바꾼 뒤 update_ip_and_build.tcl 만 돌리면 된다.
#
#     [GUI 절차 — 가장 확실]
#       1) open BD (system.bd) → mig_7series_0 더블클릭 (Re-customize IP)
#       2) Controller Options 페이지의 "Time Period (ps)" 를 3077 → $TARGET_TIMEPERIOD
#          (또는 "Memory Device Interface Speed" 한 단계 느리게). MIG 가 유효값 검증.
#       3) Finish → Generate Output Products
#       4) source update_ip_and_build.tcl   (A-only 재패키징 + 합성 + impl + bit)
#
#  실행: source {Z:/2026 CAU/AIX2026/git/Yolo_Accelerator/yolohw/fpga/IP_PACKAGING/fpga_yolohw/lower_clock_and_build.tcl}
# ============================================================

# ─── 사용자 조정 파라미터 ──────────────────────────────────
set TARGET_TIMEPERIOD 3200   ;# ps. 권장 3200(78.125MHz). 안 닫히면 3300/3333.
# ───────────────────────────────────────────────────────────

set SCRIPT_DIR [file normalize [file dirname [info script]]]
set XPR        "$SCRIPT_DIR/fpga_yolohw.xpr"
set BOARD_PRJ  "$SCRIPT_DIR/fpga_yolohw.srcs/sources_1/bd/system/ip/system_mig_7series_0_2/board.prj"
set GEN_PRJ    "$SCRIPT_DIR/fpga_yolohw.gen/sources_1/bd/system/ip/system_mig_7series_0_2/system_mig_7series_0_2/mig.prj"

set ui_mhz [expr {1.0e6 / $TARGET_TIMEPERIOD / 4.0}]
puts "=================================================="
puts "  TARGET TimePeriod = $TARGET_TIMEPERIOD ps"
puts "  => memory [format %.3f [expr {1.0e6/$TARGET_TIMEPERIOD}]] MHz, ui_clk [format %.3f $ui_mhz] MHz"
puts "=================================================="

# ─── helper: prj 의 <TimePeriod> 치환 ──────────────────────
proc patch_timeperiod {path val} {
    if {![file exists $path]} { puts "  (없음) $path"; return 0 }
    set fh [open $path r]; set txt [read $fh]; close $fh
    if {![regexp {<TimePeriod>([0-9]+)</TimePeriod>} $txt -> old]} {
        puts "  (TimePeriod 패턴 없음) $path"; return 0
    }
    regsub -all {<TimePeriod>[0-9]+</TimePeriod>} $txt "<TimePeriod>$val</TimePeriod>" txt
    set fh [open $path w]; puts -nonewline $fh $txt; close $fh
    puts "  PATCHED $old -> $val : $path"; return 1
}

puts "\n=== STEP A: MIG prj TimePeriod 편집 (best-effort) ==="
patch_timeperiod $BOARD_PRJ $TARGET_TIMEPERIOD
patch_timeperiod $GEN_PRJ   $TARGET_TIMEPERIOD

puts "\n=== STEP B: MIG IP 재생성 시도 ==="
# ※ 단일 파일 인자는 [list] 로 감싸지 말 것 (공백 경로가 {} 포함 문자열로 변해 파일못찾음).
#   맨 변수 $XPR 는 Tcl 변수치환이 공백으로 단어분리되지 않아 안전.
if {[llength [get_projects -quiet]] == 0} {
    open_project $XPR
} else {
    puts "  (이미 열린 프로젝트 사용: [current_project])"
}
set MIG [get_ips -quiet -filter {IPDEF =~ *mig_7series*}]
if {[llength $MIG] == 0} { set MIG [get_ips -quiet system_mig_7series_0_2] }
puts "  MIG IP = $MIG"
set freq_before 0
catch { set freq_before [get_property CONFIG.FREQ_HZ $MIG] }
puts "  (before) FREQ_HZ = $freq_before"
if {[llength $MIG] > 0} {
    catch { reset_target -quiet all $MIG }
    catch { generate_target all $MIG }
}
set freq_after 0
catch { set freq_after [get_property CONFIG.FREQ_HZ $MIG] }
puts "  (after)  FREQ_HZ = $freq_after   (목표 [expr {int($ui_mhz*1e6)}] Hz)"

# ─── 게이트: MIG 가 prj 편집을 안 받았으면(여전히 80MHz 초과) 빌드 중단 ───
if {$freq_after > 80000000} {
    puts "\n=================================================="
    puts "  ▶ MIG ui_clk 이 안 바뀜 (여전히 [format %.3f [expr {$freq_after/1e6}]] MHz)."
    puts "    MIG 7-series 는 prj 편집/generate 로는 재설정 안 되는 경우가 많음."
    puts "    → 빌드 중단. 아래 GUI 절차로 바꾼 뒤 update_ip_and_build.tcl 만 실행:"
    puts "      1) Flow Navigator > Open Block Design (system.bd)"
    puts "      2) mig_7series_0 더블클릭 (Re-customize IP)"
    puts "      3) Controller Options 의 Time Period (ps): 3077 -> $TARGET_TIMEPERIOD  (OK)"
    puts "      4) Generate Output Products (Force up-to-date)"
    puts "      5) source {$SCRIPT_DIR/update_ip_and_build.tcl}"
    puts "      6) open_run impl_1; report_timing_summary  로 WNS 확인"
    puts "=================================================="
    return
}
puts "  >> MIG ui_clk 변경 확인됨. 빌드 진행."
# 프로젝트는 닫는다 (update_ip_and_build 가 자체적으로 ipx::open_core 부터 시작)
close_project

puts "\n=== STEP C: A-only RTL 재패키징 + 합성 + impl + 비트스트림 ==="
source [file join $SCRIPT_DIR update_ip_and_build.tcl]

puts "\n=== STEP D: 타이밍 요약 ==="
if {[get_property STATUS [get_runs impl_1]] eq "write_bitstream Complete!"} {
    open_run impl_1
    report_timing_summary -file "$SCRIPT_DIR/timing_summary_lowclock.rpt"
    set wns [get_property STATS.WNS [get_runs impl_1]]
    set tns [get_property STATS.TNS [get_runs impl_1]]
    puts "=================================================="
    puts "  WNS = $wns ns   TNS = $tns ns   (목표: WNS > 0)"
    puts "  Clock Summary 에서 clk_pll_i_1 주파수가 [format %.3f $ui_mhz] MHz 인지 확인!"
    puts "  bit: fpga_yolohw.runs/impl_1/system_wrapper.bit"
    puts "=================================================="
} else {
    puts "  impl 미완료 — STEP B 의 FREQ_HZ 확인/ GUI 절차 필요할 수 있음."
}
