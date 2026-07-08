# ============================================================
#  yolo_engine IP 재패키징 (서브코어 BRAM/DSP 포함) — 최초 1회 실행용
#
#  목적:
#    기존 IP_PACKAGING/fpga_yolohw 의 yolo_engine IP 는 내부 BRAM/DSP IP 를
#    서브코어로 포함하지 않아 OOC 합성에서 'module dpram_2048x128_tdp not found'
#    로 실패한다. 이 스크립트는 현재 yolohw/src RTL + 필요한 IP 코어 8종을
#    하나의 IP 로 묶어 IP_PACKAGING/yolo_engine_ip 에 component.xml 을 생성한다.
#
#  실행 환경: Windows Vivado 2025.1 TCL 콘솔 (SMB Z: 드라이브 공유)
#    반드시 source 로 실행 (경로를 스크립트 위치 기준으로 자동 계산):
#      source {Z:/2026 CAU/AIX2026/git/Yolo_Accelerator/yolohw/fpga/IP_PACKAGING/package_yolo_engine_ip.tcl}
#
#  완료 후: update_ip_and_build.tcl 을 실행하면 시스템 프로젝트가 이 IP 를
#           catalog 에 잡고 upgrade_ip → validate → 합성/비트스트림을 진행한다.
# ============================================================

# 경로는 이 스크립트의 위치 기준 자동 계산 (폴더 이동/드라이브 문자 무관).
set IPPKG_DIR [file normalize [file dirname [info script]]]   ;# .../yolohw/fpga/IP_PACKAGING
set ROOT      [file normalize "$IPPKG_DIR/../../.."]           ;# 레포 루트 Yolo_Accelerator
set SRC_DIR   "$ROOT/yolohw/src"
set IP_REPO   "$IPPKG_DIR/yolo_engine_ip"
set WORK_PROJ "$IPPKG_DIR/_pack_work"
set PART      "xc7a100tcsg324-1"
set GEN_BRAM  "$ROOT/yolohw/fpga/gen_bram_ips.tcl"
set XBIP_XCI  "$IPPKG_DIR/fpga_yolohw/fpga_yolohw.srcs/sources_1/ip/xbip_dsp48_macro_0/xbip_dsp48_macro_0.xci"

puts "============================================"
puts " STEP 0: create temporary packaging project"
puts "============================================"
catch {close_project -quiet}
file delete -force $WORK_PROJ
create_project pack_tmp $WORK_PROJ -part $PART -force

puts "============================================"
puts " STEP 1: add RTL sources (yolohw/src, 19 .v files)"
puts "============================================"
# define.v 는 `include 대상이라 반드시 포함. spram_wrapper.v 는 미사용(dead)이나
# 파싱만 되고 elaborate 안 되므로 포함해도 무해.
add_files -norecurse [glob "$SRC_DIR/*.v"]

puts "============================================"
puts " STEP 2: create/import internal IP cores"
puts "============================================"
# 2-1) BRAM 7종 — 프로젝트 표준 스크립트 (dpram_4096x72, spram_2560x32,
#       dpram_2048x128_tdp, dpram_65536x32 + 호환용 3종)
source $GEN_BRAM
# 2-2) DSP48 곱셈기 (mul.v 가 인스턴스화) — 기존 검증된 .xci import
#      경로에 공백("2026 CAU")이 있어 [list] 로 감싸 단일 인자 전달
#      (안 감싸면 import_ip 가 files 인자를 리스트로 보고 공백에서 분리함)
import_ip [list $XBIP_XCI]

puts "============================================"
puts " STEP 3: generate IP output products + set top"
puts "============================================"
generate_target all [get_ips]
set_property top yolo_engine [current_fileset]
update_compile_order -fileset sources_1

puts "============================================"
puts " STEP 4: package IP (subcores auto-included)"
puts "============================================"
# -import_files: RTL + 서브코어 IP 를 IP_REPO 로 복사하여 자기완결 IP 구성
ipx::package_project -root_dir $IP_REPO -vendor xilinx.com -library user \
    -taxonomy /UserIP -import_files -set_current true -force

set core [ipx::current_core]
set_property name          yolo_engine        $core
set_property version       1.0                $core
set_property display_name  yolo_engine_v1_0   $core
set_property core_revision 1                  $core
ipx::merge_project_changes files $core
ipx::merge_project_changes ports $core
ipx::create_xgui_files $core
ipx::update_checksums $core
ipx::save_core $core
ipx::unload_core $core
close_project

puts "============================================"
puts " DONE: IP component.xml created"
puts "   $IP_REPO/component.xml"
puts ""
puts " Next steps:"
puts "   1) Verify S_AXI / M(AXI4 Master) bus interfaces and clk/rstn"
puts "      association in IP Packager GUI (recommended, once)."
puts "   2) source update_ip_and_build.tcl  to integrate + build bitstream."
puts "============================================"
