#*****************************************************************************************
# AIX2026 베타트론 - BRAM IP 생성 스크립트
#
# Vivado Tcl Console 에서 "source ./gen_bram_ips.tcl" 로 실행.
#
# 사전 조건:
#   - yolohw.tcl 으로 프로젝트가 이미 생성·열려 있어야 함
#   - 또는 임의의 Vivado 프로젝트가 current 상태여야 함
#
# ========== 강의자료 경로 (현재 활성 — 144-MAC mac_kern/conv_top) ==========
# 활성 IP:
#   dpram_4096x72_288 : gbuff_param weight buffer (write 72 / read 288 비대칭)
#                       4096 × 72 bit = 36 KB. read 측은 1024 × 288 bit 로 자동 매핑.
#   spram_2560x32     : gbuff_param bias/shift buffer (32-bit packed)
#
# ========== 폐기 (이전 Tier 1 스캐폴드) ==========
# 아래 4 종은 이전 16-MAC 스캐폴드용으로 생성된 IP. 강의자료 경로 (mac_kern 기반) 에서는
# 인스턴스화되지 않으므로 합성 시 자원 소비 0. 스크립트는 유지 (호환성 보존):
#   spram_2048x128   : (구) weight buffer
#   spram_128x32     : (구) bias buffer
#   dpram_16384x128  : (구) IFM ping-pong buffer
#   dpram_65536x32   : (구) OFM packed-byte buffer
#
# Latency: 모든 IP 는 BRAM primitive 내부 레지스터 1단만 사용 (Output 추가 register OFF)
#          → read latency = 1 cycle (시뮬레이션 모델과 일치)
#*****************************************************************************************

set ip_version "8.4"
set ip_vendor  "xilinx.com"
set ip_library "ip"
set ip_core    "blk_mem_gen"

#============================================================
# 1) spram_2048x128 - Weight buffer (Single Port)
#============================================================
puts "Creating spram_2048x128..."
create_ip -name $ip_core -vendor $ip_vendor -library $ip_library \
          -version $ip_version -module_name spram_2048x128

set_property -dict [list \
    CONFIG.Memory_Type {Single_Port_RAM} \
    CONFIG.Write_Width_A {128} \
    CONFIG.Write_Depth_A {2048} \
    CONFIG.Read_Width_A  {128} \
    CONFIG.Operating_Mode_A {NO_CHANGE} \
    CONFIG.Enable_A {Use_ENA_Pin} \
    CONFIG.Register_PortA_Output_of_Memory_Primitives {false} \
    CONFIG.Use_Byte_Write_Enable {false} \
    CONFIG.Use_RSTA_Pin {false} \
] [get_ips spram_2048x128]

#============================================================
# 2) spram_128x32 - Bias buffer (Single Port)
#============================================================
puts "Creating spram_128x32..."
create_ip -name $ip_core -vendor $ip_vendor -library $ip_library \
          -version $ip_version -module_name spram_128x32

set_property -dict [list \
    CONFIG.Memory_Type {Single_Port_RAM} \
    CONFIG.Write_Width_A {32} \
    CONFIG.Write_Depth_A {128} \
    CONFIG.Read_Width_A  {32} \
    CONFIG.Operating_Mode_A {NO_CHANGE} \
    CONFIG.Enable_A {Use_ENA_Pin} \
    CONFIG.Register_PortA_Output_of_Memory_Primitives {false} \
    CONFIG.Use_Byte_Write_Enable {false} \
    CONFIG.Use_RSTA_Pin {false} \
] [get_ips spram_128x32]

#============================================================
# 3) dpram_16384x128 - IFM buffer (Simple Dual Port)
#   Port A: write only (DMA load)
#   Port B: read only (conv_layer_ctrl fetch)
#============================================================
puts "Creating dpram_16384x128..."
create_ip -name $ip_core -vendor $ip_vendor -library $ip_library \
          -version $ip_version -module_name dpram_16384x128

set_property -dict [list \
    CONFIG.Memory_Type {Simple_Dual_Port_RAM} \
    CONFIG.Common_Clock {true} \
    CONFIG.Write_Width_A {128} \
    CONFIG.Write_Depth_A {16384} \
    CONFIG.Read_Width_A  {128} \
    CONFIG.Write_Width_B {128} \
    CONFIG.Read_Width_B  {128} \
    CONFIG.Enable_A {Use_ENA_Pin} \
    CONFIG.Enable_B {Use_ENB_Pin} \
    CONFIG.Register_PortA_Output_of_Memory_Primitives {false} \
    CONFIG.Register_PortB_Output_of_Memory_Primitives {false} \
    CONFIG.Use_Byte_Write_Enable {false} \
    CONFIG.Use_RSTA_Pin {false} \
    CONFIG.Use_RSTB_Pin {false} \
] [get_ips dpram_16384x128]

#============================================================
# 4) dpram_65536x32 - OFM buffer (Simple Dual Port)
#   Port A: write only (OFM packer)
#   Port B: read only (DMA store)
#============================================================
puts "Creating dpram_65536x32..."
create_ip -name $ip_core -vendor $ip_vendor -library $ip_library \
          -version $ip_version -module_name dpram_65536x32

set_property -dict [list \
    CONFIG.Memory_Type {Simple_Dual_Port_RAM} \
    CONFIG.Common_Clock {true} \
    CONFIG.Write_Width_A {32} \
    CONFIG.Write_Depth_A {65536} \
    CONFIG.Read_Width_A  {32} \
    CONFIG.Write_Width_B {32} \
    CONFIG.Read_Width_B  {32} \
    CONFIG.Enable_A {Use_ENA_Pin} \
    CONFIG.Enable_B {Use_ENB_Pin} \
    CONFIG.Register_PortA_Output_of_Memory_Primitives {false} \
    CONFIG.Register_PortB_Output_of_Memory_Primitives {false} \
    CONFIG.Use_Byte_Write_Enable {false} \
    CONFIG.Use_RSTA_Pin {false} \
    CONFIG.Use_RSTB_Pin {false} \
] [get_ips dpram_65536x32]

#============================================================
# 5) dpram_4096x72 - gbuff_param weight buffer (비대칭 dual port)
#   Port A: write 72-bit × depth 4096   (DMA load)
#   Port B: read 288-bit × depth 1024   (mac_kern weight stream)
#   ※ Vivado BMG 가 read width 와 write width 가 다른 경우
#     automatic asymmetric port 로 매핑한다.
#============================================================
puts "Creating dpram_4096x72..."
create_ip -name $ip_core -vendor $ip_vendor -library $ip_library \
          -version $ip_version -module_name dpram_4096x72

set_property -dict [list \
    CONFIG.Memory_Type {Simple_Dual_Port_RAM} \
    CONFIG.Common_Clock {true} \
    CONFIG.Write_Width_A {72} \
    CONFIG.Write_Depth_A {4096} \
    CONFIG.Read_Width_A  {72} \
    CONFIG.Write_Width_B {288} \
    CONFIG.Read_Width_B  {288} \
    CONFIG.Enable_A {Use_ENA_Pin} \
    CONFIG.Enable_B {Use_ENB_Pin} \
    CONFIG.Register_PortA_Output_of_Memory_Primitives {false} \
    CONFIG.Register_PortB_Output_of_Memory_Primitives {false} \
    CONFIG.Use_Byte_Write_Enable {false} \
    CONFIG.Use_RSTA_Pin {false} \
    CONFIG.Use_RSTB_Pin {false} \
] [get_ips dpram_4096x72]

#============================================================
# 6b) dpram_2048x128_tdp - ifm_line_buf line buffer (True Dual Port)
#   Port A: write 또는 base entry read (시간 분리)
#   Port B: base+1 entry read (always read)
#   Width A/B = 128, Depth A/B = 2048
#   4 인스턴스 사용 (4-row sliding window).
#============================================================
puts "Creating dpram_2048x128_tdp..."
create_ip -name $ip_core -vendor $ip_vendor -library $ip_library \
          -version $ip_version -module_name dpram_2048x128_tdp

set_property -dict [list \
    CONFIG.Memory_Type {True_Dual_Port_RAM} \
    CONFIG.Common_Clock {true} \
    CONFIG.Write_Width_A {128} \
    CONFIG.Write_Depth_A {2048} \
    CONFIG.Read_Width_A  {128} \
    CONFIG.Write_Width_B {128} \
    CONFIG.Read_Width_B  {128} \
    CONFIG.Operating_Mode_A {NO_CHANGE} \
    CONFIG.Operating_Mode_B {NO_CHANGE} \
    CONFIG.Enable_A {Use_ENA_Pin} \
    CONFIG.Enable_B {Use_ENB_Pin} \
    CONFIG.Register_PortA_Output_of_Memory_Primitives {false} \
    CONFIG.Register_PortB_Output_of_Memory_Primitives {false} \
    CONFIG.Use_Byte_Write_Enable {false} \
    CONFIG.Use_RSTA_Pin {false} \
    CONFIG.Use_RSTB_Pin {false} \
] [get_ips dpram_2048x128_tdp]

#============================================================
# 6) spram_2560x32 - gbuff_param bias/shift buffer (Single Port)
#   entry 당 {bias[15:0], shift[15:0]} packed.
#============================================================
puts "Creating spram_2560x32..."
create_ip -name $ip_core -vendor $ip_vendor -library $ip_library \
          -version $ip_version -module_name spram_2560x32

set_property -dict [list \
    CONFIG.Memory_Type {Single_Port_RAM} \
    CONFIG.Write_Width_A {32} \
    CONFIG.Write_Depth_A {2560} \
    CONFIG.Read_Width_A  {32} \
    CONFIG.Operating_Mode_A {NO_CHANGE} \
    CONFIG.Enable_A {Use_ENA_Pin} \
    CONFIG.Register_PortA_Output_of_Memory_Primitives {false} \
    CONFIG.Use_Byte_Write_Enable {false} \
    CONFIG.Use_RSTA_Pin {false} \
] [get_ips spram_2560x32]

#============================================================
# Generate output products for all IPs
#============================================================
set ip_list {spram_2048x128 spram_128x32 dpram_16384x128 dpram_65536x32 \
             dpram_4096x72 spram_2560x32 dpram_2048x128_tdp}
foreach ip_name $ip_list {
    puts "Generating targets for $ip_name..."
    generate_target all [get_ips $ip_name]
    # synth_ip 은 시간이 오래 걸리므로 합성 단계에서 자동 처리되도록 생략
    # 필요 시 주석 해제: synth_ip [get_ips $ip_name]
}

puts "============================================================"
puts "  BRAM IP 생성 완료"
puts "  활성 (강의자료 경로):"
puts "    dpram_4096x72  (gbuff_param weight, 72→288 비대칭)"
puts "    spram_2560x32  (gbuff_param bias/shift)"
puts "  폐기 (이전 Tier 1 — 합성 시 미사용):"
puts "    spram_2048x128 / spram_128x32 / dpram_16384x128 / dpram_65536x32"
puts "  다음 단계: 합성 실행 (launch_runs synth_1)"
puts "============================================================"
