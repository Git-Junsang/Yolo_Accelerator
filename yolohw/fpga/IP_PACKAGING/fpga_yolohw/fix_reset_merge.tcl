# ============================================================
#  fix_reset_merge.tcl — 외부 리셋 포트 충돌(12-1411) 해결
#
#  증상: impl Design Initialization 에서
#    CRITICAL WARNING [Vivado 12-1411] reset_0_IBUF 와 reset_IBUF 가
#    같은 IOB(IOB_X0Y144) 를 다툼.
#
#  원인: 외부 리셋 포트가 2개(둘 다 ACTIVE_LOW 시스템 리셋):
#    - reset    -> reset_inv_0(NOT) -> clk_wiz_1/reset   (clk_wiz 전용)
#    - reset_0  -> rst_clk_wiz/ext_reset_in + mig/sys_rst + rst_mig/ext_reset_in
#    원래 같은 버튼에서 와야 하는데 포트가 둘이라 같은 핀 충돌.
#
#  조치: reset_inv_0/Op1 을 reset_0 에 연결해 단일 리셋으로 통합 후
#        중복 외부 포트 reset 삭제. (clk_wiz reset = NOT(reset_0),
#        reset_0 ACTIVE_LOW -> NOT -> active-high = clk_wiz reset 극성 일치)
#        RTL 변경 없음 -> 시뮬 재검증 불필요.
#
#  사용: BD 열린 Vivado Tcl 콘솔에서
#    source {Z:/2026 CAU/AIX2026/git/Yolo_Accelerator/yolohw/fpga/IP_PACKAGING/fpga_yolohw/fix_reset_merge.tcl}
# ============================================================

if {[catch {current_bd_design}]} {
    open_project [file normalize "[file dirname [info script]]/fpga_yolohw.xpr"]
    open_bd_design [get_files system.bd]
}

# 1) reset_inv_0/Op1 을 기존 net(reset_1)에서 분리
set n [get_bd_nets -quiet -of_objects [get_bd_pins reset_inv_0/Op1]]
if {$n ne ""} { disconnect_bd_net $n [get_bd_pins reset_inv_0/Op1] }

# 2) reset_0 포트에 연결 (clk_wiz reset 도 단일 리셋 reset_0 에서 파생)
connect_bd_net [get_bd_ports reset_0] [get_bd_pins reset_inv_0/Op1]
puts "  reset_inv_0/Op1 -> reset_0 (clk_wiz reset 단일화)"

# 3) 이제 댕글링된 중복 외부 포트 reset 삭제
if {[llength [get_bd_ports -quiet reset]]} {
    delete_bd_objs [get_bd_ports reset]
    puts "  deleted duplicate external port: reset"
}

save_bd_design
puts "=== validate ==="
validate_bd_design
puts "=== 끝: 깨끗하면 generate -> wrapper -> synth -> impl 재실행 ==="
