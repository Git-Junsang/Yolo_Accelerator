# ============================================================
#  RTL 수정 후 IP 리패키징만 (비트스트림 X)
#  사용법: Windows Vivado 2025.1 TCL 콘솔에서 (반드시 source 로 실행)
#      source {Z:/2026 CAU/AIX2026/git/Yolo_Accelerator/yolohw/fpga/IP_PACKAGING/fpga_yolohw/repackage_only.tcl}
#  (Linux code-server 의 /data/2026 CAU/... 와 동일 파일을 SMB Z: 로 접근)
# ============================================================

# 경로: 스크립트 위치 기준 자동 계산. (선행: package_yolo_engine_ip.tcl 로 IP 생성)
set SCRIPT_DIR       [file normalize [file dirname [info script]]]
set IP_PACK_PROJECT  [file normalize "$SCRIPT_DIR/../yolo_engine_ip/yolo_engine_ip.xpr"]
set SYSTEM_PROJECT   "$SCRIPT_DIR/fpga_yolohw.xpr"
set IP_REPO_PATH     [file normalize "$SCRIPT_DIR/../yolo_engine_ip"]
set BD_YOLO_IP_INST  "system_yolo_engine_0_3"

# STEP 1: 리패키징
catch {close_project -quiet}
open_project $IP_PACK_PROJECT
ipx::open_core $IP_REPO_PATH/component.xml
ipx::merge_project_changes files [ipx::current_core]
ipx::merge_project_changes ports [ipx::current_core]
set_property core_revision [expr {[get_property core_revision [ipx::current_core]] + 1}] [ipx::current_core]
ipx::update_checksums [ipx::current_core]
ipx::save_core [ipx::current_core]
ipx::unload_core [ipx::current_core]
close_project
puts " >> IP 리패키징 완료"

# STEP 2: 시스템 프로젝트에서 IP 갱신
open_project $SYSTEM_PROJECT
set_property IP_REPO_PATHS $IP_REPO_PATH [current_project]
update_ip_catalog -rebuild
open_bd_design [get_files system.bd]
upgrade_ip [get_ips $BD_YOLO_IP_INST] -quiet
validate_bd_design
generate_target all [get_files system.bd]
close_bd_design [current_bd_design]
make_wrapper -files [get_files system.bd] -top -force

puts " >> IP 업데이트 + 검증 완료. 비트스트림은 수동으로 실행하세요."
