# ============================================================
#  RTL 수정 후 원클릭 리빌드 스크립트
#  사용법: Windows Vivado 2025.1 TCL 콘솔에서 (반드시 source 로 실행)
#      source {Z:/2026 CAU/AIX2026/git/Yolo_Accelerator/yolohw/fpga/IP_PACKAGING/fpga_yolohw/update_ip_and_build.tcl}
#  (Linux code-server 의 /data/2026 CAU/... 와 동일 파일을 SMB Z: 로 접근)
#  ※ 선행조건: package_yolo_engine_ip.tcl 로 yolo_engine_ip/component.xml 생성 완료
# ============================================================

# ---- 경로: 스크립트 위치 기준 자동 계산 (폴더 이동/드라이브 무관) ----
set SCRIPT_DIR    [file normalize [file dirname [info script]]]      ;# .../IP_PACKAGING/fpga_yolohw
set ROOT          [file normalize "$SCRIPT_DIR/../../../.."]          ;# 레포 루트
set IP_REPO_PATH  [file normalize "$SCRIPT_DIR/../yolo_engine_ip"]    ;# component.xml + src/
set SYSTEM_PROJECT   "$SCRIPT_DIR/fpga_yolohw.xpr"
set BD_YOLO_IP_INST  "system_yolo_engine_0_3"
set RTL_SRC_DIR      "$ROOT/yolohw/src"

# RTL 소스 파일 목록
set RTL_FILES {
    yolo_engine.v yolo_engine_axi.v conv_top.v post_process.v
    mac_kern.v mac_stack.v mul.v add_tree_36in.v
    axi_dma_rd.v axi_dma_wr.v ifm_line_buf.v dpram_wrapper.v
    gbuff_param.v max_pool_unit.v max_pool_s1_unit.v
    upsample_unit.v user_define_h.v
}

puts "============================================"
puts " STEP 0: RTL 소스 → IP Repo 복사"
puts "============================================"

foreach f $RTL_FILES {
    set src "$RTL_SRC_DIR/$f"
    set dst "$IP_REPO_PATH/src/$f"
    if {[file exists $src]} {
        file copy -force $src $dst
        puts "  COPIED: $f"
    } else {
        puts "  SKIP:   $f (not found in src)"
    }
}

puts "============================================"
puts " STEP 1: yolo_engine IP 리패키징"
puts "============================================"

# 1-1. 열린 프로젝트 있으면 닫기
catch {close_project -quiet}

# 1-2. component.xml 직접 로드 (별도 IP 패키징 프로젝트 불필요)
ipx::open_core $IP_REPO_PATH/component.xml

# 1-3. 리패키징 (소스파일 변경 자동 반영)
ipx::merge_project_changes files [ipx::current_core]
ipx::merge_project_changes ports [ipx::current_core]
set_property core_revision [expr {[get_property core_revision [ipx::current_core]] + 1}] [ipx::current_core]
ipx::update_checksums [ipx::current_core]
ipx::save_core [ipx::current_core]

puts " >> IP 리패키징 완료 (revision 증가)"

# 1-4. IP 코어 언로드
ipx::unload_core [ipx::current_core]

puts "============================================"
puts " STEP 2: fpga_yolohw 프로젝트 IP 업데이트"
puts "============================================"

# 2-1. 시스템 프로젝트 열기
open_project $SYSTEM_PROJECT

# 2-2. IP Repository 경로 설정 ([list] 로 감싸야 공백 경로가 안 쪼개짐)
set_property IP_REPO_PATHS [list $IP_REPO_PATH] [current_project]
update_ip_catalog -rebuild

# 2-3. Block Design 열기
open_bd_design [get_files system.bd]

# 2-4. 모든 locked IP 업그레이드
#  프로젝트는 Vivado 2025.1 로 생성됨. 2025.2 등 다른 버전에서 열면 microblaze/MIG/
#  smartconnect 등 표준 IP 까지 전부 잠기므로(BD 5-336), yolo_engine 만이 아니라
#  전체를 업그레이드해야 validate 가 통과한다. (버전 일치 시엔 no-op)
upgrade_ip -quiet [get_ips]

# 2-5. Block Design 검증
validate_bd_design

# 2-6. BD Output Products 재생성
generate_target all [get_files system.bd]

# 2-7. BD 닫기
close_bd_design [current_bd_design]

# 2-8. HDL Wrapper 재생성
make_wrapper -files [get_files system.bd] -top -force

puts "============================================"
puts " STEP 3: 합성 + 구현 + 비트스트림"
puts "============================================"

# 3-1. 합성
reset_runs synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1

if {[get_property STATUS [get_runs synth_1]] ne "synth_design Complete!"} {
    puts "ERROR: 합성 실패! Design Runs 탭에서 로그를 확인하세요."
    return
}
puts " >> 합성 완료"

# 3-2. 구현 + 비트스트림
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

if {[get_property STATUS [get_runs impl_1]] ne "write_bitstream Complete!"} {
    puts "ERROR: 구현/비트스트림 실패! Design Runs 탭에서 로그를 확인하세요."
    return
}

puts "============================================"
puts " 완료! 비트스트림 생성 성공"
puts " .bit 파일 위치:"
puts " fpga_yolohw/fpga_yolohw.runs/impl_1/system_wrapper.bit"
puts "============================================"
