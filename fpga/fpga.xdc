# XDC constraints for the MicroPhase Z7-LITE board
# part: xc7z020clg400-1
#
# Pin mapping is taken from the Z7-LITE R11 schematic and the
# MicroPhase/LiteX Z7-LITE board files.  PL_CLK_50M is on N18; the
# schematic text is easy to misread because P19 is the N-side of the same
# clock-capable pair.

# General configuration
set_property CFGBVS VCCO                               [current_design]
set_property CONFIG_VOLTAGE 3.3                        [current_design]
set_property BITSTREAM.GENERAL.COMPRESS true           [current_design]

# 50 MHz PL clock (PL_CLK_50M, pin N18)
# N18 is IO_L13P_T2_MRCC_34 (clock-capable P-side); P19 is the N-side
# of the same pair and cannot drive a clock buffer on its own.
set_property -dict {PACKAGE_PIN N18 IOSTANDARD LVCMOS33} [get_ports clk]
create_clock -period 20.000 -name clk [get_ports clk]

# PL keys, active low
set_property -dict {PACKAGE_PIN P16 IOSTANDARD LVCMOS33} [get_ports reset_n]
set_property -dict {PACKAGE_PIN T12 IOSTANDARD LVCMOS33} [get_ports key2_n]

set_false_path -from [get_ports {reset_n key2_n}]
set_input_delay 0 [get_ports {reset_n key2_n}]

# PL LEDs, active low
set_property -dict {PACKAGE_PIN P15 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 12} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN U12 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 12} [get_ports {led[1]}]

set_false_path -to [get_ports {led[*]}]
set_output_delay 0 [get_ports {led[*]}]

# Ethernet PHY reset (ETH_nRST, active low)
set_property -dict {PACKAGE_PIN H20 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 12} [get_ports phy_reset_n]
set_false_path -to [get_ports phy_reset_n]

# Ethernet MII PHY (RTL8201F, 10/100 Mbps)
# RX clock and RX data are driven by the PHY
set_property -dict {PACKAGE_PIN K17 IOSTANDARD LVCMOS33} [get_ports phy_rx_clk]
set_property -dict {PACKAGE_PIN J14 IOSTANDARD LVCMOS33} [get_ports {phy_rxd[0]}]
set_property -dict {PACKAGE_PIN K14 IOSTANDARD LVCMOS33} [get_ports {phy_rxd[1]}]
set_property -dict {PACKAGE_PIN M18 IOSTANDARD LVCMOS33} [get_ports {phy_rxd[2]}]
set_property -dict {PACKAGE_PIN M17 IOSTANDARD LVCMOS33} [get_ports {phy_rxd[3]}]
set_property -dict {PACKAGE_PIN K18 IOSTANDARD LVCMOS33} [get_ports phy_rx_dv]

# TX clock is driven by the PHY; TX data is driven by the FPGA
set_property -dict {PACKAGE_PIN L14 IOSTANDARD LVCMOS33} [get_ports phy_tx_clk]
set_property -dict {PACKAGE_PIN M14 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {phy_txd[0]}]
set_property -dict {PACKAGE_PIN L15 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {phy_txd[1]}]
set_property -dict {PACKAGE_PIN M15 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {phy_txd[2]}]
set_property -dict {PACKAGE_PIN N15 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports {phy_txd[3]}]
set_property -dict {PACKAGE_PIN N16 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 12} [get_ports phy_tx_en]

# MDIO: used to read the PHY RMII mode register and force MII mode
set_property -dict {PACKAGE_PIN G14 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 12} [get_ports phy_mdc]
set_property -dict {PACKAGE_PIN J15 IOSTANDARD LVCMOS33 PULLTYPE PULLUP} [get_ports phy_mdio]

set_false_path -to [get_ports phy_mdc]
set_false_path -from [get_ports phy_mdio]
set_false_path -to [get_ports phy_mdio]
set_output_delay 0 [get_ports phy_mdc]

# MII clocks.  At 100 Mbps RXC/TXC are 25 MHz.  The 40 ns period is the
# tightest case; 10 Mbps operation is slower.
create_clock -period 40.000 -name phy_rx_clk [get_ports phy_rx_clk]
create_clock -period 40.000 -name phy_tx_clk [get_ports phy_tx_clk]

# L14 (ETH_TXCK) is not a clock-capable pin in the CLG400 package, but
# mii_phy_if drives a BUFG from it.  Allow the non-dedicated route; at
# 25 MHz the extra insertion delay is acceptable.  (RXCK on K17 is a
# proper CCIO P-side pin and does not need this.)
# Match the port net during synthesis and the IBUF output net during
# implementation, so the constraint is never applied to an empty list.
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets -hierarchical -filter {NAME =~ "*phy_tx_clk*"}]

set_clock_groups -asynchronous \
    -group [get_clocks clk] \
    -group [get_clocks phy_rx_clk] \
    -group [get_clocks phy_tx_clk]

# MII RX timing.  RTL8201F changes RXD/RXDV on the falling edge of RXC,
# i.e. nominally 20 ns after the rising capture edge at 25 MHz.  Model a
# +/-5 ns window around that falling edge; using 0/2 ns around the rising
# edge creates an artificial hold violation because the data is actually
# launched half a cycle later.
set_input_delay -clock phy_rx_clk -max 25.000 [get_ports {phy_rxd[*] phy_rx_dv}]
set_input_delay -clock phy_rx_clk -min 15.000 [get_ports {phy_rxd[*] phy_rx_dv}]

# MII TX timing.  The PHY samples TXD/TXEN on the rising edge of TXC.
set_output_delay -clock phy_tx_clk -max 10.000 [get_ports {phy_txd[*] phy_tx_en}]
set_output_delay -clock phy_tx_clk -min 2.000  [get_ports {phy_txd[*] phy_tx_en}]
