`resetall
`timescale 1ns / 1ps
`default_nettype none

module icmp_echo #(
    parameter [31:0] LOCAL_IP = 32'hC0A8_0180,
    parameter FIFO_DEPTH = 64
) (
    input  wire        clk,
    input  wire        rst,

    input  wire        s_ip_hdr_valid,
    output wire        s_ip_hdr_ready,
    input  wire [3:0]  s_ip_ihl,
    input  wire [15:0] s_ip_length,
    input  wire [7:0]  s_ip_ttl,
    input  wire [7:0]  s_ip_protocol,
    input  wire [31:0] s_ip_source_ip,
    input  wire [31:0] s_ip_dest_ip,
    input  wire [2:0]  s_ip_flags,
    input  wire [12:0] s_ip_fragment_offset,
    input  wire [7:0]  s_ip_payload_axis_tdata,
    input  wire        s_ip_payload_axis_tvalid,
    output wire        s_ip_payload_axis_tready,
    input  wire        s_ip_payload_axis_tlast,
    input  wire        s_ip_payload_axis_tuser,

    output wire        m_ip_hdr_valid,
    input  wire        m_ip_hdr_ready,
    output wire [5:0]  m_ip_dscp,
    output wire [1:0]  m_ip_ecn,
    output wire [15:0] m_ip_length,
    output wire [7:0]  m_ip_ttl,
    output wire [7:0]  m_ip_protocol,
    output wire [31:0] m_ip_source_ip,
    output wire [31:0] m_ip_dest_ip,
    output wire [7:0]  m_ip_payload_axis_tdata,
    output wire        m_ip_payload_axis_tvalid,
    input  wire        m_ip_payload_axis_tready,
    output wire        m_ip_payload_axis_tlast,
    output wire        m_ip_payload_axis_tuser,

    output wire        busy,
    output wire        error_overflow
);

reg        in_active = 1'b0;
reg [15:0] in_idx = 0;
reg [7:0]  icmp_type = 0;
reg [7:0]  icmp_code = 0;
reg [7:0]  icmp_csum_hi = 0;
reg [7:0]  icmp_csum_lo = 0;
reg        is_echo = 1'b0;
reg        req_tuser = 1'b0;
reg        req_header_ok = 1'b0;
reg [15:0] req_ip_length = 0;
reg [7:0]  req_ttl = 0;
reg [31:0] req_source_ip = 0;

wire [15:0] icmp_csum_orig = {icmp_csum_hi, icmp_csum_lo};
wire [16:0] icmp_csum_adj = {1'b0, icmp_csum_orig} + 17'h00800;
wire [15:0] icmp_csum_reply = icmp_csum_adj[15:0] + icmp_csum_adj[16];

localparam OUT_IDLE = 2'd0;
localparam OUT_IP_HDR = 2'd1;
localparam OUT_ICMP_HDR = 2'd2;
localparam OUT_PAYLOAD = 2'd3;

reg [1:0] out_state = OUT_IDLE;
reg       out_active = 1'b0;
reg [1:0] out_idx = 0;

wire fifo_s_tready;
wire [7:0] fifo_m_tdata;
wire fifo_m_tvalid;
wire fifo_m_tready;
wire fifo_m_tlast;
wire fifo_s_tvalid;

assign fifo_s_tvalid = in_active && is_echo && (in_idx >= 4) &&
                       s_ip_payload_axis_tvalid && s_ip_payload_axis_tready;

axis_fifo #(
    .DEPTH(FIFO_DEPTH),
    .DATA_WIDTH(8),
    .KEEP_ENABLE(0),
    .KEEP_WIDTH(1),
    .LAST_ENABLE(1),
    .ID_ENABLE(0),
    .DEST_ENABLE(0),
    .USER_ENABLE(0),
    .RAM_PIPELINE(1),
    .OUTPUT_FIFO_ENABLE(0),
    .FRAME_FIFO(0)
) fifo_inst (
    .clk(clk),
    .rst(rst),
    .s_axis_tdata(s_ip_payload_axis_tdata),
    .s_axis_tkeep(1'b1),
    .s_axis_tvalid(fifo_s_tvalid),
    .s_axis_tready(fifo_s_tready),
    .s_axis_tlast(s_ip_payload_axis_tlast),
    .s_axis_tid(8'd0),
    .s_axis_tdest(8'd0),
    .s_axis_tuser(1'b0),
    .m_axis_tdata(fifo_m_tdata),
    .m_axis_tkeep(),
    .m_axis_tvalid(fifo_m_tvalid),
    .m_axis_tready(fifo_m_tready),
    .m_axis_tlast(fifo_m_tlast),
    .m_axis_tid(),
    .m_axis_tdest(),
    .m_axis_tuser(),
    .pause_req(1'b0),
    .pause_ack(),
    .status_depth(),
    .status_depth_commit(),
    .status_overflow(),
    .status_bad_frame(),
    .status_good_frame()
);

assign s_ip_hdr_ready = !in_active && !out_active;
assign s_ip_payload_axis_tready = in_active && ((in_idx < 4) || !is_echo || fifo_s_tready);

wire header_ok = (s_ip_ihl == 4'd5) &&
                 (s_ip_length >= 16'd28) &&
                 (s_ip_protocol == 8'h01) &&
                 (s_ip_dest_ip == LOCAL_IP) &&
                 !s_ip_flags[0] &&
                 (s_ip_fragment_offset == 13'd0);

wire start_reply = in_active && is_echo && (in_idx >= 4) && !out_active && req_header_ok;

always @(posedge clk) begin
    if (rst) begin
        in_active <= 1'b0;
        in_idx <= 0;
        icmp_type <= 0;
        icmp_code <= 0;
        icmp_csum_hi <= 0;
        icmp_csum_lo <= 0;
        is_echo <= 1'b0;
        req_tuser <= 1'b0;
        req_header_ok <= 1'b0;
        req_ip_length <= 0;
        req_ttl <= 0;
        req_source_ip <= 0;
    end else begin
        if (s_ip_hdr_valid && s_ip_hdr_ready) begin
            in_active <= 1'b1;
            in_idx <= 0;
            is_echo <= 1'b0;
            req_tuser <= 1'b0;
            req_header_ok <= header_ok;
            req_ip_length <= s_ip_length;
            req_ttl <= s_ip_ttl;
            req_source_ip <= s_ip_source_ip;
        end else if (in_active && s_ip_payload_axis_tvalid && s_ip_payload_axis_tready) begin
            req_tuser <= req_tuser | s_ip_payload_axis_tuser;
            if (in_idx == 0) begin
                icmp_type <= s_ip_payload_axis_tdata;
            end else if (in_idx == 1) begin
                icmp_code <= s_ip_payload_axis_tdata;
                is_echo <= req_header_ok && (icmp_type == 8'h08) &&
                           (s_ip_payload_axis_tdata == 8'h00);
            end else if (in_idx == 2) begin
                icmp_csum_hi <= s_ip_payload_axis_tdata;
            end else if (in_idx == 3) begin
                icmp_csum_lo <= s_ip_payload_axis_tdata;
            end
            if (s_ip_payload_axis_tlast) begin
                in_active <= 1'b0;
            end else begin
                in_idx <= in_idx + 1;
            end
        end
    end
end

always @(posedge clk) begin
    if (rst) begin
        out_state <= OUT_IDLE;
        out_active <= 1'b0;
        out_idx <= 0;
    end else begin
        if (start_reply) begin
            out_active <= 1'b1;
            out_state <= OUT_IP_HDR;
            out_idx <= 0;
        end else begin
            case (out_state)
                OUT_IDLE: ;
                OUT_IP_HDR: begin
                    if (m_ip_hdr_ready) out_state <= OUT_ICMP_HDR;
                end
                OUT_ICMP_HDR: begin
                    if (m_ip_payload_axis_tready) begin
                        if (out_idx == 2'd3) out_state <= OUT_PAYLOAD;
                        out_idx <= out_idx + 1;
                    end
                end
                OUT_PAYLOAD: begin
                    if (fifo_m_tvalid && m_ip_payload_axis_tready && fifo_m_tlast) begin
                        out_active <= 1'b0;
                        out_state <= OUT_IDLE;
                    end
                end
                default: out_state <= OUT_IDLE;
            endcase
        end
    end
end

reg [7:0] icmp_hdr_byte;
always @* begin
    case (out_idx)
        2'd0: icmp_hdr_byte = 8'h00;
        2'd1: icmp_hdr_byte = 8'h00;
        2'd2: icmp_hdr_byte = icmp_csum_reply[15:8];
        default: icmp_hdr_byte = icmp_csum_reply[7:0];
    endcase
end

assign m_ip_hdr_valid = (out_state == OUT_IP_HDR);
assign m_ip_dscp = 6'd0;
assign m_ip_ecn = 2'd0;
assign m_ip_length = req_ip_length;
assign m_ip_ttl = req_ttl;
assign m_ip_protocol = 8'h01;
assign m_ip_source_ip = LOCAL_IP;
assign m_ip_dest_ip = req_source_ip;

assign m_ip_payload_axis_tdata = (out_state == OUT_ICMP_HDR) ? icmp_hdr_byte : fifo_m_tdata;
assign m_ip_payload_axis_tvalid = (out_state == OUT_ICMP_HDR) ? 1'b1 :
                                  (out_state == OUT_PAYLOAD) ? fifo_m_tvalid : 1'b0;
assign m_ip_payload_axis_tlast = (out_state == OUT_PAYLOAD) ? fifo_m_tlast : 1'b0;
assign m_ip_payload_axis_tuser = req_tuser && m_ip_payload_axis_tlast;
assign fifo_m_tready = (out_state == OUT_PAYLOAD) && m_ip_payload_axis_tready;

assign busy = in_active || out_active;
assign error_overflow = 1'b0;

endmodule

`resetall
