# ============================================================
#  step-3 (개정): 클럭 분리 + DDR2_0 삭제 + LED 연결
#
#  비트스트림 실패 원인 진단(impl 로그):
#   A. [Timing 38-469] IDELAYCTRL REFCLK=100MHz 인데 200MHz 필요
#      → MIG clk_ref_i 에 별도 200MHz 공급해야 함 (IDELAY 경로 타이밍 위반의 주범)
#   B. [DRC RTRES-1] clk_wiz/clk_out1 백본 라우팅 실패 (비트젠 차단)
#      → clk_out1 이 'MIG sys_clk_i' 와 '패브릭(MicroBlaze 등)' 을 한 net 으로
#        공유해서 MIG 전용 클럭 라우팅을 못 함.
#
#  해결: MIG 의 두 입력 클럭을 패브릭 net 에서 떼어 clk_wiz 전용 출력으로 분리.
#    clk_out1 = 100MHz → 패브릭(MicroBlaze/UART/axi_smc 등)  [기존 유지]
#    clk_out2 = 100MHz → MIG sys_clk_i  (전용, 저fanout → 백본 OK)
#    clk_out3 = 200MHz → MIG clk_ref_i  (IDELAYCTRL 200MHz)
#    ui_clk(81.25MHz)  → axi_smc_1 / yolo / axi_smc.aclk1 (AXI 데이터측, 기존)
#
#  사용: BD 열린 Vivado Tcl 콘솔에서
#    source {Z:/2026 CAU/AIX2026/git/Yolo_Accelerator/yolohw/fpga/IP_PACKAGING/fpga_yolohw/fix_ports.tcl}
# ============================================================

if {[catch {current_bd_design}]} {
    open_project [file normalize "[file dirname [info script]]/fpga_yolohw.xpr"]
    open_bd_design [get_files system.bd]
}

# 1) clk_wiz 출력 3개 구성 (clk_out2=100, clk_out3=200)
set_property -dict [list \
    CONFIG.CLKOUT2_USED {true} CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {100.000} \
    CONFIG.CLKOUT3_USED {true} CONFIG.CLKOUT3_REQUESTED_OUT_FREQ {200.000} \
] [get_bd_cells clk_wiz_1]
puts "  clk_wiz_1: clk_out2=100MHz, clk_out3=200MHz 추가"

# 2) MIG sys_clk_i 를 패브릭 net 에서 분리 → clk_out2 (100MHz, 전용)
set n [get_bd_nets -quiet -of_objects [get_bd_pins mig_7series_0/sys_clk_i]]
if {$n ne ""} { disconnect_bd_net $n [get_bd_pins mig_7series_0/sys_clk_i] }
connect_bd_net [get_bd_pins clk_wiz_1/clk_out2] [get_bd_pins mig_7series_0/sys_clk_i]
puts "  mig/sys_clk_i -> clk_wiz/clk_out2 (100MHz 전용)"

# 3) MIG clk_ref_i 를 패브릭 net 에서 분리 → clk_out3 (200MHz)
set n [get_bd_nets -quiet -of_objects [get_bd_pins mig_7series_0/clk_ref_i]]
if {$n ne ""} { disconnect_bd_net $n [get_bd_pins mig_7series_0/clk_ref_i] }
connect_bd_net [get_bd_pins clk_wiz_1/clk_out3] [get_bd_pins mig_7series_0/clk_ref_i]
puts "  mig/clk_ref_i -> clk_wiz/clk_out3 (200MHz)"

# 4) 떠있는 DDR2_0 외부 인터페이스 포트 삭제
if {[llength [get_bd_intf_ports -quiet DDR2_0]]} {
    delete_bd_objs [get_bd_intf_ports DDR2_0]
    puts "  deleted dangling intf port: DDR2_0"
}

# 5) yolo LED 출력 → 외부 포트 연결
catch { connect_bd_net [get_bd_pins yolo_engine_0/o_network_done]   [get_bd_ports o_network_done_0] }
catch { connect_bd_net [get_bd_pins yolo_engine_0/network_done_led] [get_bd_ports network_done_led_0] }
puts "  connected yolo LED outputs"

save_bd_design
puts "=== validate ==="
validate_bd_design
puts "=== 끝: generate->wrapper->synth->impl 재실행. 이후 WNS(타이밍) 확인 ==="
