# ============================================================
#  ui_clk 도메인 복구 스크립트
#  증상: MIG 삭제/재추가로 mig/ui_clk 가 orphan 되고, 데이터측 AXI
#        (axi_smc_1, yolo_engine, axi_smc/aclk1)가 clk_out1(100MHz)에
#        잘못 붙어 MIG S_AXI(ui_clk 81.25MHz)와 클럭 불일치 → HDL gen 실패.
#  조치: 데이터측 클럭을 MIG ui_clk 로 재연결 + mmcm_locked->dcm_locked.
#  사용: BD 가 열린 Vivado Tcl 콘솔에서
#        source {Z:/2026 CAU/AIX2026/git/Yolo_Accelerator/yolohw/fpga/IP_PACKAGING/fpga_yolohw/fix_clock_domain.tcl}
# ============================================================

# BD 가 안 열려 있으면 연다
if {[catch {current_bd_design}]} {
    open_project [file normalize "[file dirname [info script]]/fpga_yolohw.xpr"]
    open_bd_design [get_files system.bd]
}

set uiclk [get_bd_pins mig_7series_0/ui_clk]

# 1) 데이터측 클럭: clk_out1 → ui_clk 로 이동
foreach p {axi_smc_1/aclk yolo_engine_0/clk axi_smc/aclk1 rst_mig_7series_0_50M/slowest_sync_clk} {
    set net [get_bd_nets -quiet -of_objects [get_bd_pins $p]]
    if {$net ne ""} { disconnect_bd_net $net [get_bd_pins $p] }
    connect_bd_net $uiclk [get_bd_pins $p]
    puts "  reconnected: $p -> mig ui_clk"
}

# 2) MIG mmcm_locked -> proc_sys_reset(ui_clk) dcm_locked
catch { connect_bd_net [get_bd_pins mig_7series_0/mmcm_locked] [get_bd_pins rst_mig_7series_0_50M/dcm_locked] }
puts "  connected: mig/mmcm_locked -> rst_mig_7series_0_50M/dcm_locked"

save_bd_design
puts "=== validate 시작 ==="
validate_bd_design
puts "=== 완료: 위 validate 결과에 ERROR/CRITICAL 없으면 generate_target 진행 ==="
