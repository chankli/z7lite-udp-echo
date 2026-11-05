
# FPGA settings
FPGA_PART = xc7z020clg400-1
FPGA_TOP = fpga
FPGA_ARCH = zynq7

# Files for synthesis
SYN_FILES = rtl/fpga.v
SYN_FILES += rtl/fpga_core.v
SYN_FILES += rtl/mdio_master.v
SYN_FILES += ../rtl/udp_axis_complete.v
SYN_FILES += ../rtl/icmp_echo.v
SYN_FILES += ../vendor/verilog-ethernet/rtl/ssio_sdr_in.v
SYN_FILES += ../vendor/verilog-ethernet/rtl/mii_phy_if.v
SYN_FILES += ../vendor/verilog-ethernet/rtl/eth_mac_mii_fifo.v
SYN_FILES += ../vendor/verilog-ethernet/rtl/eth_mac_mii.v
SYN_FILES += ../vendor/verilog-ethernet/rtl/eth_mac_1g.v
SYN_FILES += ../vendor/verilog-ethernet/rtl/axis_gmii_rx.v
SYN_FILES += ../vendor/verilog-ethernet/rtl/axis_gmii_tx.v
SYN_FILES += ../vendor/verilog-ethernet/rtl/lfsr.v
SYN_FILES += ../vendor/verilog-ethernet/rtl/eth_axis_rx.v
SYN_FILES += ../vendor/verilog-ethernet/rtl/eth_axis_tx.v
SYN_FILES += ../vendor/verilog-ethernet/rtl/udp_complete.v
SYN_FILES += ../vendor/verilog-ethernet/rtl/udp_checksum_gen.v
SYN_FILES += ../vendor/verilog-ethernet/rtl/udp.v
SYN_FILES += ../vendor/verilog-ethernet/rtl/udp_ip_rx.v
SYN_FILES += ../vendor/verilog-ethernet/rtl/udp_ip_tx.v
SYN_FILES += ../vendor/verilog-ethernet/rtl/ip_complete.v
SYN_FILES += ../vendor/verilog-ethernet/rtl/ip.v
SYN_FILES += ../vendor/verilog-ethernet/rtl/ip_eth_rx.v
SYN_FILES += ../vendor/verilog-ethernet/rtl/ip_eth_tx.v
SYN_FILES += ../vendor/verilog-ethernet/rtl/ip_arb_mux.v
SYN_FILES += ../vendor/verilog-ethernet/rtl/arp.v
SYN_FILES += ../vendor/verilog-ethernet/rtl/arp_cache.v
SYN_FILES += ../vendor/verilog-ethernet/rtl/arp_eth_rx.v
SYN_FILES += ../vendor/verilog-ethernet/rtl/arp_eth_tx.v
SYN_FILES += ../vendor/verilog-ethernet/rtl/eth_arb_mux.v
SYN_FILES += ../vendor/verilog-ethernet/lib/axis/rtl/arbiter.v
SYN_FILES += ../vendor/verilog-ethernet/lib/axis/rtl/priority_encoder.v
SYN_FILES += ../vendor/verilog-ethernet/lib/axis/rtl/axis_fifo.v
SYN_FILES += ../vendor/verilog-ethernet/lib/axis/rtl/axis_srl_fifo.v
SYN_FILES += ../vendor/verilog-ethernet/lib/axis/rtl/axis_async_fifo.v
SYN_FILES += ../vendor/verilog-ethernet/lib/axis/rtl/axis_async_fifo_adapter.v
SYN_FILES += ../vendor/verilog-ethernet/lib/axis/rtl/sync_reset.v

# Debug ILA IP
IP_TCL_FILES = ila_0.tcl

# XDC files
XDC_FILES = fpga.xdc
XDC_FILES += ../vendor/verilog-ethernet/syn/vivado/mii_phy_if.tcl
XDC_FILES += ../vendor/verilog-ethernet/syn/vivado/eth_mac_fifo.tcl
XDC_FILES += ../vendor/verilog-ethernet/lib/axis/syn/vivado/axis_async_fifo.tcl
XDC_FILES += ../vendor/verilog-ethernet/lib/axis/syn/vivado/sync_reset.tcl

include ../common/vivado.mk

program: $(FPGA_TOP).bit
	echo "open_hw" > program.tcl
	echo "connect_hw_server" >> program.tcl
	echo "open_hw_target" >> program.tcl
	echo "foreach d [get_hw_devices] { if {![string match *arm_dap* $$d]} { current_hw_device $$d; break } }" >> program.tcl
	echo "refresh_hw_device -update_hw_probes false [current_hw_device]" >> program.tcl
	echo "set_property PROGRAM.FILE {$(FPGA_TOP).bit} [current_hw_device]" >> program.tcl
	echo "if {[file exists $(FPGA_TOP).ltx]} { set_property PROBES.FILE {$(FPGA_TOP).ltx} [current_hw_device] }" >> program.tcl
	echo "program_hw_devices [current_hw_device]" >> program.tcl
	echo "exit" >> program.tcl
	vivado -nojournal -nolog -mode batch -source program.tcl
