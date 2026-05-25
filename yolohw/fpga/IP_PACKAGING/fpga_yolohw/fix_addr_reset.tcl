# ============================================================
#  step-2: MIG AXI reset 연결 + DDR2 주소 할당
#  (fix_clock_domain.tcl 로 클럭 복구 후 실행)
#  증상: validate 에서
#    - 41-759 mig_7series_0/aresetn 미연결(0 tie-off)
#    - 41-1356 DDR2(memaddr)가 yolo_engine/M, microblaze/Data 에 미할당
#  사용: BD 열린 Vivado Tcl 콘솔에서
#    source {Z:/2026 CAU/AIX2026/git/Yolo_Accelerator/yolohw/fpga/IP_PACKAGING/fpga_yolohw/fix_addr_reset.tcl}
# ============================================================

if {[catch {current_bd_design}]} {
    open_project [file normalize "[file dirname [info script]]/fpga_yolohw.xpr"]
    open_bd_design [get_files system.bd]
}

# 1) MIG S_AXI reset (ui_clk 도메인) — peripheral_aresetn 에 연결
catch { connect_bd_net [get_bd_pins mig_7series_0/aresetn] \
                       [get_bd_pins rst_mig_7series_0_50M/peripheral_aresetn] }
puts "  connected: mig_7series_0/aresetn -> rst_mig_7series_0_50M/peripheral_aresetn"

# 2) 주소 자동 할당 (DDR2 -> microblaze/Data + yolo_engine/M, yolo S_AXI/uart -> microblaze)
assign_bd_address

puts "==================== ADDRESS MAP ===================="
# report_bd_address 는 일부 버전에서 미지원 → catch 로 감싸 흐름 안 끊기게
catch { report_bd_address -quiet } _rba
puts "====================================================="

save_bd_design
puts "=== validate ==="
validate_bd_design
puts "=== 끝: ERROR/CRITICAL 없으면 generate_target -> synth -> impl ==="
