# Migrating from 100M MII to 1G RGMII

This note describes how to turn the current Z7-LITE 100M MII design into a
1G RGMII design while keeping `udp_axis_complete` and the UDP echo/streaming
application.  The RGMII RTL and timing Tcl files are already vendored under
`vendor/verilog-ethernet`, and a complete 1G RGMII reference top/core is in
`docs/reference/` (NexysVideo, which uses the same `udp_axis_complete`).

The important idea:

```text
100M MII:   eth_mac_mii_fifo      + 50 MHz  logic clock
1G RGMII:   eth_mac_1g_rgmii_fifo + 125 MHz logic clock (+ 90 deg TX clock)
UDP/AXIS:   udp_axis_complete     unchanged (8-bit AXIS)
```

## 1. File list changes in fpga/fpga/Makefile

Remove the MII MAC files:

```make
# remove these
SYN_FILES += ../vendor/verilog-ethernet/rtl/ssio_sdr_in.v
SYN_FILES += ../vendor/verilog-ethernet/rtl/mii_phy_if.v
SYN_FILES += ../vendor/verilog-ethernet/rtl/eth_mac_mii_fifo.v
SYN_FILES += ../vendor/verilog-ethernet/rtl/eth_mac_mii.v
```

Add the RGMII files (already present in vendor):

```make
SYN_FILES += ../vendor/verilog-ethernet/rtl/iddr.v
SYN_FILES += ../vendor/verilog-ethernet/rtl/oddr.v
SYN_FILES += ../vendor/verilog-ethernet/rtl/ssio_ddr_in.v
SYN_FILES += ../vendor/verilog-ethernet/rtl/ssio_ddr_out.v
SYN_FILES += ../vendor/verilog-ethernet/rtl/rgmii_phy_if.v
SYN_FILES += ../vendor/verilog-ethernet/rtl/eth_mac_1g_rgmii_fifo.v
SYN_FILES += ../vendor/verilog-ethernet/rtl/eth_mac_1g_rgmii.v
```

Keep the common files already used by both MACs:

```text
eth_mac_1g.v, axis_gmii_rx.v, axis_gmii_tx.v, lfsr.v,
eth_axis_rx.v, eth_axis_tx.v, udp_complete.v, ..., arp_eth_tx.v,
eth_arb_mux.v, and the axis library files
```

XDC Tcl files:

```make
# remove
XDC_FILES += ../vendor/verilog-ethernet/syn/vivado/mii_phy_if.tcl

# add
XDC_FILES += ../vendor/verilog-ethernet/syn/vivado/rgmii_phy_if.tcl
XDC_FILES += ../vendor/verilog-ethernet/syn/vivado/eth_mac_1g_rgmii.tcl
```

Keep `eth_mac_fifo.tcl`, `axis_async_fifo.tcl`, and `sync_reset.tcl`; the
`eth_mac_fifo.tcl` regex also matches `eth_mac_1g_rgmii_fifo`.

## 2. Top level fpga.v: clocks and ports

Replace the MII PHY ports with RGMII ports:

```verilog
input  wire       rgmii_rx_clk,
input  wire [3:0] rgmii_rxd,
input  wire       rgmii_rx_ctl,
output wire       rgmii_tx_clk,
output wire [3:0] rgmii_txd,
output wire       rgmii_tx_ctl,
output wire       phy_reset_n
```

The current Z7-LITE board only has a 50 MHz PL clock.  For 1G RGMII, generate
a 125 MHz logic clock and a 125 MHz 90-degree clock with an MMCM:

```verilog
wire clk125_mmcm;
wire clk125_90_mmcm;
wire clk125;
wire clk125_90;

MMCME2_BASE #(
    .BANDWIDTH("OPTIMIZED"),
    .CLKOUT0_DIVIDE_F(8.000),   // 1000 MHz VCO / 8 = 125 MHz
    .CLKOUT0_DUTY_CYCLE(0.5),
    .CLKOUT0_PHASE(0.000),
    .CLKOUT1_DIVIDE(8),
    .CLKOUT1_DUTY_CYCLE(0.5),
    .CLKOUT1_PHASE(90.000),     // 125 MHz, 90 degrees
    .CLKFBOUT_MULT_F(20.000),   // 50 MHz * 20 = 1000 MHz VCO
    .CLKFBOUT_PHASE(0.0),
    .DIVCLK_DIVIDE(1),
    .REF_JITTER1(0.010),
    .CLKIN1_PERIOD(20.000),     // 50 MHz input
    .STARTUP_WAIT("FALSE"),
    .CLKOUT4_CASCADE("FALSE")
)
clk125_mmcm_inst (
    .CLKIN1(clk_ibuf),
    .CLKFBIN(clk125_fb),
    .RST(~reset_n),
    .PWRDWN(1'b0),
    .CLKOUT0(clk125_mmcm),
    .CLKOUT1(clk125_90_mmcm),
    .CLKFBOUT(clk125_fb),
    .LOCKED(mmcm_locked)
);

BUFG clk125_bufg_inst      (.I(clk125_mmcm),    .O(clk125));
BUFG clk125_90_bufg_inst   (.I(clk125_90_mmcm), .O(clk125_90));

wire rst125;
sync_reset #(.N(4)) rst125_inst (
    .clk(clk125),
    .rst(~reset_n | ~mmcm_locked),
    .out(rst125)
);
```

If the new board already has a 125 MHz oscillator, use it for `clk125`; still
generate the 90-degree clock with an MMCM (or set `USE_CLK90("FALSE")` in the
MAC and follow the MAC's requirements).

Update the PHY reset stretch counter for 125 MHz.  The current 50 MHz design
uses 21 bits for about 42 ms; at 125 MHz use 23 bits:

```verilog
reg [22:0] phy_rst_cnt = 23'd0;
always @(posedge clk125) begin
    if (rst125) phy_rst_cnt <= 23'd0;
    else if (!(&phy_rst_cnt)) phy_rst_cnt <= phy_rst_cnt + 1'b1;
end
assign phy_reset_n = &phy_rst_cnt;
```

Pass the new clocks/ports to `fpga_core`:

```verilog
fpga_core #(
    .TARGET("XILINX"),
    .ECHO_DEST_IP(32'hC0A8_0A64),
    .DEBUG_ILA(1)
) core_inst (
    .clk(clk125),
    .clk90(clk125_90),
    .rst(rst125),
    .rgmii_rx_clk(rgmii_rx_clk),
    .rgmii_rxd(rgmii_rxd),
    .rgmii_rx_ctl(rgmii_rx_ctl),
    .rgmii_tx_clk(rgmii_tx_clk),
    .rgmii_txd(rgmii_txd),
    .rgmii_tx_ctl(rgmii_tx_ctl),
    .phy_reset_n(phy_reset_n),
    ...
);
```

The NexysVideo reference in `docs/reference/fpga.v` is a working
100 MHz -> 125 MHz + 90-degree MMCM example.

## 3. fpga_core.v: replace the MAC instance

Add `clk90`, `gtx_rst`, and RGMII ports, then replace
`eth_mac_mii_fifo` with:

```verilog
eth_mac_1g_rgmii_fifo #(
    .TARGET(TARGET),
    .IODDR_STYLE("IODDR"),
    .CLOCK_INPUT_STYLE("BUFR"),
    .USE_CLK90("TRUE"),
    .ENABLE_PADDING(1),
    .MIN_FRAME_LENGTH(64),
    .TX_FIFO_DEPTH(4096),
    .TX_FRAME_FIFO(1),
    .RX_FIFO_DEPTH(4096),
    .RX_FRAME_FIFO(1)
)
eth_mac_inst (
    .gtx_clk(clk),
    .gtx_clk90(clk90),
    .gtx_rst(rst),
    .logic_clk(clk),
    .logic_rst(rst),

    .tx_axis_tdata(tx_axis_tdata),
    .tx_axis_tkeep(1'b1),
    .tx_axis_tvalid(tx_axis_tvalid),
    .tx_axis_tready(tx_axis_tready),
    .tx_axis_tlast(tx_axis_tlast),
    .tx_axis_tuser(tx_axis_tuser),

    .rx_axis_tdata(rx_axis_tdata),
    .rx_axis_tkeep(),
    .rx_axis_tvalid(rx_axis_tvalid),
    .rx_axis_tready(rx_axis_tready),
    .rx_axis_tlast(rx_axis_tlast),
    .rx_axis_tuser(rx_axis_tuser),

    .rgmii_rx_clk(rgmii_rx_clk),
    .rgmii_rxd(rgmii_rxd),
    .rgmii_rx_ctl(rgmii_rx_ctl),
    .rgmii_tx_clk(rgmii_tx_clk),
    .rgmii_txd(rgmii_txd),
    .rgmii_tx_ctl(rgmii_tx_ctl),

    .tx_fifo_overflow(),
    .tx_fifo_bad_frame(),
    .tx_fifo_good_frame(),
    .rx_error_bad_frame(),
    .rx_error_bad_fcs(),
    .rx_fifo_overflow(),
    .rx_fifo_bad_frame(),
    .rx_fifo_good_frame(),
    .speed(),

    .cfg_ifg(8'd12),
    .cfg_tx_enable(1'b1),
    .cfg_rx_enable(1'b1)
);
```

Keep the `udp_axis_complete` instance exactly as it is; it still uses 8-bit
AXIS.  The only changes are:

* `clk` is now 125 MHz.
* Remove the 50 MHz ARP timer overrides (or set 125 MHz values):

```verilog
.ARP_REQUEST_RETRY_COUNT(4),
.ARP_REQUEST_RETRY_INTERVAL(250000000),   // 2 s at 125 MHz
.ARP_REQUEST_TIMEOUT(3750000000)          // 30 s at 125 MHz
```

The `udp_axis_complete` module defaults are already 125 MHz values.

## 4. PHY pins and XDC

Remove the MII pin constraints, MII input/output delays, and the
`CLOCK_DEDICATED_ROUTE FALSE` for the MII TX clock.

Add RGMII pins for the new board, for example (the exact LOCs and IOSTANDARD
come from the new board schematic):

```tcl
# RGMII PHY, adapt LOC/IOSTANDARD to the board
set_property -dict {PACKAGE_PIN ... IOSTANDARD LVCMOS25} [get_ports rgmii_rx_clk]
set_property -dict {PACKAGE_PIN ... IOSTANDARD LVCMOS25} [get_ports {rgmii_rxd[0]}]
...
set_property -dict {PACKAGE_PIN ... IOSTANDARD LVCMOS25 SLEW FAST DRIVE 16} [get_ports rgmii_tx_clk]
set_property -dict {PACKAGE_PIN ... IOSTANDARD LVCMOS25 SLEW FAST DRIVE 16} [get_ports {rgmii_txd[0]}]
...
```

The RGMII RX clock is 125 MHz at 1G:

```tcl
create_clock -period 8.000 -name rgmii_rx_clk [get_ports rgmii_rx_clk]
```

The reference `docs/reference/nexysvideo_fpga.xdc` has the complete NexysVideo
RGMII pin map and the 8 ns RX clock constraint.  The reference
`docs/reference/nexysvideo_eth.xdc` shows the IDELAY setting for the
RTL8211E:

```tcl
set_property IDELAY_VALUE 0 [get_cells {phy_rx_ctl_idelay phy_rxd_idelay_*}]
```

The vendored `rgmii_phy_if.tcl` and `eth_mac_1g_rgmii.tcl` insert the
IDDR/ODDR and output timing constraints.  Keep the async FIFO and reset Tcl
files.  Check the new PHY datasheet for:

* RGMII internal delay (RTL8211E, KSZ9031, DP83867 all differ)
* RX/TX clock skew
* I/O voltage (1.8 V, 2.5 V, or 3.3 V)
* whether the PHY needs MDIO configuration for RGMII delay

## 5. MDIO / PHY initialization

The current `mdio_master` is used only to work around the Z7-LITE RTL8201F
RMII strap.  For a new 1G PHY:

* Change `CLK_DIV`: 125 MHz / (2 * 62) ~= 1.008 MHz; set `CLK_DIV = 62` in
  the `mdio_master` instance (the current 50 MHz design uses 25).
* Set `phy_addr` to the new PHY address.
* Keep the BMSR read if you want link/speed diagnostics.
* Remove the RTL8201F-specific Page 7 RMSR RMII write unless the new PHY has
  the same strap behavior.
* If the new PHY needs register writes (RGMII delay, clock skew, LED,
  power-down), add them to the sequencer in `fpga_core.v`.

The `eth_mac_1g_rgmii_fifo` itself does not contain an MDIO master; MDIO is
separate.

## 6. ILA changes

The current ILA probes are MII-specific:

* `mac_mii_rx_dv`, `mac_mii_rxd`
* `dbg_mii_rx_clk_cnt`, `dbg_mii_tx_clk_cnt`
* `phy_rmsr`, `phy_bmsr`

For RGMII:

* Change the ILA clock to the 125 MHz `clk` and regenerate the ILA IP.
* Remove the MII RX/clock counter probes.
* Probe the MAC-side AXIS (`rx_axis_*`, `tx_axis_*`) and the application
  (`echo_rx_*`, `echo_tx_*`) as before.
* The raw RGMII pins are DDR and are packed into IOBs; probing them directly
  is usually not possible.  Probe the registered signals inside
  `rgmii_phy_if` or keep the MAC-side AXIS probes.
* Keep `phy_bmsr`/`phy_rmsr` only if the new PHY uses the same registers.

The ILA IP is regenerated from `fpga/ila_0.tcl`; update `C_NUM_OF_PROBES` and
the probe widths when the probe list changes.

## 7. Throughput and datapath width

The 8-bit AXIS at 125 MHz is exactly 1 Gbps raw:

```text
8 bit * 125 MHz = 1000 Mbps
```

The `udp_axis_complete` wrapper is currently fixed at 8-bit.  For typical ADC
uploads with large packets it can run at 1G line rate, but for small packets
the per-packet UDP/IP/ARP logic and the 8-bit path may become the bottleneck.
Options:

* Keep 8-bit for 1G and use 512-1472 byte payloads.
* Increase `TX_FIFO_DEPTH` and the MAC FIFOs (e.g., 8192/16384) for
  back-to-back bursts.
* For more margin or >1G, widen `udp_axis_complete` to 32/64-bit.  The
  upstream `udp_complete`/`ip_complete` support wider AXIS; the wrapper's
  FIFOs, metadata, and checksum path would need the same width change.

`MAX_PAYLOAD_LEN` is 1472 (standard 1500-byte MTU).  Jumbo frames are not
supported by the current wrapper.

## 8. Test the 1G version

On the PC, use a 1G NIC and set the address to the new `ECHO_DEST_IP`.
The board's `LOCAL_IP` and the PC address still need to be on the same subnet.

```bash
ping <board-ip>
python tools/udp_echo_test.py --dut-ip <board-ip> --local-ip <pc-ip>
python tools/udp_stress_test.py --dut-ip <board-ip> --local-ip <pc-ip> \
       --sizes 1472 --count 20000 --pps 80000
```

At 1G, the approximate line-rate packet rates are:

| Payload | Approx. pps at 1G |
|---------|-------------------|
| 1472 B | 81,000 |
| 1024 B | 114,000 |
| 512 B | 216,000 |
| 64 B | 960,000 |

The Python stress script cannot reach the small-packet rates at 1G; use a C
or DPDK-based sender for 64-byte line-rate tests.  For large packets it is
fine.

## 9. Reference files

`docs/reference/` contains the NexysVideo 1G RGMII reference, which uses the
same `udp_axis_complete`:

```text
docs/reference/fpga.v                 # 100 MHz -> 125 MHz + 90 deg MMCM, RGMII top
docs/reference/fpga_core.v            # eth_mac_1g_rgmii_fifo + udp_axis_complete
docs/reference/nexysvideo_fpga.xdc    # RGMII pin map example
docs/reference/nexysvideo_eth.xdc     # RTL8211E IDELAY example
```

These are reference files, not part of the current build.  Adapt the pin
constraints, clock source, and PHY initialization to the new board.

## 10. Migration checklist

- [ ] Replace MII MAC files with RGMII files in `fpga/fpga/Makefile`
- [ ] Replace `mii_phy_if.tcl` with `rgmii_phy_if.tcl` and `eth_mac_1g_rgmii.tcl`
- [ ] Add RGMII ports to `fpga.v`
- [ ] Generate 125 MHz + 125 MHz 90-degree clocks (or use the board's 125 MHz clock)
- [ ] Replace `eth_mac_mii_fifo` with `eth_mac_1g_rgmii_fifo`
- [ ] Tie `tx_axis_tkeep` high; leave `rx_axis_tkeep` open
- [ ] Keep `udp_axis_complete` 8-bit and set ARP timers for 125 MHz
- [ ] Replace MII XDC pins/timing with RGMII pins/timing
- [ ] Adapt MDIO clock divider and PHY initialization
- [ ] Update/remove MII-specific ILA probes
- [ ] Verify link, ARP, ping, UDP echo, and stress throughput
