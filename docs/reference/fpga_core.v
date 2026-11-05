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
 * FPGA core logic
 */
module fpga_core #
(
    parameter TARGET = "GENERIC",
    parameter [31:0] ECHO_DEST_IP = 32'hC0A8_0164
)
(
    /*
     * Clock: 125MHz
     * Synchronous reset
     */
    input  wire       clk,
    input  wire       clk90,
    input  wire       rst,

    /*
     * GPIO
     */
    input  wire       btnu,
    input  wire       btnl,
    input  wire       btnd,
    input  wire       btnr,
    input  wire       btnc,
    input  wire [7:0] sw,
    output wire [7:0] led,

    /*
     * Ethernet: 1000BASE-T RGMII
     */
    input  wire       phy_rx_clk,
    input  wire [3:0] phy_rxd,
    input  wire       phy_rx_ctl,
    output wire       phy_tx_clk,
    output wire [3:0] phy_txd,
    output wire       phy_tx_ctl,
    output wire       phy_reset_n,
    input  wire       phy_int_n,
    input  wire       phy_pme_n,

    /*
     * UART: 115200 bps, 8N1
     */
    input  wire       uart_rxd,
    output wire       uart_txd
);

// AXI between MAC and Ethernet modules
wire [7:0] rx_axis_tdata;
wire rx_axis_tvalid;
wire rx_axis_tready;
wire rx_axis_tlast;
wire rx_axis_tuser;

wire [7:0] tx_axis_tdata;
wire tx_axis_tvalid;
wire tx_axis_tready;
wire tx_axis_tlast;
wire tx_axis_tuser;

// Application-side echo AXIS
wire [7:0]  echo_rx_tdata;
wire        echo_rx_tvalid;
wire        echo_rx_tready;
wire        echo_rx_tlast;
wire        echo_rx_tuser;
wire [31:0] echo_rx_tdest;

wire [7:0]  echo_tx_tdata;
wire        echo_tx_tvalid;
wire        echo_tx_tready;
wire        echo_tx_tlast;
wire        echo_tx_tuser;
wire [31:0] echo_tx_tdest;

// Configuration
localparam [47:0] local_mac   = 48'h02_00_00_00_00_00;
localparam [31:0] local_ip    = {8'd192, 8'd168, 8'd1,   8'd128};
localparam [31:0] gateway_ip  = {8'd192, 8'd168, 8'd1,   8'd1};
localparam [31:0] subnet_mask = {8'd255, 8'd255, 8'd255, 8'd0};

// Echo only UDP destination port 1234, and reply to the fixed ECHO_DEST_IP.
wire echo_match = (echo_rx_tdest[15:0] == 16'd1234);

assign echo_tx_tdata  = echo_rx_tdata;
assign echo_tx_tvalid = echo_rx_tvalid && echo_match;
assign echo_tx_tlast  = echo_rx_tlast;
assign echo_tx_tuser  = echo_rx_tuser;
assign echo_tx_tdest  = {echo_rx_tdest[15:0], echo_rx_tdest[31:16]};
assign echo_rx_tready = echo_match ? echo_tx_tready : 1'b1;

// Place first payload byte onto LEDs
reg valid_last = 0;
reg [7:0] led_reg = 0;

always @(posedge clk) begin
    if (rst) begin
        led_reg <= 0;
        valid_last <= 1'b0;
    end else begin
        if (echo_tx_tvalid) begin
            if (!valid_last) begin
                led_reg <= echo_tx_tdata;
                valid_last <= 1'b1;
            end
            if (echo_tx_tlast) begin
                valid_last <= 1'b0;
            end
        end
    end
end

//assign led = sw;
assign led = led_reg;
assign phy_reset_n = !rst;

assign uart_txd = 0;

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
    .tx_axis_tvalid(tx_axis_tvalid),
    .tx_axis_tready(tx_axis_tready),
    .tx_axis_tlast(tx_axis_tlast),
    .tx_axis_tuser(tx_axis_tuser),

    .rx_axis_tdata(rx_axis_tdata),
    .rx_axis_tvalid(rx_axis_tvalid),
    .rx_axis_tready(rx_axis_tready),
    .rx_axis_tlast(rx_axis_tlast),
    .rx_axis_tuser(rx_axis_tuser),

    .rgmii_rx_clk(phy_rx_clk),
    .rgmii_rxd(phy_rxd),
    .rgmii_rx_ctl(phy_rx_ctl),
    .rgmii_tx_clk(phy_tx_clk),
    .rgmii_txd(phy_txd),
    .rgmii_tx_ctl(phy_tx_ctl),

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

udp_axis_complete #(
    .LOCAL_MAC(local_mac),
    .LOCAL_IP(local_ip),
    .GATEWAY_IP(gateway_ip),
    .SUBNET_MASK(subnet_mask),
    .DEST_IP(ECHO_DEST_IP),
    .TX_FIFO_DEPTH(4096),
    .MAX_PAYLOAD_LEN(1472),
    .META_FIFO_DEPTH(8),
    .UDP_CHECKSUM_GEN_ENABLE(1),
    .UDP_CHECKSUM_PAYLOAD_FIFO_DEPTH(2048),
    .UDP_CHECKSUM_HEADER_FIFO_DEPTH(8),
    .ICMP_ECHO_ENABLE(1),
    .ICMP_FIFO_DEPTH(64)
) udp_axis_complete_inst (
    .clk(clk),
    .rst(rst),
    // Application TX (echo loop)
    .s_axis_tx_tdata(echo_tx_tdata),
    .s_axis_tx_tvalid(echo_tx_tvalid),
    .s_axis_tx_tready(echo_tx_tready),
    .s_axis_tx_tlast(echo_tx_tlast),
    .s_axis_tx_tuser(echo_tx_tuser),
    .s_axis_tx_tdest(echo_tx_tdest),
    // Application RX
    .m_axis_rx_tdata(echo_rx_tdata),
    .m_axis_rx_tvalid(echo_rx_tvalid),
    .m_axis_rx_tready(echo_rx_tready),
    .m_axis_rx_tlast(echo_rx_tlast),
    .m_axis_rx_tuser(echo_rx_tuser),
    .m_axis_rx_tdest(echo_rx_tdest),
    // MAC RX
    .s_eth_rx_axis_tdata(rx_axis_tdata),
    .s_eth_rx_axis_tvalid(rx_axis_tvalid),
    .s_eth_rx_axis_tready(rx_axis_tready),
    .s_eth_rx_axis_tlast(rx_axis_tlast),
    .s_eth_rx_axis_tuser(rx_axis_tuser),
    // MAC TX
    .m_eth_tx_axis_tdata(tx_axis_tdata),
    .m_eth_tx_axis_tvalid(tx_axis_tvalid),
    .m_eth_tx_axis_tready(tx_axis_tready),
    .m_eth_tx_axis_tlast(tx_axis_tlast),
    .m_eth_tx_axis_tuser(tx_axis_tuser),
    // Status
    .tx_busy(),
    .rx_busy(),
    .tx_error_overflow(),
    .tx_error_arp_failed(),
    .tx_error_payload_early_termination(),
    .rx_error_header_early_termination(),
    .rx_error_payload_early_termination(),
    .rx_error_invalid_header(),
    .rx_error_invalid_checksum(),
    .rx_drop_ip_mismatch(),
    .icmp_error_overflow(),
    .clear_arp_cache(1'b0)
);

endmodule

`resetall
