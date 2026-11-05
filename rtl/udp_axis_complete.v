`resetall
`timescale 1ns / 1ps
`default_nettype none

module udp_axis_complete #(
    parameter [47:0] LOCAL_MAC = 48'h02_00_00_00_00_01,
    parameter [31:0] LOCAL_IP = 32'hC0A8_0180,
    parameter [31:0] GATEWAY_IP = 32'hC0A8_0101,
    parameter [31:0] SUBNET_MASK = 32'hFF_FF_FF_00,
    parameter [31:0] DEST_IP = 32'hC0A8_0164,
    parameter TX_FIFO_DEPTH = 4096,
    parameter MAX_PAYLOAD_LEN = 1472,
    parameter META_FIFO_DEPTH = 8,
    parameter UDP_CHECKSUM_GEN_ENABLE = 1,
    parameter UDP_CHECKSUM_PAYLOAD_FIFO_DEPTH = 2048,
    parameter UDP_CHECKSUM_HEADER_FIFO_DEPTH = 8,
    parameter ICMP_ECHO_ENABLE = 1,
    parameter ICMP_FIFO_DEPTH = 64,
    parameter ARP_CACHE_ADDR_WIDTH = 9,
    parameter ARP_REQUEST_RETRY_COUNT = 4,
    parameter ARP_REQUEST_RETRY_INTERVAL = 125000000*2,
    parameter ARP_REQUEST_TIMEOUT = 125000000*30
) (
    input  wire        clk,
    input  wire        rst,
    input  wire [7:0]  s_axis_tx_tdata,
    input  wire        s_axis_tx_tvalid,
    output wire        s_axis_tx_tready,
    input  wire        s_axis_tx_tlast,
    input  wire        s_axis_tx_tuser,
    input  wire [31:0] s_axis_tx_tdest,
    output wire [7:0]  m_axis_rx_tdata,
    output wire        m_axis_rx_tvalid,
    input  wire        m_axis_rx_tready,
    output wire        m_axis_rx_tlast,
    output wire        m_axis_rx_tuser,
    output wire [31:0] m_axis_rx_tdest,
    input  wire [7:0]  s_eth_rx_axis_tdata,
    input  wire        s_eth_rx_axis_tvalid,
    output wire        s_eth_rx_axis_tready,
    input  wire        s_eth_rx_axis_tlast,
    input  wire        s_eth_rx_axis_tuser,
    output wire [7:0]  m_eth_tx_axis_tdata,
    output wire        m_eth_tx_axis_tvalid,
    input  wire        m_eth_tx_axis_tready,
    output wire        m_eth_tx_axis_tlast,
    output wire        m_eth_tx_axis_tuser,
    output wire        tx_busy,
    output wire        rx_busy,
    output wire        tx_error_overflow,
    output wire        tx_error_arp_failed,
    output wire        tx_error_payload_early_termination,
    output wire        rx_error_header_early_termination,
    output wire        rx_error_payload_early_termination,
    output wire        rx_error_invalid_header,
    output wire        rx_error_invalid_checksum,
    output wire        rx_drop_ip_mismatch,
    output wire        icmp_error_overflow,
    input  wire        clear_arp_cache
);

localparam LEN_WIDTH = $clog2(MAX_PAYLOAD_LEN+1);
localparam DEPTH_WIDTH = $clog2(TX_FIFO_DEPTH)+1;

initial begin
    if (MAX_PAYLOAD_LEN > TX_FIFO_DEPTH) begin
        $error("MAX_PAYLOAD_LEN must be <= TX_FIFO_DEPTH");
        $finish;
    end
    if ((TX_FIFO_DEPTH & (TX_FIFO_DEPTH-1)) != 0) begin
        $error("TX_FIFO_DEPTH must be a power of two");
        $finish;
    end
    if (UDP_CHECKSUM_GEN_ENABLE && (UDP_CHECKSUM_PAYLOAD_FIFO_DEPTH < MAX_PAYLOAD_LEN+8)) begin
        $error("UDP_CHECKSUM_PAYLOAD_FIFO_DEPTH too small");
        $finish;
    end
end

/*
 * TX data FIFO
 */
wire [7:0]  tx_data_fifo_s_tdata;
wire        tx_data_fifo_s_tvalid;
wire        tx_data_fifo_s_tready;
wire [7:0]  tx_data_fifo_m_tdata;
wire        tx_data_fifo_m_tvalid;
wire        tx_data_fifo_m_tready;
wire [DEPTH_WIDTH-1:0] tx_data_fifo_depth;

axis_fifo #(
    .DEPTH(TX_FIFO_DEPTH),
    .DATA_WIDTH(8),
    .KEEP_ENABLE(0),
    .KEEP_WIDTH(1),
    .LAST_ENABLE(0),
    .ID_ENABLE(0),
    .DEST_ENABLE(0),
    .USER_ENABLE(0),
    .RAM_PIPELINE(1),
    .OUTPUT_FIFO_ENABLE(0),
    .FRAME_FIFO(0)
) tx_data_fifo_inst (
    .clk(clk),
    .rst(rst),
    .s_axis_tdata(tx_data_fifo_s_tdata),
    .s_axis_tkeep(1'b1),
    .s_axis_tvalid(tx_data_fifo_s_tvalid),
    .s_axis_tready(tx_data_fifo_s_tready),
    .s_axis_tlast(1'b0),
    .s_axis_tid(8'd0),
    .s_axis_tdest(8'd0),
    .s_axis_tuser(1'b0),
    .m_axis_tdata(tx_data_fifo_m_tdata),
    .m_axis_tkeep(),
    .m_axis_tvalid(tx_data_fifo_m_tvalid),
    .m_axis_tready(tx_data_fifo_m_tready),
    .m_axis_tlast(),
    .m_axis_tid(),
    .m_axis_tdest(),
    .m_axis_tuser(),
    .pause_req(1'b0),
    .pause_ack(),
    .status_depth(tx_data_fifo_depth),
    .status_depth_commit(),
    .status_overflow(),
    .status_bad_frame(),
    .status_good_frame()
);

/*
 * TX metadata FIFO
 */
wire [LEN_WIDTH-1:0] meta_s_tdata;
wire [31:0]          meta_s_tdest;
wire                 meta_s_tvalid;
wire                 meta_s_tready;
wire                 meta_s_tlast;
wire                 meta_s_tuser;
wire [LEN_WIDTH-1:0] meta_m_tdata;
wire [31:0]          meta_m_tdest;
wire                 meta_m_tvalid;
wire                 meta_m_tready;
wire                 meta_m_tlast;
wire                 meta_m_tuser;

axis_srl_fifo #(
    .DATA_WIDTH(LEN_WIDTH),
    .KEEP_ENABLE(0),
    .KEEP_WIDTH(1),
    .LAST_ENABLE(1),
    .ID_ENABLE(0),
    .ID_WIDTH(1),
    .DEST_ENABLE(1),
    .DEST_WIDTH(32),
    .USER_ENABLE(1),
    .USER_WIDTH(1),
    .DEPTH(META_FIFO_DEPTH)
) meta_fifo_inst (
    .clk(clk),
    .rst(rst),
    .s_axis_tdata(meta_s_tdata),
    .s_axis_tkeep(1'b1),
    .s_axis_tvalid(meta_s_tvalid),
    .s_axis_tready(meta_s_tready),
    .s_axis_tlast(meta_s_tlast),
    .s_axis_tid(1'b0),
    .s_axis_tdest(meta_s_tdest),
    .s_axis_tuser(meta_s_tuser),
    .m_axis_tdata(meta_m_tdata),
    .m_axis_tkeep(),
    .m_axis_tvalid(meta_m_tvalid),
    .m_axis_tready(meta_m_tready),
    .m_axis_tlast(meta_m_tlast),
    .m_axis_tid(),
    .m_axis_tdest(meta_m_tdest),
    .m_axis_tuser(meta_m_tuser),
    .count()
);

/*
 * TX write side
 */
localparam WR_IDLE = 2'd0;
localparam WR_ACTIVE = 2'd1;
localparam WR_OVERFLOW = 2'd2;

reg [1:0] wr_state = WR_IDLE;
reg [LEN_WIDTH-1:0] wr_len = 0;
reg [31:0] wr_tdest = 0;
reg wr_tuser = 0;

reg meta_push;
reg [LEN_WIDTH-1:0] meta_push_len;
reg [31:0] meta_push_tdest;
reg meta_push_tuser;
reg meta_push_drop;

wire fifo_admit = (tx_data_fifo_depth <= (TX_FIFO_DEPTH - MAX_PAYLOAD_LEN));

assign s_axis_tx_tready = (wr_state == WR_IDLE) ? (fifo_admit && tx_data_fifo_s_tready && meta_s_tready) :
                          (wr_state == WR_ACTIVE) ? tx_data_fifo_s_tready : 1'b1;

assign tx_data_fifo_s_tdata = s_axis_tx_tdata;
assign tx_data_fifo_s_tvalid = s_axis_tx_tvalid && s_axis_tx_tready && (wr_state != WR_OVERFLOW);

always @* begin
    meta_push = 1'b0;
    meta_push_len = wr_len;
    meta_push_tdest = (wr_state == WR_IDLE) ? s_axis_tx_tdest : wr_tdest;
    meta_push_tuser = wr_tuser;
    meta_push_drop = 1'b0;
    if (s_axis_tx_tvalid && s_axis_tx_tready) begin
        case (wr_state)
            WR_IDLE: if (s_axis_tx_tlast) begin
                meta_push = 1'b1;
                meta_push_len = 1;
                meta_push_tuser = s_axis_tx_tuser;
                meta_push_drop = 1'b0;
            end
            WR_ACTIVE: if (s_axis_tx_tlast) begin
                meta_push = 1'b1;
                meta_push_len = wr_len + 1;
                meta_push_tuser = wr_tuser | s_axis_tx_tuser;
                meta_push_drop = 1'b0;
            end
            WR_OVERFLOW: if (s_axis_tx_tlast) begin
                meta_push = 1'b1;
                meta_push_len = MAX_PAYLOAD_LEN;
                meta_push_tuser = 1'b0;
                meta_push_drop = 1'b1;
            end
            default: ;
        endcase
    end
end

assign meta_s_tvalid = meta_push;
assign meta_s_tdata = meta_push_len;
assign meta_s_tdest = meta_push_tdest;
assign meta_s_tuser = meta_push_tuser;
assign meta_s_tlast = meta_push_drop;

always @(posedge clk) begin
    if (rst) begin
        wr_state <= WR_IDLE;
        wr_len <= 0;
        wr_tdest <= 0;
        wr_tuser <= 0;
    end else if (s_axis_tx_tvalid && s_axis_tx_tready) begin
        case (wr_state)
            WR_IDLE: begin
                wr_tdest <= s_axis_tx_tdest;
                wr_tuser <= s_axis_tx_tuser;
                wr_len <= 1;
                wr_state <= s_axis_tx_tlast ? WR_IDLE : WR_ACTIVE;
            end
            WR_ACTIVE: begin
                wr_tuser <= wr_tuser | s_axis_tx_tuser;
                wr_len <= wr_len + 1;
                if (s_axis_tx_tlast) wr_state <= WR_IDLE;
                else if (wr_len + 1 == MAX_PAYLOAD_LEN) wr_state <= WR_OVERFLOW;
            end
            WR_OVERFLOW: begin
                if (s_axis_tx_tlast) wr_state <= WR_IDLE;
            end
            default: wr_state <= WR_IDLE;
        endcase
    end
end

/*
 * TX read side
 */
localparam RD_IDLE = 2'd0;
localparam RD_HDR = 2'd1;
localparam RD_SEND = 2'd2;
localparam RD_DROP = 2'd3;

reg [1:0] rd_state = RD_IDLE;
reg [LEN_WIDTH-1:0] rd_len = 0;
reg [31:0] rd_tdest = 0;
reg rd_tuser = 0;
reg rd_drop = 0;
reg [LEN_WIDTH-1:0] rd_cnt = 0;

wire [15:0] rd_src_port = rd_tdest[31:16];
wire [15:0] rd_dst_port = rd_tdest[15:0];

wire        s_udp_hdr_valid;
wire        s_udp_hdr_ready;
wire [5:0]  s_udp_ip_dscp;
wire [1:0]  s_udp_ip_ecn;
wire [7:0]  s_udp_ip_ttl;
wire [31:0] s_udp_ip_source_ip;
wire [31:0] s_udp_ip_dest_ip;
wire [15:0] s_udp_source_port;
wire [15:0] s_udp_dest_port;
wire [15:0] s_udp_length;
wire [15:0] s_udp_checksum;
wire [7:0]  s_udp_payload_axis_tdata;
wire        s_udp_payload_axis_tvalid;
wire        s_udp_payload_axis_tready;
wire        s_udp_payload_axis_tlast;
wire        s_udp_payload_axis_tuser;

assign meta_m_tready = (rd_state == RD_IDLE);

assign s_udp_hdr_valid = (rd_state == RD_HDR);
assign s_udp_ip_dscp = 6'd0;
assign s_udp_ip_ecn = 2'd0;
assign s_udp_ip_ttl = 8'd64;
assign s_udp_ip_source_ip = LOCAL_IP;
assign s_udp_ip_dest_ip = DEST_IP;
assign s_udp_source_port = rd_src_port;
assign s_udp_dest_port = rd_dst_port;
assign s_udp_length = rd_len + 16'd8;
assign s_udp_checksum = 16'd0;

assign s_udp_payload_axis_tdata = tx_data_fifo_m_tdata;
assign s_udp_payload_axis_tvalid = (rd_state == RD_SEND) ? tx_data_fifo_m_tvalid : 1'b0;
assign s_udp_payload_axis_tlast = (rd_state == RD_SEND) ? (rd_cnt == rd_len - 1) : 1'b0;
assign s_udp_payload_axis_tuser = (rd_state == RD_SEND) ? (rd_tuser && (rd_cnt == rd_len - 1)) : 1'b0;
assign tx_data_fifo_m_tready = (rd_state == RD_SEND) ? s_udp_payload_axis_tready :
                               (rd_state == RD_DROP) ? 1'b1 : 1'b0;

assign tx_error_overflow = (rd_state == RD_DROP) && tx_data_fifo_m_tvalid && (rd_cnt == rd_len - 1);

always @(posedge clk) begin
    if (rst) begin
        rd_state <= RD_IDLE;
        rd_len <= 0;
        rd_tdest <= 0;
        rd_tuser <= 0;
        rd_drop <= 0;
        rd_cnt <= 0;
    end else begin
        case (rd_state)
            RD_IDLE: begin
                if (meta_m_tvalid) begin
                    rd_len <= meta_m_tdata;
                    rd_tdest <= meta_m_tdest;
                    rd_tuser <= meta_m_tuser;
                    rd_drop <= meta_m_tlast;
                    rd_cnt <= 0;
                    rd_state <= meta_m_tlast ? RD_DROP : RD_HDR;
                end
            end
            RD_HDR: begin
                if (s_udp_hdr_ready) begin
                    rd_cnt <= 0;
                    rd_state <= RD_SEND;
                end
            end
            RD_SEND: begin
                if (tx_data_fifo_m_tvalid && s_udp_payload_axis_tready) begin
                    if (rd_cnt == rd_len - 1) rd_state <= RD_IDLE;
                    else rd_cnt <= rd_cnt + 1;
                end
            end
            RD_DROP: begin
                if (tx_data_fifo_m_tvalid) begin
                    if (rd_cnt == rd_len - 1) rd_state <= RD_IDLE;
                    else rd_cnt <= rd_cnt + 1;
                end
            end
            default: rd_state <= RD_IDLE;
        endcase
    end
end

assign tx_busy = (wr_state != WR_IDLE) || (rd_state != RD_IDLE) || meta_m_tvalid;

/*
 * Ethernet AXIS <-> udp_complete
 */
wire        eth_rx_hdr_valid;
wire        eth_rx_hdr_ready;
wire [47:0] eth_rx_dest_mac;
wire [47:0] eth_rx_src_mac;
wire [15:0] eth_rx_type;
wire [7:0]  eth_rx_payload_axis_tdata;
wire        eth_rx_payload_axis_tvalid;
wire        eth_rx_payload_axis_tready;
wire        eth_rx_payload_axis_tlast;
wire        eth_rx_payload_axis_tuser;
wire        eth_rx_error_header_early_termination;

wire        eth_tx_hdr_valid;
wire        eth_tx_hdr_ready;
wire [47:0] eth_tx_dest_mac;
wire [47:0] eth_tx_src_mac;
wire [15:0] eth_tx_type;
wire [7:0]  eth_tx_payload_axis_tdata;
wire        eth_tx_payload_axis_tvalid;
wire        eth_tx_payload_axis_tready;
wire        eth_tx_payload_axis_tlast;
wire        eth_tx_payload_axis_tuser;

eth_axis_rx #(
    .DATA_WIDTH(8),
    .KEEP_ENABLE(0),
    .KEEP_WIDTH(1)
) eth_axis_rx_inst (
    .clk(clk),
    .rst(rst),
    .s_axis_tdata(s_eth_rx_axis_tdata),
    .s_axis_tkeep(1'b1),
    .s_axis_tvalid(s_eth_rx_axis_tvalid),
    .s_axis_tready(s_eth_rx_axis_tready),
    .s_axis_tlast(s_eth_rx_axis_tlast),
    .s_axis_tuser(s_eth_rx_axis_tuser),
    .m_eth_hdr_valid(eth_rx_hdr_valid),
    .m_eth_hdr_ready(eth_rx_hdr_ready),
    .m_eth_dest_mac(eth_rx_dest_mac),
    .m_eth_src_mac(eth_rx_src_mac),
    .m_eth_type(eth_rx_type),
    .m_eth_payload_axis_tdata(eth_rx_payload_axis_tdata),
    .m_eth_payload_axis_tkeep(),
    .m_eth_payload_axis_tvalid(eth_rx_payload_axis_tvalid),
    .m_eth_payload_axis_tready(eth_rx_payload_axis_tready),
    .m_eth_payload_axis_tlast(eth_rx_payload_axis_tlast),
    .m_eth_payload_axis_tuser(eth_rx_payload_axis_tuser),
    .busy(),
    .error_header_early_termination(eth_rx_error_header_early_termination)
);

eth_axis_tx #(
    .DATA_WIDTH(8),
    .KEEP_ENABLE(0),
    .KEEP_WIDTH(1)
) eth_axis_tx_inst (
    .clk(clk),
    .rst(rst),
    .s_eth_hdr_valid(eth_tx_hdr_valid),
    .s_eth_hdr_ready(eth_tx_hdr_ready),
    .s_eth_dest_mac(eth_tx_dest_mac),
    .s_eth_src_mac(eth_tx_src_mac),
    .s_eth_type(eth_tx_type),
    .s_eth_payload_axis_tdata(eth_tx_payload_axis_tdata),
    .s_eth_payload_axis_tkeep(1'b1),
    .s_eth_payload_axis_tvalid(eth_tx_payload_axis_tvalid),
    .s_eth_payload_axis_tready(eth_tx_payload_axis_tready),
    .s_eth_payload_axis_tlast(eth_tx_payload_axis_tlast),
    .s_eth_payload_axis_tuser(eth_tx_payload_axis_tuser),
    .m_axis_tdata(m_eth_tx_axis_tdata),
    .m_axis_tkeep(),
    .m_axis_tvalid(m_eth_tx_axis_tvalid),
    .m_axis_tready(m_eth_tx_axis_tready),
    .m_axis_tlast(m_eth_tx_axis_tlast),
    .m_axis_tuser(m_eth_tx_axis_tuser),
    .busy()
);

/*
 * UDP complete
 */
wire        udp_s_udp_hdr_valid;
wire        udp_s_udp_hdr_ready;
wire [5:0]  udp_s_udp_ip_dscp;
wire [1:0]  udp_s_udp_ip_ecn;
wire [7:0]  udp_s_udp_ip_ttl;
wire [31:0] udp_s_udp_ip_source_ip;
wire [31:0] udp_s_udp_ip_dest_ip;
wire [15:0] udp_s_udp_source_port;
wire [15:0] udp_s_udp_dest_port;
wire [15:0] udp_s_udp_length;
wire [15:0] udp_s_udp_checksum;
wire [7:0]  udp_s_udp_payload_axis_tdata;
wire        udp_s_udp_payload_axis_tvalid;
wire        udp_s_udp_payload_axis_tready;
wire        udp_s_udp_payload_axis_tlast;
wire        udp_s_udp_payload_axis_tuser;

wire        udp_m_udp_hdr_valid;
wire        udp_m_udp_hdr_ready;
wire [31:0] udp_m_udp_ip_dest_ip;
wire [15:0] udp_m_udp_source_port;
wire [15:0] udp_m_udp_dest_port;
wire [7:0]  udp_m_udp_payload_axis_tdata;
wire        udp_m_udp_payload_axis_tvalid;
wire        udp_m_udp_payload_axis_tready;
wire        udp_m_udp_payload_axis_tlast;
wire        udp_m_udp_payload_axis_tuser;

wire        udp_ip_tx_error_arp_failed;
wire        udp_udp_tx_error_payload_early_termination;
wire        udp_udp_rx_error_header_early_termination;
wire        udp_udp_rx_error_payload_early_termination;
wire        udp_ip_rx_error_invalid_header;
wire        udp_ip_rx_error_invalid_checksum;

wire        udp_s_ip_hdr_valid;
wire        udp_s_ip_hdr_ready;
wire [5:0]  udp_s_ip_dscp;
wire [1:0]  udp_s_ip_ecn;
wire [15:0] udp_s_ip_length;
wire [7:0]  udp_s_ip_ttl;
wire [7:0]  udp_s_ip_protocol;
wire [31:0] udp_s_ip_source_ip;
wire [31:0] udp_s_ip_dest_ip;
wire [7:0]  udp_s_ip_payload_axis_tdata;
wire        udp_s_ip_payload_axis_tvalid;
wire        udp_s_ip_payload_axis_tready;
wire        udp_s_ip_payload_axis_tlast;
wire        udp_s_ip_payload_axis_tuser;

wire        udp_m_ip_hdr_valid;
wire        udp_m_ip_hdr_ready;
wire [3:0]  udp_m_ip_ihl;
wire [15:0] udp_m_ip_length;
wire [7:0]  udp_m_ip_ttl;
wire [7:0]  udp_m_ip_protocol;
wire [31:0] udp_m_ip_source_ip;
wire [31:0] udp_m_ip_dest_ip;
wire [2:0]  udp_m_ip_flags;
wire [12:0] udp_m_ip_fragment_offset;
wire [7:0]  udp_m_ip_payload_axis_tdata;
wire        udp_m_ip_payload_axis_tvalid;
wire        udp_m_ip_payload_axis_tready;
wire        udp_m_ip_payload_axis_tlast;
wire        udp_m_ip_payload_axis_tuser;

assign udp_s_udp_hdr_valid = s_udp_hdr_valid;
assign s_udp_hdr_ready = udp_s_udp_hdr_ready;
assign udp_s_udp_ip_dscp = s_udp_ip_dscp;
assign udp_s_udp_ip_ecn = s_udp_ip_ecn;
assign udp_s_udp_ip_ttl = s_udp_ip_ttl;
assign udp_s_udp_ip_source_ip = s_udp_ip_source_ip;
assign udp_s_udp_ip_dest_ip = s_udp_ip_dest_ip;
assign udp_s_udp_source_port = s_udp_source_port;
assign udp_s_udp_dest_port = s_udp_dest_port;
assign udp_s_udp_length = s_udp_length;
assign udp_s_udp_checksum = s_udp_checksum;
assign udp_s_udp_payload_axis_tdata = s_udp_payload_axis_tdata;
assign udp_s_udp_payload_axis_tvalid = s_udp_payload_axis_tvalid;
assign s_udp_payload_axis_tready = udp_s_udp_payload_axis_tready;
assign udp_s_udp_payload_axis_tlast = s_udp_payload_axis_tlast;
assign udp_s_udp_payload_axis_tuser = s_udp_payload_axis_tuser;

wire        icmp_s_ip_hdr_ready;
wire        icmp_s_ip_payload_axis_tready;
wire        icmp_m_ip_hdr_valid;
wire [5:0]  icmp_m_ip_dscp;
wire [1:0]  icmp_m_ip_ecn;
wire [15:0] icmp_m_ip_length;
wire [7:0]  icmp_m_ip_ttl;
wire [7:0]  icmp_m_ip_protocol;
wire [31:0] icmp_m_ip_source_ip;
wire [31:0] icmp_m_ip_dest_ip;
wire [7:0]  icmp_m_ip_payload_axis_tdata;
wire        icmp_m_ip_payload_axis_tvalid;
wire        icmp_m_ip_payload_axis_tlast;
wire        icmp_m_ip_payload_axis_tuser;

generate
if (ICMP_ECHO_ENABLE) begin : g_icmp
    icmp_echo #(
        .LOCAL_IP(LOCAL_IP),
        .FIFO_DEPTH(ICMP_FIFO_DEPTH)
    ) icmp_echo_inst (
        .clk(clk),
        .rst(rst),
        .s_ip_hdr_valid(udp_m_ip_hdr_valid),
        .s_ip_hdr_ready(icmp_s_ip_hdr_ready),
        .s_ip_ihl(udp_m_ip_ihl),
        .s_ip_length(udp_m_ip_length),
        .s_ip_ttl(udp_m_ip_ttl),
        .s_ip_protocol(udp_m_ip_protocol),
        .s_ip_source_ip(udp_m_ip_source_ip),
        .s_ip_dest_ip(udp_m_ip_dest_ip),
        .s_ip_flags(udp_m_ip_flags),
        .s_ip_fragment_offset(udp_m_ip_fragment_offset),
        .s_ip_payload_axis_tdata(udp_m_ip_payload_axis_tdata),
        .s_ip_payload_axis_tvalid(udp_m_ip_payload_axis_tvalid),
        .s_ip_payload_axis_tready(icmp_s_ip_payload_axis_tready),
        .s_ip_payload_axis_tlast(udp_m_ip_payload_axis_tlast),
        .s_ip_payload_axis_tuser(udp_m_ip_payload_axis_tuser),
        .m_ip_hdr_valid(icmp_m_ip_hdr_valid),
        .m_ip_hdr_ready(udp_s_ip_hdr_ready),
        .m_ip_dscp(icmp_m_ip_dscp),
        .m_ip_ecn(icmp_m_ip_ecn),
        .m_ip_length(icmp_m_ip_length),
        .m_ip_ttl(icmp_m_ip_ttl),
        .m_ip_protocol(icmp_m_ip_protocol),
        .m_ip_source_ip(icmp_m_ip_source_ip),
        .m_ip_dest_ip(icmp_m_ip_dest_ip),
        .m_ip_payload_axis_tdata(icmp_m_ip_payload_axis_tdata),
        .m_ip_payload_axis_tvalid(icmp_m_ip_payload_axis_tvalid),
        .m_ip_payload_axis_tready(udp_s_ip_payload_axis_tready),
        .m_ip_payload_axis_tlast(icmp_m_ip_payload_axis_tlast),
        .m_ip_payload_axis_tuser(icmp_m_ip_payload_axis_tuser),
        .busy(),
        .error_overflow(icmp_error_overflow)
    );
    assign udp_m_ip_hdr_ready = icmp_s_ip_hdr_ready;
    assign udp_m_ip_payload_axis_tready = icmp_s_ip_payload_axis_tready;
    assign udp_s_ip_hdr_valid = icmp_m_ip_hdr_valid;
    assign udp_s_ip_dscp = icmp_m_ip_dscp;
    assign udp_s_ip_ecn = icmp_m_ip_ecn;
    assign udp_s_ip_length = icmp_m_ip_length;
    assign udp_s_ip_ttl = icmp_m_ip_ttl;
    assign udp_s_ip_protocol = icmp_m_ip_protocol;
    assign udp_s_ip_source_ip = icmp_m_ip_source_ip;
    assign udp_s_ip_dest_ip = icmp_m_ip_dest_ip;
    assign udp_s_ip_payload_axis_tdata = icmp_m_ip_payload_axis_tdata;
    assign udp_s_ip_payload_axis_tvalid = icmp_m_ip_payload_axis_tvalid;
    assign udp_s_ip_payload_axis_tlast = icmp_m_ip_payload_axis_tlast;
    assign udp_s_ip_payload_axis_tuser = icmp_m_ip_payload_axis_tuser;
end else begin : g_no_icmp
    assign udp_m_ip_hdr_ready = 1'b1;
    assign udp_m_ip_payload_axis_tready = 1'b1;
    assign udp_s_ip_hdr_valid = 1'b0;
    assign udp_s_ip_dscp = 6'd0;
    assign udp_s_ip_ecn = 2'd0;
    assign udp_s_ip_length = 16'd0;
    assign udp_s_ip_ttl = 8'd0;
    assign udp_s_ip_protocol = 8'd0;
    assign udp_s_ip_source_ip = 32'd0;
    assign udp_s_ip_dest_ip = 32'd0;
    assign udp_s_ip_payload_axis_tdata = 8'd0;
    assign udp_s_ip_payload_axis_tvalid = 1'b0;
    assign udp_s_ip_payload_axis_tlast = 1'b0;
    assign udp_s_ip_payload_axis_tuser = 1'b0;
    assign icmp_error_overflow = 1'b0;
end
endgenerate

udp_complete #(
    .ARP_CACHE_ADDR_WIDTH(ARP_CACHE_ADDR_WIDTH),
    .ARP_REQUEST_RETRY_COUNT(ARP_REQUEST_RETRY_COUNT),
    .ARP_REQUEST_RETRY_INTERVAL(ARP_REQUEST_RETRY_INTERVAL),
    .ARP_REQUEST_TIMEOUT(ARP_REQUEST_TIMEOUT),
    .UDP_CHECKSUM_GEN_ENABLE(UDP_CHECKSUM_GEN_ENABLE),
    .UDP_CHECKSUM_PAYLOAD_FIFO_DEPTH(UDP_CHECKSUM_PAYLOAD_FIFO_DEPTH),
    .UDP_CHECKSUM_HEADER_FIFO_DEPTH(UDP_CHECKSUM_HEADER_FIFO_DEPTH)
) udp_complete_inst (
    .clk(clk),
    .rst(rst),
    .s_eth_hdr_valid(eth_rx_hdr_valid),
    .s_eth_hdr_ready(eth_rx_hdr_ready),
    .s_eth_dest_mac(eth_rx_dest_mac),
    .s_eth_src_mac(eth_rx_src_mac),
    .s_eth_type(eth_rx_type),
    .s_eth_payload_axis_tdata(eth_rx_payload_axis_tdata),
    .s_eth_payload_axis_tvalid(eth_rx_payload_axis_tvalid),
    .s_eth_payload_axis_tready(eth_rx_payload_axis_tready),
    .s_eth_payload_axis_tlast(eth_rx_payload_axis_tlast),
    .s_eth_payload_axis_tuser(eth_rx_payload_axis_tuser),
    .m_eth_hdr_valid(eth_tx_hdr_valid),
    .m_eth_hdr_ready(eth_tx_hdr_ready),
    .m_eth_dest_mac(eth_tx_dest_mac),
    .m_eth_src_mac(eth_tx_src_mac),
    .m_eth_type(eth_tx_type),
    .m_eth_payload_axis_tdata(eth_tx_payload_axis_tdata),
    .m_eth_payload_axis_tvalid(eth_tx_payload_axis_tvalid),
    .m_eth_payload_axis_tready(eth_tx_payload_axis_tready),
    .m_eth_payload_axis_tlast(eth_tx_payload_axis_tlast),
    .m_eth_payload_axis_tuser(eth_tx_payload_axis_tuser),
    .s_ip_hdr_valid(udp_s_ip_hdr_valid),
    .s_ip_hdr_ready(udp_s_ip_hdr_ready),
    .s_ip_dscp(udp_s_ip_dscp),
    .s_ip_ecn(udp_s_ip_ecn),
    .s_ip_length(udp_s_ip_length),
    .s_ip_ttl(udp_s_ip_ttl),
    .s_ip_protocol(udp_s_ip_protocol),
    .s_ip_source_ip(udp_s_ip_source_ip),
    .s_ip_dest_ip(udp_s_ip_dest_ip),
    .s_ip_payload_axis_tdata(udp_s_ip_payload_axis_tdata),
    .s_ip_payload_axis_tvalid(udp_s_ip_payload_axis_tvalid),
    .s_ip_payload_axis_tready(udp_s_ip_payload_axis_tready),
    .s_ip_payload_axis_tlast(udp_s_ip_payload_axis_tlast),
    .s_ip_payload_axis_tuser(udp_s_ip_payload_axis_tuser),
    .m_ip_hdr_valid(udp_m_ip_hdr_valid),
    .m_ip_hdr_ready(udp_m_ip_hdr_ready),
    .m_ip_eth_dest_mac(),
    .m_ip_eth_src_mac(),
    .m_ip_eth_type(),
    .m_ip_version(),
    .m_ip_ihl(udp_m_ip_ihl),
    .m_ip_dscp(),
    .m_ip_ecn(),
    .m_ip_length(udp_m_ip_length),
    .m_ip_identification(),
    .m_ip_flags(udp_m_ip_flags),
    .m_ip_fragment_offset(udp_m_ip_fragment_offset),
    .m_ip_ttl(udp_m_ip_ttl),
    .m_ip_protocol(udp_m_ip_protocol),
    .m_ip_header_checksum(),
    .m_ip_source_ip(udp_m_ip_source_ip),
    .m_ip_dest_ip(udp_m_ip_dest_ip),
    .m_ip_payload_axis_tdata(udp_m_ip_payload_axis_tdata),
    .m_ip_payload_axis_tvalid(udp_m_ip_payload_axis_tvalid),
    .m_ip_payload_axis_tready(udp_m_ip_payload_axis_tready),
    .m_ip_payload_axis_tlast(udp_m_ip_payload_axis_tlast),
    .m_ip_payload_axis_tuser(udp_m_ip_payload_axis_tuser),
    .s_udp_hdr_valid(udp_s_udp_hdr_valid),
    .s_udp_hdr_ready(udp_s_udp_hdr_ready),
    .s_udp_ip_dscp(udp_s_udp_ip_dscp),
    .s_udp_ip_ecn(udp_s_udp_ip_ecn),
    .s_udp_ip_ttl(udp_s_udp_ip_ttl),
    .s_udp_ip_source_ip(udp_s_udp_ip_source_ip),
    .s_udp_ip_dest_ip(udp_s_udp_ip_dest_ip),
    .s_udp_source_port(udp_s_udp_source_port),
    .s_udp_dest_port(udp_s_udp_dest_port),
    .s_udp_length(udp_s_udp_length),
    .s_udp_checksum(udp_s_udp_checksum),
    .s_udp_payload_axis_tdata(udp_s_udp_payload_axis_tdata),
    .s_udp_payload_axis_tvalid(udp_s_udp_payload_axis_tvalid),
    .s_udp_payload_axis_tready(udp_s_udp_payload_axis_tready),
    .s_udp_payload_axis_tlast(udp_s_udp_payload_axis_tlast),
    .s_udp_payload_axis_tuser(udp_s_udp_payload_axis_tuser),
    .m_udp_hdr_valid(udp_m_udp_hdr_valid),
    .m_udp_hdr_ready(udp_m_udp_hdr_ready),
    .m_udp_eth_dest_mac(),
    .m_udp_eth_src_mac(),
    .m_udp_eth_type(),
    .m_udp_ip_version(),
    .m_udp_ip_ihl(),
    .m_udp_ip_dscp(),
    .m_udp_ip_ecn(),
    .m_udp_ip_length(),
    .m_udp_ip_identification(),
    .m_udp_ip_flags(),
    .m_udp_ip_fragment_offset(),
    .m_udp_ip_ttl(),
    .m_udp_ip_protocol(),
    .m_udp_ip_header_checksum(),
    .m_udp_ip_source_ip(),
    .m_udp_ip_dest_ip(udp_m_udp_ip_dest_ip),
    .m_udp_source_port(udp_m_udp_source_port),
    .m_udp_dest_port(udp_m_udp_dest_port),
    .m_udp_length(),
    .m_udp_checksum(),
    .m_udp_payload_axis_tdata(udp_m_udp_payload_axis_tdata),
    .m_udp_payload_axis_tvalid(udp_m_udp_payload_axis_tvalid),
    .m_udp_payload_axis_tready(udp_m_udp_payload_axis_tready),
    .m_udp_payload_axis_tlast(udp_m_udp_payload_axis_tlast),
    .m_udp_payload_axis_tuser(udp_m_udp_payload_axis_tuser),
    .ip_rx_busy(),
    .ip_tx_busy(),
    .udp_rx_busy(),
    .udp_tx_busy(),
    .ip_rx_error_header_early_termination(),
    .ip_rx_error_payload_early_termination(),
    .ip_rx_error_invalid_header(udp_ip_rx_error_invalid_header),
    .ip_rx_error_invalid_checksum(udp_ip_rx_error_invalid_checksum),
    .ip_tx_error_payload_early_termination(),
    .ip_tx_error_arp_failed(udp_ip_tx_error_arp_failed),
    .udp_rx_error_header_early_termination(udp_udp_rx_error_header_early_termination),
    .udp_rx_error_payload_early_termination(udp_udp_rx_error_payload_early_termination),
    .udp_tx_error_payload_early_termination(udp_udp_tx_error_payload_early_termination),
    .local_mac(LOCAL_MAC),
    .local_ip(LOCAL_IP),
    .gateway_ip(GATEWAY_IP),
    .subnet_mask(SUBNET_MASK),
    .clear_arp_cache(clear_arp_cache)
);

/*
 * RX path
 */
reg rx_active = 1'b0;
reg rx_drop = 1'b0;
reg [15:0] rx_src_port = 0;
reg [15:0] rx_dst_port = 0;

assign udp_m_udp_hdr_ready = !rx_active;
assign udp_m_udp_payload_axis_tready = rx_active ? (rx_drop ? 1'b1 : m_axis_rx_tready) : 1'b0;

assign m_axis_rx_tdata = udp_m_udp_payload_axis_tdata;
assign m_axis_rx_tvalid = udp_m_udp_payload_axis_tvalid && rx_active && !rx_drop;
assign m_axis_rx_tlast = udp_m_udp_payload_axis_tlast;
assign m_axis_rx_tuser = udp_m_udp_payload_axis_tuser;
assign m_axis_rx_tdest = {rx_src_port, rx_dst_port};

assign rx_busy = rx_active || udp_m_udp_hdr_valid;
assign rx_drop_ip_mismatch = rx_drop && udp_m_udp_payload_axis_tvalid &&
                             udp_m_udp_payload_axis_tready && udp_m_udp_payload_axis_tlast;

always @(posedge clk) begin
    if (rst) begin
        rx_active <= 1'b0;
        rx_drop <= 1'b0;
        rx_src_port <= 0;
        rx_dst_port <= 0;
    end else begin
        if (udp_m_udp_hdr_valid && udp_m_udp_hdr_ready) begin
            rx_active <= 1'b1;
            rx_src_port <= udp_m_udp_source_port;
            rx_dst_port <= udp_m_udp_dest_port;
            rx_drop <= (udp_m_udp_ip_dest_ip != LOCAL_IP);
        end else if (udp_m_udp_payload_axis_tvalid && udp_m_udp_payload_axis_tready &&
                     udp_m_udp_payload_axis_tlast) begin
            rx_active <= 1'b0;
        end
    end
end

/*
 * Status
 */
assign tx_error_arp_failed = udp_ip_tx_error_arp_failed;
assign tx_error_payload_early_termination = udp_udp_tx_error_payload_early_termination;
assign rx_error_header_early_termination = eth_rx_error_header_early_termination |
                                           udp_udp_rx_error_header_early_termination;
assign rx_error_payload_early_termination = udp_udp_rx_error_payload_early_termination;
assign rx_error_invalid_header = udp_ip_rx_error_invalid_header;
assign rx_error_invalid_checksum = udp_ip_rx_error_invalid_checksum;

endmodule

`resetall
