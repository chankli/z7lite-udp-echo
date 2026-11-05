# Debug ILA for the Z7-LITE example.
#
# Probe layout (see rtl/fpga_core.v):
#   probe0  {rx_axis_tuser, tlast, tready, tvalid, tdata[7:0]}
#   probe1  {tx_axis_tuser, tlast, tready, tvalid, tdata[7:0]}
#   probe2  echo_rx_tdest[31:0]
#   probe3  {echo_rx_tlast, echo_rx_tuser, echo_rx_tvalid,
#            echo_rx_tready, echo_rx_tdata[7:0]}
#   probe4  echo_tx_tdest[31:0]
#   probe5  {echo_tx_tlast, echo_tx_tuser, echo_tx_tvalid,
#            echo_tx_tready, echo_tx_tdata[7:0]}
#   probe6  status bits
#   probe7  {tx_busy, rx_busy, phy_reset_n, rst, led[1:0]}
#   probe8  {mac_mii_rx_dv, mac_mii_rxd[3:0]}
#   probe9  dbg_mii_rx_clk_cnt[11:8]  MII RX clock activity
#   probe10 dbg_mii_tx_clk_cnt[11:8]  MII TX clock activity
#   probe11 {phy_rmsr[15:0], phy_bmsr[15:0]}
#   probe12 {mdio_state[2:0], mdio_busy, mdio_done, mdio_start, mdio_we}

create_ip -name ila -vendor xilinx.com -library ip -version 6.2 -module_name ila_0

set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES {13} \
    CONFIG.C_DATA_DEPTH {4096} \
    CONFIG.C_INPUT_PIPE_STAGES {2} \
    CONFIG.C_PROBE0_WIDTH {12} \
    CONFIG.C_PROBE1_WIDTH {12} \
    CONFIG.C_PROBE2_WIDTH {32} \
    CONFIG.C_PROBE3_WIDTH {12} \
    CONFIG.C_PROBE4_WIDTH {32} \
    CONFIG.C_PROBE5_WIDTH {12} \
    CONFIG.C_PROBE6_WIDTH {9} \
    CONFIG.C_PROBE7_WIDTH {6} \
    CONFIG.C_PROBE8_WIDTH {5} \
    CONFIG.C_PROBE9_WIDTH {4} \
    CONFIG.C_PROBE10_WIDTH {4} \
    CONFIG.C_PROBE11_WIDTH {32} \
    CONFIG.C_PROBE12_WIDTH {7} \
] [get_ips ila_0]

generate_target {instantiation_template} [get_files ila_0.xci]
