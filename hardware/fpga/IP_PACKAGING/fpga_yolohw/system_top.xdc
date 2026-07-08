# Nexys A7-100T - UART
set_property -dict { PACKAGE_PIN C4    IOSTANDARD LVCMOS33 } [get_ports { usb_uart_rxd }]
set_property -dict { PACKAGE_PIN D4    IOSTANDARD LVCMOS33 } [get_ports { usb_uart_txd }]

# Nexys A7-100T - LEDs
set_property -dict { PACKAGE_PIN H17   IOSTANDARD LVCMOS33 } [get_ports { network_done_led_0 }]
set_property -dict { PACKAGE_PIN K15   IOSTANDARD LVCMOS33 } [get_ports { o_network_done_0 }]

# reset_0 - Center Button (BTNC)
set_property -dict { PACKAGE_PIN N17   IOSTANDARD LVCMOS33 } [get_ports { reset_0 }]

# ------------------------------------------------------------
# RTRES-1 우회: clk_wiz -> MIG sys_clk(clk_out2) 가 백본 클럭 라우팅을
# 요구하지만 못 쓰는 DRC 에러 회피. clk_wiz 와 MIG 가 같은/인접 클럭영역에
# 있어 일반 라우팅으로 충분하므로 dedicated route 강제를 해제한다.
# ------------------------------------------------------------
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets -hierarchical -filter {NAME =~ "*clk_wiz_1/inst/clk_out2"}]
