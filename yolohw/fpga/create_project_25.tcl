#*****************************************************************************************
# AIX2026 베타트론 - Vivado 2025.x 프로젝트 재생성 스크립트
#
# 목적: 2021.2 기반 구 프로젝트(IP locked)를 버리고, 현재 yolohw/src/ 구성으로
#       깨끗한 새 프로젝트를 생성한다. (Phase 1/2 — yolo_engine 단독 합성)
#
# 사용법 (Windows Vivado 2025.x Tcl Console):
#   set fpga_dir "Z:/2026 CAU/AIX2026/git/Yolo_Accelerator/yolohw/fpga"
#   source $fpga_dir/create_project_25.tcl
#
#   ※ fpga_dir 를 미리 set 하지 않으면 스크립트가 자동으로 경로를 추정한다.
#
# 동작:
#   1) xc7a100tcsg324-1 (Nexys A7-100T) 로 새 프로젝트 생성
#   2) yolohw/src/*.v 전체를 design source 로 추가 (*_wip.v 제외)
#   3) 합성에서만 FPGA 매크로 활성화 (verilog_define FPGA=1) — 시뮬 파일은 그대로
#   4) NEXYS_A7_100T.xdc 제약 추가
#   5) top = yolo_engine 설정
#   6) gen_bram_ips.tcl 로 BRAM IP 를 현재 버전 기준으로 재생성
#*****************************************************************************************

# --- 폴더 경로 결정: fpga_dir 가 set 돼 있으면 그것을, 아니면 자동 추정 ---------
if { [info exists fpga_dir] } {
    set origin_dir [file normalize $fpga_dir]
} else {
    set origin_dir [file dirname [file normalize [info script]]]
}
puts "origin_dir = $origin_dir"

# gen_bram_ips.tcl 이 실제로 있는지 먼저 확인 (없으면 즉시 명확한 에러)
if { ![file isfile $origin_dir/gen_bram_ips.tcl] } {
    error "gen_bram_ips.tcl 을 $origin_dir 에서 못 찾음. 콘솔에서 'set fpga_dir <fpga 폴더 절대경로>' 후 다시 실행하세요."
}

set proj_name  "vivado_yolohw"
set part       "xc7a100tcsg324-1"

# 기존 동명 프로젝트가 있으면 덮어쓰기 (-force)
create_project $proj_name $origin_dir/$proj_name -part $part -force

# 보드 지정 (없어도 무방 — 실패해도 진행)
catch { set_property board_part digilentinc.com:nexys4_ddr:part0:1.1 [current_project] }

#--- RTL 소스 추가 (WIP 파일 제외) ---------------------------------------------
set src_files [glob -nocomplain $origin_dir/../src/*.v]
set src_files [lsearch -all -inline -not -glob $src_files *_wip.v]
add_files -norecurse $src_files

#--- 합성 전용 FPGA 매크로 (시뮬레이션 파일 수정 없이 FPGA 경로 활성화) ----------
# CLAUDE.md 규칙 #1: FPGA 매크로는 합성 시 ON, 시뮬레이션 시 OFF.
# 파일의 `define FPGA 는 주석 처리된 상태로 두고, 합성 fileset 에만 define 주입.
set_property verilog_define {FPGA=1} [get_filesets sources_1]

#--- include 검색 경로 (user_define_h.v / define.v 가 src 에 있음) ---------------
# `include "user_define_h.v" 등을 찾으려면 src 폴더가 include path 에 있어야 함.
# 합성(sources_1) · 시뮬(sim_1) 양쪽에 등록.
set src_inc [file normalize $origin_dir/../src]
set_property include_dirs [list $src_inc] [get_filesets sources_1]
catch { set_property include_dirs [list $src_inc] [get_filesets sim_1] }

#--- 제약 파일 ----------------------------------------------------------------
# 경로에 공백("2026 CAU")이 있으므로 [list] 로 감싸 단일 요소로 전달
add_files -fileset constrs_1 -norecurse [list $origin_dir/NEXYS_A7_100T.xdc]

#--- Top 모듈 -----------------------------------------------------------------
set_property top yolo_engine [current_fileset]
update_compile_order -fileset sources_1

#--- BRAM IP 재생성 (dpram_4096x72 / spram_2560x32 / dpram_2048x128_tdp 등) -----
source $origin_dir/gen_bram_ips.tcl

puts "============================================================"
puts "  $proj_name 프로젝트 생성 완료 (top = yolo_engine)"
puts "  위치: $origin_dir/$proj_name"
puts "  다음 단계:"
puts "    launch_runs synth_1 -jobs 4"
puts "    wait_on_run synth_1"
puts "============================================================"
