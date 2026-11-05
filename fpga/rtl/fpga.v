/*

Copyright (c) 2014-2018 Alex Forencich

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

*/

// Language: Verilog 2001

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * FPGA top-level module
 *
 * MicroPhase Z7-LITE (XC7Z020-1CLG400C)
 * PL-only design using the on-board RTL8201F 10/100 MII PHY.
 */
module fpga (
    /*
     * Clock: 50 MHz (PL_CLK_50M)
     */
    input  wire       clk,

    /*
     * Keys, active low
     */
    input  wire       reset_n,     // PL_KEY1
    input  wire       key2_n,      // PL_KEY2, clears the ARP cache

    /*
     * LEDs, active low
     */
    output wire [1:0] led,

    /*
     * Ethernet: 10/100BASE-T MII (RTL8201F)
     */
    output wire       phy_reset_n,
    input  wire       phy_rx_clk,
    input  wire [3:0] phy_rxd,
    input  wire       phy_rx_dv,
    input  wire       phy_tx_clk,
    output wire [3:0] phy_txd,
    output wire       phy_tx_en,
    output wire       phy_mdc,
    inout  wire       phy_mdio
);

// 50 MHz logic clock
wire clk_ibuf;
wire clk_int;

IBUF
clk_ibuf_inst (
    .I(clk),
    .O(clk_ibuf)
);

BUFG
clk_bufg_inst (
    .I(clk_ibuf),
    .O(clk_int)
);

// Synchronized reset
wire rst_int;

sync_reset #(
    .N(4)
)
sync_reset_inst (
    .clk(clk_int),
    .rst(~reset_n),
    .out(rst_int)
);

// PL_KEY2 clears the ARP cache
reg [1:0] key2_sync = 2'b11;

always @(posedge clk_int) begin
    key2_sync <= {key2_sync[0], key2_n};
end

wire clear_arp_cache = ~key2_sync[1];

// Hold the PHY in reset for about 42 ms after configuration.
// 2^21 cycles at 50 MHz = 41.9 ms.
reg [20:0] phy_rst_cnt = 21'd0;

always @(posedge clk_int) begin
    if (rst_int) begin
        phy_rst_cnt <= 21'd0;
    end else if (!(&phy_rst_cnt)) begin
        phy_rst_cnt <= phy_rst_cnt + 1'b1;
    end
end

assign phy_reset_n = &phy_rst_cnt;

// Core logic
wire [1:0] led_int;

fpga_core #(
    .TARGET("XILINX"),
    .ECHO_DEST_IP(32'hC0A8_0A64),
    .DEBUG_ILA(1)
)
core_inst (
    .clk(clk_int),
    .rst(rst_int),
    .led(led_int),
    .phy_rx_clk(phy_rx_clk),
    .phy_rxd(phy_rxd),
    .phy_rx_dv(phy_rx_dv),
    .phy_tx_clk(phy_tx_clk),
    .phy_txd(phy_txd),
    .phy_tx_en(phy_tx_en),
    .phy_mdc(phy_mdc),
    .phy_mdio(phy_mdio),
    .phy_reset_n(phy_reset_n),
    .clear_arp_cache(clear_arp_cache)
);

// Board LEDs are active low
assign led = ~led_int;

endmodule

`resetall
