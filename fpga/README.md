# Verilog Ethernet Z7-LITE Example Design

## Introduction

This example design targets the MicroPhase Z7-LITE board.

The design is PL-only and uses the on-board RTL8201F 10/100 Mbps PHY in MII
mode.  It listens to UDP port 1234 at IP address 192.168.10.128 and echoes
received payloads back.  ARP requests and ICMP echo requests (ping) are
answered by the UDP stack.

The echo reply is sent to a fixed host IP configured by `ECHO_DEST_IP` in
`rtl/fpga.v` / `rtl/fpga_core.v` (default `192.168.10.100`).  Set it to the IP
address of the host running netcat/hping before building.  Only UDP port 1234
is echoed.

*  FPGA: XC7Z020-1CLG400C
*  PHY: Realtek RTL8201F, 10/100 Mbps MII
*  Clock: 50 MHz PL clock (`PL_CLK_50M`, pin N18)

## Board details

The reference manual and the R11 schematic disagree on a few pin numbers.
This design uses the schematic and the pin list from a known-working Z7-LITE
project:

| Signal | Pin | Signal | Pin |
|--------|-----|--------|-----|
| PL_CLK_50M | N18 | ETH_nRST | H20 |
| PL_KEY1 | P16 | PL_KEY2 | T12 |
| PL_LED1 | P15 | PL_LED2 | U12 |
| ETH_MDC | G14 | ETH_MDIO | J15 |
| ETH_RXCK | K17 | ETH_TXCK | L14 |
| ETH_RXD0 | J14 | ETH_TXD0 | M14 |
| ETH_RXD1 | K14 | ETH_TXD1 | L15 |
| ETH_RXD2 | M18 | ETH_TXD2 | M15 |
| ETH_RXD3 | M17 | ETH_TXD3 | N15 |
| ETH_RXDV | K18 | ETH_TXCTL | N16 |

Notes:

* `PL_CLK_50M` is on N18 (`IO_L13P_T2_MRCC_34`).  The schematic text is
  easy to misread because P19 is the N-side of the same clock-capable pair;
  a single-ended clock input must use the P-side, and Vivado confirms that
  N18 is the P-side pin.
* `ETH_RXER`, `ETH_CRS` and `ETH_COL` are not routed to the FPGA on this
  board.  `mii_rx_er` is tied low inside the design.
* `ETH_TXCK` (L14) is not a clock-capable pin in the CLG400 package, but
  `mii_phy_if` drives a BUFG from it.  The XDC uses
  `CLOCK_DEDICATED_ROUTE FALSE` for that net, so Vivado reports a
  `Place 30-574` warning.  This is expected; the 25 MHz TX clock still
  meets timing with the non-dedicated route.
* The RTL8201F on this board comes up in **RMII mode**: Page 7 Register
  16 (RMSR) reads `0x1FFA`, so bit 3 (RMII Mode) is 1.  In RMII mode TXC
  is an input, so both MII clocks are dead and the MAC never sees data.
  The mode is latched at power-on from the PHY RXDV strap (pin 26).
* **PUDC_B** is brought out on **JP1 pin 37** (net `GPIO1_16P`, FPGA
  V13) and is floating by default.  A floating PUDC_B makes the
  configuration-time user-I/O pull-ups undefined; FPGA K18 can then pull
  `ETH_RXDV` high when the PHY samples its strap, latching RMII.  The
  hardware fix is to strap PUDC_B high: **JP1 pin 37 to pin 29
  (VCC_3V3) through 4.7K**.  Power-cycle after fitting the strap.
* The design also includes an MDIO master on MDC = G14 / MDIO = J15
  (PHY address 001) that selects page 7, reads RMSR, clears bit 3 to
  force MII mode, then returns to page 0 and reads BMSR.  This is a
  software fallback: it is required only when PUDC_B is not strapped
  high.  With the PUDC_B strap fitted, the MDIO master still runs but
  sees RMSR bit 3 already 0.
* Observed with the MDIO fallback: RMSR read `0x1FFA` (RMII), BMSR
  `0x786D` (link up, auto-negotiation complete).  Both MII clocks then
  run and ping/UDP echo work.

## LEDs and keys

* LED0 (P15): heartbeat, toggles about every 0.67 s.
* LED1 (U12): packet activity, stretched for about 0.33 s after RX or TX.
* KEY1 (P16): reset, active low.
* KEY2 (T12): clears the ARP cache while held.

The board LEDs are active low; the top level inverts the core's active-high
LED outputs.

## How to build

Run make to build.  Ensure that the Xilinx Vivado toolchain components are
in PATH.

    make

The output bitstream is `fpga/fpga.bit`.

The upstream RTL is vendored under `vendor/verilog-ethernet`; no `lib/eth`
symlink or Windows junction is needed.

## How to test

Program the board over JTAG:

    make program

The PC's Ethernet adapter must have the address configured by
`ECHO_DEST_IP` (default `192.168.10.100/24`).  Check it with `ipconfig` or

    powershell -Command "Get-NetIPAddress -AddressFamily IPv4"

On Windows without netcat, use the included Python test script (from the
repository root):

    python tools/udp_echo_test.py
    python tools/udp_echo_test.py "hello" --count 10

The script prints `PASS` when the echoed payload matches, and reports a
timeout if the link, PC address, ARP entry, or `ECHO_DEST_IP` is wrong.

It is also possible to use netcat or hping:

    netcat -u 192.168.10.128 1234
    hping 192.168.10.128 -2 -p 1234 -d 1024

and to check the ICMP responder with

    ping 192.168.10.128

## UDP stress test

`udp_stress_test.py` sends back-to-back UDP packets of several payload
sizes and measures the echoed throughput (from the repository root):

    python tools/udp_stress_test.py
    python tools/udp_stress_test.py --count 20000
    python tools/udp_stress_test.py --sizes 64,256,1024,1472
    python tools/udp_stress_test.py --sizes 1472 --count 10000 --pps 8000

The design supports payloads up to 1472 bytes (`MAX_PAYLOAD_LEN`).  The
printed `wire_Mbps` is a one-way Ethernet estimate; the echo doubles the
link load (full duplex).  Without `--pps` the PC can offer more than
100 Mbps and the board's RX/TX FIFOs will drop packets; use `--pps` at
the line rate for a clean throughput measurement.

Measured on the Z7-LITE (100M MII, 50 MHz logic clock):

* 1472 B, `--pps 8000`: 0% loss, 94.1 Mbps payload, 98.35 Mbps wire,
  latency 0.4/1.0/2.4 ms
* 64 B, max rate: 0% loss, 47.7 Mbps payload, 96.9 Mbps wire
* 512 B and larger without pacing: link saturated at ~99.7 Mbps wire,
  with loss because the PC offers more than the 100M link can carry

## Debug with ILA

The default build includes a 4096-sample ILA clocked by the 50 MHz `clk`
domain.  Program `fpga/fpga.bit` and make sure the matching
`fpga/fpga.ltx` probes file is loaded in Hardware Manager.  The raw MII
pins are packed into IOB flip-flops; probe8 uses the registered MII RX
signals after the IOB, and probe9/probe10 count the MII clocks.

| Probe | Width | Contents |
|-------|-------|----------|
| probe0 | 12 | `{rx_axis_tuser, tlast, tready, tvalid, tdata[7:0]}` |
| probe1 | 12 | `{tx_axis_tuser, tlast, tready, tvalid, tdata[7:0]}` |
| probe2 | 32 | `echo_rx_tdest[31:0]` = `{source_port, destination_port}` |
| probe3 | 12 | `{echo_rx_tlast, tuser, tvalid, tready, tdata[7:0]}` |
| probe4 | 32 | `echo_tx_tdest[31:0]` |
| probe5 | 12 | `{echo_tx_tlast, tuser, tvalid, tready, tdata[7:0]}` |
| probe6 | 9 | status bits (see below) |
| probe7 | 6 | `{tx_busy, rx_busy, phy_reset_n, rst, led[1:0]}` |
| probe8 | 5 | `{mac_mii_rx_dv, mac_mii_rxd[3:0]}` |
| probe9 | 4 | `dbg_mii_rx_clk_cnt[11:8]` |
| probe10 | 4 | `dbg_mii_tx_clk_cnt[11:8]` |
| probe11 | 32 | `{phy_rmsr[15:0], phy_bmsr[15:0]}` |
| probe12 | 7 | `{mdio_state[2:0], mdio_busy, mdio_done, mdio_start, mdio_we}` |

Status bits (`probe6`):

| Bit | Signal |
|-----|--------|
| 8 | `tx_error_arp_failed` |
| 7 | `tx_error_overflow` |
| 6 | `tx_error_payload_early_termination` |
| 5 | `rx_error_header_early_termination` |
| 4 | `rx_error_payload_early_termination` |
| 3 | `rx_error_invalid_header` |
| 2 | `rx_error_invalid_checksum` |
| 1 | `rx_drop_ip_mismatch` |
| 0 | `icmp_error_overflow` |

Useful triggers:

* Any Ethernet frame received: `probe0[8]` (rx_axis_tvalid) = 1
* Any Ethernet frame transmitted: `probe1[8]` (tx_axis_tvalid) = 1
* UDP payload received by the application: `probe3[9]` = 1
* UDP payload transmitted by the application: `probe5[9]` = 1
* ARP resolution failed: `probe6[8]` = 1
* MII RXDV activity: `probe8[4]` = 1
* MII RX/TX clocks running: probe9/probe10 changing
* Check the design is alive: `probe7[0]` (heartbeat) toggling
* PHY MDIO result: probe11 = `{RMSR, BMSR}`

Set the trigger position to 50%, arm the ILA, then ping or run the UDP
test from the PC.

Set `.DEBUG_ILA(0)` in `rtl/fpga.v` and rebuild for a production
bitstream without the ILA.

## Design structure

```
rtl/fpga.v                 top level: 50 MHz clock buffer, reset, PHY reset, LEDs
rtl/fpga_core.v            eth_mac_mii_fifo + udp_axis_complete + UDP echo loop
rtl/mdio_master.v          MDIO master used to force the RTL8201F into MII mode
../rtl/udp_axis_complete.v compact UDP/AXIS wrapper
../rtl/icmp_echo.v         cut-through ICMP echo responder
fpga.xdc                   pin and timing constraints
fpga/Makefile              Vivado project and bitstream flow
```

The upstream UDP stack, ARP, ICMP core and AXIS infrastructure are
vendored under `vendor/verilog-ethernet`.

For a future 1G RGMII PHY, see
[../docs/rgmii-migration.md](../docs/rgmii-migration.md).  The RGMII RTL and
timing Tcl files are already in the vendor tree, and the NexysVideo 1G
RGMII top/core reference is under `../docs/reference/`.
