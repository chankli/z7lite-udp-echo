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
 *
 * 10/100 Mbps MII MAC + udp_axis_complete UDP echo.
 *
 * The design listens on UDP port 1234 at LOCAL_IP and echoes each payload
 * back to ECHO_DEST_IP.  ARP and ICMP echo requests are handled inside
 * udp_axis_complete.
 */
module fpga_core #
(
    parameter TARGET = "GENERIC",
    parameter [31:0] ECHO_DEST_IP = 32'hC0A8_0A64,
    parameter DEBUG_ILA = 1
)
(
    /*
     * Clock: 50 MHz
     * Synchronous reset
     */
    input  wire       clk,
    input  wire       rst,

    /*
     * LEDs (active high, top level inverts for active-low board LEDs)
     */
    output wire [1:0] led,

    /*
     * Ethernet: 10/100BASE-T MII
     */
    input  wire       phy_rx_clk,
    input  wire [3:0] phy_rxd,
    input  wire       phy_rx_dv,
    input  wire       phy_tx_clk,
    output wire [3:0] phy_txd,
    output wire       phy_tx_en,
    output wire       phy_mdc,
    inout  wire       phy_mdio,

    /*
     * Debug
     */
    input  wire       phy_reset_n,

    /*
     * Clear the ARP cache when high
     */
    input  wire       clear_arp_cache
);

// AXI between MAC and UDP stack
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

// Status for debug
wire tx_busy;
wire rx_busy;
wire tx_error_overflow;
wire tx_error_arp_failed;
wire tx_error_payload_early_termination;
wire rx_error_header_early_termination;
wire rx_error_payload_early_termination;
wire rx_error_invalid_header;
wire rx_error_invalid_checksum;
wire rx_drop_ip_mismatch;
wire icmp_error_overflow;

wire [8:0] status_dbg;

assign status_dbg = {
    tx_error_arp_failed,
    tx_error_overflow,
    tx_error_payload_early_termination,
    rx_error_header_early_termination,
    rx_error_payload_early_termination,
    rx_error_invalid_header,
    rx_error_invalid_checksum,
    rx_drop_ip_mismatch,
    icmp_error_overflow
};

// Configuration
localparam [47:0] local_mac   = 48'h02_00_00_00_00_00;
localparam [31:0] local_ip    = {8'd192, 8'd168, 8'd10,  8'd128};
localparam [31:0] gateway_ip  = {8'd192, 8'd168, 8'd10,  8'd1};
localparam [31:0] subnet_mask = {8'd255, 8'd255, 8'd255, 8'd0};

// Echo only UDP destination port 1234, and reply to the fixed ECHO_DEST_IP.
wire echo_match = (echo_rx_tdest[15:0] == 16'd1234);

assign echo_tx_tdata  = echo_rx_tdata;
assign echo_tx_tvalid = echo_rx_tvalid && echo_match;
assign echo_tx_tlast  = echo_rx_tlast;
assign echo_tx_tuser  = echo_rx_tuser;
assign echo_tx_tdest  = {echo_rx_tdest[15:0], echo_rx_tdest[31:16]};
assign echo_rx_tready = echo_match ? echo_tx_tready : 1'b1;

// Heartbeat and packet activity on the two user LEDs
reg [25:0] heartbeat_cnt = 26'd0;
reg [23:0] activity_cnt = 24'd0;

always @(posedge clk) begin
    if (rst) begin
        heartbeat_cnt <= 26'd0;
        activity_cnt <= 24'd0;
    end else begin
        heartbeat_cnt <= heartbeat_cnt + 1'b1;

        if (echo_rx_tvalid || echo_tx_tvalid) begin
            activity_cnt <= 24'hFFFFFF;
        end else if (activity_cnt != 24'd0) begin
            activity_cnt <= activity_cnt - 1'b1;
        end
    end
end

assign led = {activity_cnt != 24'd0, heartbeat_cnt[25]};

eth_mac_mii_fifo #(
    .TARGET(TARGET),
    .CLOCK_INPUT_STYLE("BUFR"),
    .ENABLE_PADDING(1),
    .MIN_FRAME_LENGTH(64),
    .TX_FIFO_DEPTH(4096),
    .TX_FRAME_FIFO(1),
    .RX_FIFO_DEPTH(4096),
    .RX_FRAME_FIFO(1)
)
eth_mac_inst (
    .rst(rst),
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

    .mii_rx_clk(phy_rx_clk),
    .mii_rxd(phy_rxd),
    .mii_rx_dv(phy_rx_dv),
    .mii_rx_er(1'b0),
    .mii_tx_clk(phy_tx_clk),
    .mii_txd(phy_txd),
    .mii_tx_en(phy_tx_en),
    .mii_tx_er(),

    .tx_error_underflow(),
    .tx_fifo_overflow(),
    .tx_fifo_bad_frame(),
    .tx_fifo_good_frame(),
    .rx_error_bad_frame(),
    .rx_error_bad_fcs(),
    .rx_fifo_overflow(),
    .rx_fifo_bad_frame(),
    .rx_fifo_good_frame(),

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
    .ICMP_FIFO_DEPTH(64),
    // 50 MHz clock: 100M cycles = 2 s, 1.5G cycles = 30 s
    .ARP_REQUEST_RETRY_COUNT(4),
    .ARP_REQUEST_RETRY_INTERVAL(100000000),
    .ARP_REQUEST_TIMEOUT(1500000000)
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
    .tx_busy(tx_busy),
    .rx_busy(rx_busy),
    .tx_error_overflow(tx_error_overflow),
    .tx_error_arp_failed(tx_error_arp_failed),
    .tx_error_payload_early_termination(tx_error_payload_early_termination),
    .rx_error_header_early_termination(rx_error_header_early_termination),
    .rx_error_payload_early_termination(rx_error_payload_early_termination),
    .rx_error_invalid_header(rx_error_invalid_header),
    .rx_error_invalid_checksum(rx_error_invalid_checksum),
    .rx_drop_ip_mismatch(rx_drop_ip_mismatch),
    .icmp_error_overflow(icmp_error_overflow),
    .clear_arp_cache(clear_arp_cache)
);

/*
 * Debug ILA
 *
 * The raw MII pins are packed into IOB flip-flops and cannot be probed
 * directly.  Adding a counter clocked by the MII clocks would also make
 * Vivado insert a BUFG on those clocks and conflict with the BUFIO used
 * by mii_phy_if.  Probe the MAC-side AXIS and UDP application signals,
 * which are all in the 50 MHz clk domain.
 *
 * probe0  : {rx_axis_tuser, tlast, tready, tvalid, tdata[7:0]}
 * probe1  : {tx_axis_tuser, tlast, tready, tvalid, tdata[7:0]}
 * probe2  : echo_rx_tdest[31:0]  {source_port, destination_port}
 * probe3  : {echo_rx_tlast, echo_rx_tuser, echo_rx_tvalid,
 *            echo_rx_tready, echo_rx_tdata[7:0]}
 * probe4  : echo_tx_tdest[31:0]
 * probe5  : {echo_tx_tlast, echo_tx_tuser, echo_tx_tvalid,
 *            echo_tx_tready, echo_tx_tdata[7:0]}
 * probe6  : {arp_failed, tx_overflow, tx_early_term, rx_hdr_early_term,
 *            rx_payload_early_term, rx_invalid_hdr, rx_invalid_csum,
 *            rx_ip_mismatch, icmp_overflow}
 * probe7  : {tx_busy, rx_busy, phy_reset_n, rst, led[1:0]}
 * probe8  : {mac_mii_rx_dv, mac_mii_rxd[3:0]}  (registered MII RX,
 *            after the IOB flip-flops inside eth_mac_mii)
 * probe9  : dbg_mii_rx_clk_cnt[11:8]  (shows whether the PHY RXC is running)
 * probe10 : dbg_mii_tx_clk_cnt[11:8]  (shows whether the PHY TXC is running;
 *            also distinguishes 25 MHz MII TXC from 50 MHz RMII REF_CLK)
 * probe11 : {phy_rmsr[15:0], phy_bmsr[15:0]}
 * probe12 : {mdio_state[2:0], mdio_busy, mdio_done, mdio_start, mdio_we}
 */

// Free-running counters in the MII clock domains.  They are clocked by the
// BUFR/BUFG outputs inside eth_mac_mii, so they do not add a BUFG on the
// MII pins.
reg [15:0] dbg_mii_rx_clk_cnt = 16'd0;
reg [15:0] dbg_mii_tx_clk_cnt = 16'd0;

always @(posedge eth_mac_inst.rx_clk) begin
    dbg_mii_rx_clk_cnt <= dbg_mii_rx_clk_cnt + 1'b1;
end

always @(posedge eth_mac_inst.tx_clk) begin
    dbg_mii_tx_clk_cnt <= dbg_mii_tx_clk_cnt + 1'b1;
end

/*
 * MDIO master: read the RTL8201F RMII mode register and force MII mode
 * if the PHY was strapped into RMII mode.  In RMII mode TXC is an input,
 * so the MII clocks are dead and the MAC never sees any data.
 */
wire        mdio_i = phy_mdio;
wire        mdio_oe;
wire        mdio_busy;
wire        mdio_done;
wire [15:0] mdio_rdata;

reg         mdio_start;
reg  [4:0]  mdio_reg;
reg  [15:0] mdio_wdata;
reg         mdio_we;
reg  [15:0] phy_rmsr;
reg  [15:0] phy_bmsr;
reg  [2:0]  mdio_state;
reg  [15:0] mdio_delay_cnt;

localparam MDIO_IDLE     = 3'd0;
localparam MDIO_WR_PAGE  = 3'd1;
localparam MDIO_RD_RMSR  = 3'd2;
localparam MDIO_WR_RMSR  = 3'd3;
localparam MDIO_WR_PAGE0 = 3'd4;
localparam MDIO_RD_BMSR  = 3'd5;
localparam MDIO_DELAY    = 3'd6;

assign phy_mdio = mdio_oe ? 1'b0 : 1'bz;

always @(posedge clk) begin
    if (rst) begin
        mdio_state <= MDIO_IDLE;
        mdio_delay_cnt <= 16'd0;
        mdio_start <= 1'b0;
        mdio_reg <= 5'd0;
        mdio_wdata <= 16'd0;
        mdio_we <= 1'b0;
        phy_rmsr <= 16'd0;
        phy_bmsr <= 16'd0;
    end else begin
        mdio_start <= 1'b0;

        if (mdio_delay_cnt != 16'd50000) begin
            mdio_delay_cnt <= mdio_delay_cnt + 1'b1;
        end

        case (mdio_state)
        MDIO_IDLE: begin
            if (mdio_delay_cnt == 16'd50000) begin
                // select page 7
                mdio_state <= MDIO_WR_PAGE;
                mdio_reg <= 5'd31;
                mdio_wdata <= 16'd7;
                mdio_we <= 1'b1;
                mdio_start <= 1'b1;
            end
        end
        MDIO_WR_PAGE: begin
            if (mdio_done) begin
                // read RMII Mode Setting Register
                mdio_state <= MDIO_RD_RMSR;
                mdio_reg <= 5'd16;
                mdio_wdata <= 16'd0;
                mdio_we <= 1'b0;
                mdio_start <= 1'b1;
            end
        end
        MDIO_RD_RMSR: begin
            if (mdio_done) begin
                phy_rmsr <= mdio_rdata;
                if (mdio_rdata[3]) begin
                    // RMII mode: clear bit 3 to select MII
                    mdio_state <= MDIO_WR_RMSR;
                    mdio_reg <= 5'd16;
                    mdio_wdata <= mdio_rdata & 16'hFFF7;
                    mdio_we <= 1'b1;
                end else begin
                    // already MII
                    mdio_state <= MDIO_WR_PAGE0;
                    mdio_reg <= 5'd31;
                    mdio_wdata <= 16'd0;
                    mdio_we <= 1'b1;
                end
                mdio_start <= 1'b1;
            end
        end
        MDIO_WR_RMSR: begin
            if (mdio_done) begin
                // back to page 0
                mdio_state <= MDIO_WR_PAGE0;
                mdio_reg <= 5'd31;
                mdio_wdata <= 16'd0;
                mdio_we <= 1'b1;
                mdio_start <= 1'b1;
            end
        end
        MDIO_WR_PAGE0: begin
            if (mdio_done) begin
                // read BMSR
                mdio_state <= MDIO_RD_BMSR;
                mdio_reg <= 5'd1;
                mdio_wdata <= 16'd0;
                mdio_we <= 1'b0;
                mdio_start <= 1'b1;
            end
        end
        MDIO_RD_BMSR: begin
            if (mdio_done) begin
                phy_bmsr <= mdio_rdata;
                mdio_state <= MDIO_DELAY;
                mdio_delay_cnt <= 16'd0;
            end
        end
        MDIO_DELAY: begin
            if (mdio_delay_cnt == 16'd50000) begin
                mdio_state <= MDIO_RD_BMSR;
                mdio_reg <= 5'd1;
                mdio_we <= 1'b0;
                mdio_start <= 1'b1;
                mdio_delay_cnt <= 16'd0;
            end
        end
        default: mdio_state <= MDIO_IDLE;
        endcase
    end
end

mdio_master #(
    .CLK_DIV(25)
)
mdio_master_inst (
    .clk(clk),
    .rst(rst),
    .start(mdio_start),
    .phy_addr(5'b00001),
    .reg_addr(mdio_reg),
    .write_data(mdio_wdata),
    .write_en(mdio_we),
    .busy(mdio_busy),
    .done(mdio_done),
    .read_data(mdio_rdata),
    .mdc(phy_mdc),
    .mdio_oe(mdio_oe),
    .mdio_o(),
    .mdio_i(mdio_i)
);

generate
if (DEBUG_ILA) begin : g_debug_ila

    ila_0 ila_inst (
        .clk(clk),
        .probe0({rx_axis_tuser, rx_axis_tlast, rx_axis_tready, rx_axis_tvalid, rx_axis_tdata}),
        .probe1({tx_axis_tuser, tx_axis_tlast, tx_axis_tready, tx_axis_tvalid, tx_axis_tdata}),
        .probe2(echo_rx_tdest),
        .probe3({echo_rx_tlast, echo_rx_tuser, echo_rx_tvalid, echo_rx_tready, echo_rx_tdata}),
        .probe4(echo_tx_tdest),
        .probe5({echo_tx_tlast, echo_tx_tuser, echo_tx_tvalid, echo_tx_tready, echo_tx_tdata}),
        .probe6(status_dbg),
        .probe7({tx_busy, rx_busy, phy_reset_n, rst, led}),
        .probe8({eth_mac_inst.eth_mac_1g_mii_inst.mac_mii_rx_dv,
                 eth_mac_inst.eth_mac_1g_mii_inst.mac_mii_rxd}),
        .probe9(dbg_mii_rx_clk_cnt[11:8]),
        .probe10(dbg_mii_tx_clk_cnt[11:8]),
        .probe11({phy_rmsr, phy_bmsr}),
        .probe12({mdio_state, mdio_busy, mdio_done, mdio_start, mdio_we})
    );

end
endgenerate

endmodule

`resetall
