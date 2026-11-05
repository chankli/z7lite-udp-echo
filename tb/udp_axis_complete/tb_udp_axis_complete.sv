`timescale 1ns / 1ps

module tb_udp_axis_complete;

    localparam [47:0] LOCAL_MAC = 48'h02_00_00_00_00_01;
    localparam [31:0] LOCAL_IP  = 32'hC0A8_0180;
    localparam [31:0] DEST_IP   = 32'hC0A8_0164;
    localparam [31:0] GW_IP     = 32'hC0A8_0101;
    localparam [31:0] MASK      = 32'hFFFF_FF00;
    localparam [47:0] HOST_MAC  = 48'h02_00_00_00_00_02;
    localparam [31:0] HOST_IP   = DEST_IP;

    logic clk = 0;
    logic rst = 1;
    always #4 clk = ~clk;

    logic [7:0]  s_axis_tx_tdata = 0;
    logic        s_axis_tx_tvalid = 0;
    logic        s_axis_tx_tready;
    logic        s_axis_tx_tlast = 0;
    logic        s_axis_tx_tuser = 0;
    logic [31:0] s_axis_tx_tdest = 0;

    logic [7:0]  m_axis_rx_tdata;
    logic        m_axis_rx_tvalid;
    logic        m_axis_rx_tready = 1;
    logic        m_axis_rx_tlast;
    logic        m_axis_rx_tuser;
    logic [31:0] m_axis_rx_tdest;

    logic [7:0]  s_eth_rx_axis_tdata = 0;
    logic        s_eth_rx_axis_tvalid = 0;
    logic        s_eth_rx_axis_tready;
    logic        s_eth_rx_axis_tlast = 0;
    logic        s_eth_rx_axis_tuser = 0;

    logic [7:0]  m_eth_tx_axis_tdata;
    logic        m_eth_tx_axis_tvalid;
    logic        m_eth_tx_axis_tready = 1;
    logic        m_eth_tx_axis_tlast;
    logic        m_eth_tx_axis_tuser;

    logic tx_busy, rx_busy;
    logic tx_error_overflow, tx_error_arp_failed, tx_error_payload_early_termination;
    logic rx_error_header_early_termination, rx_error_payload_early_termination;
    logic rx_error_invalid_header, rx_error_invalid_checksum;
    logic rx_drop_ip_mismatch, icmp_error_overflow;
    logic clear_arp_cache = 0;

    udp_axis_complete #(
        .LOCAL_MAC(LOCAL_MAC),
        .LOCAL_IP(LOCAL_IP),
        .GATEWAY_IP(GW_IP),
        .SUBNET_MASK(MASK),
        .DEST_IP(DEST_IP),
        .TX_FIFO_DEPTH(4096),
        .MAX_PAYLOAD_LEN(1472),
        .META_FIFO_DEPTH(8),
        .UDP_CHECKSUM_GEN_ENABLE(1),
        .UDP_CHECKSUM_PAYLOAD_FIFO_DEPTH(2048),
        .UDP_CHECKSUM_HEADER_FIFO_DEPTH(8),
        .ICMP_ECHO_ENABLE(1),
        .ICMP_FIFO_DEPTH(64),
        .ARP_CACHE_ADDR_WIDTH(9),
        .ARP_REQUEST_RETRY_COUNT(1),
        .ARP_REQUEST_RETRY_INTERVAL(1000),
        .ARP_REQUEST_TIMEOUT(2000)
    ) dut (
        .clk(clk),
        .rst(rst),
        .s_axis_tx_tdata(s_axis_tx_tdata),
        .s_axis_tx_tvalid(s_axis_tx_tvalid),
        .s_axis_tx_tready(s_axis_tx_tready),
        .s_axis_tx_tlast(s_axis_tx_tlast),
        .s_axis_tx_tuser(s_axis_tx_tuser),
        .s_axis_tx_tdest(s_axis_tx_tdest),
        .m_axis_rx_tdata(m_axis_rx_tdata),
        .m_axis_rx_tvalid(m_axis_rx_tvalid),
        .m_axis_rx_tready(m_axis_rx_tready),
        .m_axis_rx_tlast(m_axis_rx_tlast),
        .m_axis_rx_tuser(m_axis_rx_tuser),
        .m_axis_rx_tdest(m_axis_rx_tdest),
        .s_eth_rx_axis_tdata(s_eth_rx_axis_tdata),
        .s_eth_rx_axis_tvalid(s_eth_rx_axis_tvalid),
        .s_eth_rx_axis_tready(s_eth_rx_axis_tready),
        .s_eth_rx_axis_tlast(s_eth_rx_axis_tlast),
        .s_eth_rx_axis_tuser(s_eth_rx_axis_tuser),
        .m_eth_tx_axis_tdata(m_eth_tx_axis_tdata),
        .m_eth_tx_axis_tvalid(m_eth_tx_axis_tvalid),
        .m_eth_tx_axis_tready(m_eth_tx_axis_tready),
        .m_eth_tx_axis_tlast(m_eth_tx_axis_tlast),
        .m_eth_tx_axis_tuser(m_eth_tx_axis_tuser),
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

    typedef byte unsigned byte_t;
    typedef byte_t frame_t[];

    frame_t tx_store[0:255];
    int tx_store_wr = 0;
    int tx_store_rd = 0;

    initial begin
        frame_t f;
        automatic int len = 0;
        forever begin
            @(posedge clk);
            if (m_eth_tx_axis_tvalid && m_eth_tx_axis_tready) begin
                f = new[len+1](f);
                f[len] = m_eth_tx_axis_tdata;
                len++;
                if (m_eth_tx_axis_tlast) begin
                    tx_store[tx_store_wr] = f;
                    tx_store_wr++;
                    len = 0;
                end
            end
        end
    end

    frame_t rx_store[0:255];
    int rx_store_wr = 0;
    int rx_store_rd = 0;
    logic [31:0] rx_tdest_store[0:255];

    initial begin
        frame_t f;
        automatic int len = 0;
        forever begin
            @(posedge clk);
            if (m_axis_rx_tvalid && m_axis_rx_tready) begin
                f = new[len+1](f);
                f[len] = m_axis_rx_tdata;
                len++;
                if (m_axis_rx_tlast) begin
                    rx_store[rx_store_wr] = f;
                    rx_tdest_store[rx_store_wr] = m_axis_rx_tdest;
                    rx_store_wr++;
                    len = 0;
                end
            end
        end
    end

    int errors = 0;
    int tx_overflow_cnt = 0;
    int tx_arp_fail_cnt = 0;
    int rx_drop_cnt = 0;

    always @(posedge clk) begin
        if (tx_error_overflow) tx_overflow_cnt++;
        if (tx_error_arp_failed) tx_arp_fail_cnt++;
        if (rx_drop_ip_mismatch) rx_drop_cnt++;
    end

    task automatic check(input logic cond, input string msg);
        if (!cond) begin
            errors++;
            $display("ERROR: %s", msg);
        end
    endtask

    function automatic logic [15:0] csum(input byte_t d[], input int start, input int len, input logic [31:0] init);
        logic [31:0] sum;
        logic [15:0] w;
        sum = init;
        for (int i = 0; i < len; i += 2) begin
            w = {d[start+i], ((i+1) < len) ? d[start+i+1] : 8'h00};
            sum += w;
        end
        while (sum > 32'hFFFF) sum = (sum & 32'hFFFF) + (sum >> 16);
        return ~sum[15:0];
    endfunction

    task automatic send_axis_packet(input frame_t payload, input logic [31:0] tdest, input logic tuser);
        int n = 0;
        for (int i = 0; i < payload.size(); i++) begin
            @(negedge clk);
            s_axis_tx_tdata  = payload[i];
            s_axis_tx_tvalid = 1;
            s_axis_tx_tlast  = (i == payload.size()-1);
            s_axis_tx_tuser  = tuser;
            s_axis_tx_tdest  = tdest;
            @(posedge clk);
            while (!s_axis_tx_tready) begin
                @(posedge clk);
                n++;
                if (n > 20000) begin
                    $display("ERROR: timeout waiting for s_axis_tx_tready");
                    errors++;
                    $finish;
                end
            end
        end
        @(negedge clk);
        s_axis_tx_tvalid = 0;
        s_axis_tx_tlast  = 0;
        s_axis_tx_tuser  = 0;
    endtask

    task automatic send_eth_frame(input frame_t f);
        int n = 0;
        for (int i = 0; i < f.size(); i++) begin
            @(negedge clk);
            s_eth_rx_axis_tdata  = f[i];
            s_eth_rx_axis_tvalid = 1;
            s_eth_rx_axis_tlast  = (i == f.size()-1);
            s_eth_rx_axis_tuser  = 0;
            @(posedge clk);
            while (!s_eth_rx_axis_tready) begin
                @(posedge clk);
                n++;
                if (n > 20000) begin
                    $display("ERROR: timeout waiting for s_eth_rx_axis_tready");
                    errors++;
                    $finish;
                end
            end
        end
        @(negedge clk);
        s_eth_rx_axis_tvalid = 0;
        s_eth_rx_axis_tlast  = 0;
    endtask

    task automatic get_tx_frame(output frame_t f);
        int n = 0;
        while (tx_store_rd >= tx_store_wr) begin
            @(posedge clk);
            n++;
            if (n > 20000) begin
                $display("ERROR: timeout waiting for TX frame");
                errors++;
                $finish;
            end
        end
        f = tx_store[tx_store_rd];
        tx_store_rd++;
    endtask

    task automatic get_rx_frame(output frame_t f, output logic [31:0] tdest);
        int n = 0;
        while (rx_store_rd >= rx_store_wr) begin
            @(posedge clk);
            n++;
            if (n > 20000) begin
                $display("ERROR: timeout waiting for RX frame");
                errors++;
                $finish;
            end
        end
        f = rx_store[rx_store_rd];
        tdest = rx_tdest_store[rx_store_rd];
        rx_store_rd++;
    endtask

    function automatic bit is_arp_request(input frame_t f);
        return (f.size() >= 42 && f[12] == 8'h08 && f[13] == 8'h06 &&
                f[20] == 8'h00 && f[21] == 8'h01);
    endfunction

    task automatic build_arp_reply(output frame_t f);
        f = new[42];
        {f[0],f[1],f[2],f[3],f[4],f[5]} = LOCAL_MAC;
        {f[6],f[7],f[8],f[9],f[10],f[11]} = HOST_MAC;
        f[12] = 8'h08; f[13] = 8'h06;
        f[14] = 8'h00; f[15] = 8'h01;
        f[16] = 8'h08; f[17] = 8'h00;
        f[18] = 8'h06; f[19] = 8'h04;
        f[20] = 8'h00; f[21] = 8'h02;
        {f[22],f[23],f[24],f[25],f[26],f[27]} = HOST_MAC;
        {f[28],f[29],f[30],f[31]} = HOST_IP;
        {f[32],f[33],f[34],f[35],f[36],f[37]} = LOCAL_MAC;
        {f[38],f[39],f[40],f[41]} = LOCAL_IP;
    endtask

    task automatic build_udp_frame(
        output frame_t f,
        input logic [47:0] dmac, input logic [47:0] smac,
        input logic [31:0] sip, input logic [31:0] dip,
        input logic [15:0] sport, input logic [15:0] dport,
        input byte_t payload[]
    );
        int n = payload.size();
        int ip_len = 20 + 8 + n;
        int udp_len = 8 + n;
        logic [31:0] pseudo;
        logic [15:0] ip_csum, udp_csum;
        f = new[14 + ip_len];
        {f[0],f[1],f[2],f[3],f[4],f[5]} = dmac;
        {f[6],f[7],f[8],f[9],f[10],f[11]} = smac;
        f[12] = 8'h08; f[13] = 8'h00;
        f[14] = 8'h45; f[15] = 8'h00;
        f[16] = ip_len[15:8]; f[17] = ip_len[7:0];
        f[18] = 8'h00; f[19] = 8'h00;
        f[20] = 8'h40; f[21] = 8'h00;
        f[22] = 8'h40;
        f[23] = 8'h11;
        f[24] = 8'h00; f[25] = 8'h00;
        {f[26],f[27],f[28],f[29]} = sip;
        {f[30],f[31],f[32],f[33]} = dip;
        f[34] = sport[15:8]; f[35] = sport[7:0];
        f[36] = dport[15:8]; f[37] = dport[7:0];
        f[38] = udp_len[15:8]; f[39] = udp_len[7:0];
        f[40] = 8'h00; f[41] = 8'h00;
        for (int i = 0; i < n; i++) f[42+i] = payload[i];
        ip_csum = csum(f, 14, 20, 0);
        f[24] = ip_csum[15:8]; f[25] = ip_csum[7:0];
        pseudo = sip[31:16] + sip[15:0] + dip[31:16] + dip[15:0] + 16'h0011 + udp_len;
        udp_csum = csum(f, 34, udp_len, pseudo);
        if (udp_csum == 0) udp_csum = 16'hFFFF;
        f[40] = udp_csum[15:8]; f[41] = udp_csum[7:0];
    endtask

    task automatic build_icmp_frame(
        output frame_t f,
        input logic [47:0] dmac, input logic [47:0] smac,
        input logic [31:0] sip, input logic [31:0] dip,
        input logic [7:0] ttl, input logic [7:0] icmp_type,
        input logic [15:0] id, input logic [15:0] seq,
        input byte_t payload[]
    );
        int n = payload.size();
        int icmp_len = 8 + n;
        int ip_len = 20 + icmp_len;
        logic [15:0] ip_csum, icmp_csum;
        f = new[14 + ip_len];
        {f[0],f[1],f[2],f[3],f[4],f[5]} = dmac;
        {f[6],f[7],f[8],f[9],f[10],f[11]} = smac;
        f[12] = 8'h08; f[13] = 8'h00;
        f[14] = 8'h45; f[15] = 8'h00;
        f[16] = ip_len[15:8]; f[17] = ip_len[7:0];
        f[18] = 8'h00; f[19] = 8'h00;
        f[20] = 8'h40; f[21] = 8'h00;
        f[22] = ttl;
        f[23] = 8'h01;
        f[24] = 8'h00; f[25] = 8'h00;
        {f[26],f[27],f[28],f[29]} = sip;
        {f[30],f[31],f[32],f[33]} = dip;
        f[34] = icmp_type; f[35] = 8'h00;
        f[36] = 8'h00; f[37] = 8'h00;
        f[38] = id[15:8]; f[39] = id[7:0];
        f[40] = seq[15:8]; f[41] = seq[7:0];
        for (int i = 0; i < n; i++) f[42+i] = payload[i];
        ip_csum = csum(f, 14, 20, 0);
        f[24] = ip_csum[15:8]; f[25] = ip_csum[7:0];
        icmp_csum = csum(f, 34, icmp_len, 0);
        f[36] = icmp_csum[15:8]; f[37] = icmp_csum[7:0];
    endtask

    task automatic build_icmp_fragment(
        output frame_t f,
        input logic [47:0] dmac, input logic [47:0] smac,
        input logic [31:0] sip, input logic [31:0] dip,
        input logic [7:0] ttl, input logic [7:0] icmp_type,
        input logic [15:0] id, input logic [15:0] seq,
        input byte_t payload[]
    );
        build_icmp_frame(f, dmac, smac, sip, dip, ttl, icmp_type, id, seq, payload);
        f[20] = 8'h20;
        f[24] = 8'h00; f[25] = 8'h00;
        {f[24],f[25]} = csum(f, 14, 20, 0);
    endtask

    task automatic check_udp_frame(
        input frame_t f,
        input logic [15:0] sport, input logic [15:0] dport,
        input byte_t payload[]
    );
        int n = payload.size();
        logic [31:0] pseudo;
        logic [15:0] udp_csum;
        check(f.size() == 14+20+8+n, "UDP frame length");
        check({f[0],f[1],f[2],f[3],f[4],f[5]} == HOST_MAC, "UDP eth dst");
        check({f[6],f[7],f[8],f[9],f[10],f[11]} == LOCAL_MAC, "UDP eth src");
        check(f[12] == 8'h08 && f[13] == 8'h00, "UDP eth type");
        check(f[14] == 8'h45, "UDP IP ver/ihl");
        check({f[16],f[17]} == 16'd28+n, "UDP IP length");
        check(f[22] == 8'd64, "UDP IP TTL");
        check(f[23] == 8'h11, "UDP IP protocol");
        check({f[26],f[27],f[28],f[29]} == LOCAL_IP, "UDP IP src");
        check({f[30],f[31],f[32],f[33]} == DEST_IP, "UDP IP dst");
        check(csum(f, 14, 20, 0) == 0, "UDP IP checksum");
        check({f[34],f[35]} == sport, "UDP source port");
        check({f[36],f[37]} == dport, "UDP dest port");
        check({f[38],f[39]} == 16'd8+n, "UDP length");
        pseudo = LOCAL_IP[31:16] + LOCAL_IP[15:0] + DEST_IP[31:16] + DEST_IP[15:0] + 16'h0011 + (8+n);
        udp_csum = csum(f, 34, 8+n, pseudo);
        check(udp_csum == 0, "UDP checksum");
        for (int i = 0; i < n; i++) check(f[42+i] == payload[i], "UDP payload");
    endtask

    task automatic check_icmp_reply(
        input frame_t f,
        input logic [7:0] req_ttl,
        input logic [15:0] id, input logic [15:0] seq,
        input byte_t payload[]
    );
        int n = payload.size();
        int icmp_len = 8 + n;
        check(f.size() == 14+20+icmp_len, "ICMP reply length");
        check({f[0],f[1],f[2],f[3],f[4],f[5]} == HOST_MAC, "ICMP eth dst");
        check({f[6],f[7],f[8],f[9],f[10],f[11]} == LOCAL_MAC, "ICMP eth src");
        check(f[12] == 8'h08 && f[13] == 8'h00, "ICMP eth type");
        check(f[14] == 8'h45, "ICMP IP ver/ihl");
        check({f[16],f[17]} == 20+icmp_len, "ICMP IP length");
        check(f[22] == req_ttl, "ICMP TTL mirror");
        check(f[23] == 8'h01, "ICMP protocol");
        check({f[26],f[27],f[28],f[29]} == LOCAL_IP, "ICMP src IP");
        check({f[30],f[31],f[32],f[33]} == HOST_IP, "ICMP dst IP");
        check(csum(f, 14, 20, 0) == 0, "ICMP IP checksum");
        check(f[34] == 8'h00 && f[35] == 8'h00, "ICMP type/code");
        check(csum(f, 34, icmp_len, 0) == 0, "ICMP checksum");
        check({f[38],f[39]} == id, "ICMP id");
        check({f[40],f[41]} == seq, "ICMP seq");
        for (int i = 0; i < n; i++) begin
            if (f[42+i] != payload[i] && i < 10)
                $display("ICMP mismatch i=%0d got=%02x exp=%02x", i, f[42+i], payload[i]);
            check(f[42+i] == payload[i], "ICMP payload");
        end
    endtask

    task automatic run_smoke();
        check(tx_busy == 0, "smoke tx_busy");
        check(rx_busy == 0, "smoke rx_busy");
        check(tx_store_rd == tx_store_wr, "smoke no tx frame");
        $display("SMOKE PASS");
    endtask

    task automatic run_tx_basic();
        frame_t payload, f, arp;
        // ARP resolution + 100-byte payload
        payload = new[100];
        for (int i = 0; i < 100; i++) payload[i] = i;
        send_axis_packet(payload, {16'd1234, 16'd4321}, 1'b0);
        get_tx_frame(f);
        if (is_arp_request(f)) begin
            build_arp_reply(arp);
            send_eth_frame(arp);
            get_tx_frame(f);
        end
        check_udp_frame(f, 16'd1234, 16'd4321, payload);

        // 1-byte payload
        payload = new[1];
        payload[0] = 8'hA5;
        send_axis_packet(payload, {16'd1000, 16'd2000}, 1'b0);
        get_tx_frame(f);
        check_udp_frame(f, 16'd1000, 16'd2000, payload);

        // 1472-byte payload
        payload = new[1472];
        for (int i = 0; i < 1472; i++) payload[i] = i ^ 8'h5A;
        send_axis_packet(payload, {16'd3000, 16'd4000}, 1'b0);
        get_tx_frame(f);
        check_udp_frame(f, 16'd3000, 16'd4000, payload);
        $display("TX_BASIC PASS");
    endtask

    task automatic run_tx_ports();
        frame_t p, f;
        p = new[32];
        for (int i = 0; i < 32; i++) p[i] = 8'h10 + i;
        send_axis_packet(p, {16'd1234, 16'd1234}, 1'b0);
        get_tx_frame(f);
        if (is_arp_request(f)) begin
            frame_t arp;
            build_arp_reply(arp);
            send_eth_frame(arp);
            get_tx_frame(f);
        end
        check_udp_frame(f, 16'd1234, 16'd1234, p);

        send_axis_packet(p, {16'd4321, 16'd4321}, 1'b0);
        get_tx_frame(f);
        check_udp_frame(f, 16'd4321, 16'd4321, p);

        send_axis_packet(p, {16'd6000, 16'd1234}, 1'b0);
        get_tx_frame(f);
        check_udp_frame(f, 16'd6000, 16'd1234, p);
        $display("TX_PORTS PASS");
    endtask

    task automatic run_tx_backtoback();
        frame_t p0, p1, f;
        p0 = new[1472];
        p1 = new[1472];
        for (int i = 0; i < 1472; i++) begin
            p0[i] = i;
            p1[i] = i ^ 8'hFF;
        end
        send_axis_packet(p0, {16'd1000, 16'd2000}, 1'b0);
        send_axis_packet(p1, {16'd1001, 16'd2001}, 1'b0);
        get_tx_frame(f);
        if (is_arp_request(f)) begin
            frame_t arp;
            build_arp_reply(arp);
            send_eth_frame(arp);
            get_tx_frame(f);
        end
        check_udp_frame(f, 16'd1000, 16'd2000, p0);
        get_tx_frame(f);
        check_udp_frame(f, 16'd1001, 16'd2001, p1);
        $display("TX_BACKTOBACK PASS");
    endtask

    task automatic run_rx_basic();
        frame_t p, f;
        logic [31:0] tdest;
        p = new[64];
        for (int i = 0; i < 64; i++) p[i] = 8'h80 + i;
        build_udp_frame(f, LOCAL_MAC, HOST_MAC, HOST_IP, LOCAL_IP,
                        16'd5000, 16'd7000, p);
        send_eth_frame(f);
        get_rx_frame(f, tdest);
        check(tdest == {16'd5000, 16'd7000}, "RX TDEST");
        check(f.size() == p.size(), "RX payload length");
        for (int i = 0; i < p.size(); i++) check(f[i] == p[i], "RX payload");
        $display("RX_BASIC PASS");
    endtask

    task automatic run_rx_filter();
        frame_t p, f;
        logic [31:0] tdest;
        int drop_before;
        p = new[16];
        for (int i = 0; i < 16; i++) p[i] = 8'hC0 + i;
        build_udp_frame(f, LOCAL_MAC, HOST_MAC, HOST_IP, 32'hC0A8_0163,
                        16'd5000, 16'd7000, p);
        drop_before = rx_drop_cnt;
        send_eth_frame(f);
        repeat (100) @(posedge clk);
        check(rx_store_rd == rx_store_wr, "RX filter no output");
        check(rx_drop_cnt == drop_before + 1, "RX filter drop pulse");
        build_udp_frame(f, LOCAL_MAC, HOST_MAC, HOST_IP, LOCAL_IP,
                        16'd5001, 16'd7001, p);
        send_eth_frame(f);
        get_rx_frame(f, tdest);
        check(tdest == {16'd5001, 16'd7001}, "RX filter TDEST");
        check(f.size() == p.size(), "RX filter payload length");
        for (int i = 0; i < p.size(); i++) check(f[i] == p[i], "RX filter payload");
        $display("RX_FILTER PASS");
    endtask

    task automatic resolve_arp();
        frame_t p, f, arp;
        p = new[8];
        for (int i = 0; i < 8; i++) p[i] = i;
        send_axis_packet(p, {16'd1234, 16'd1234}, 1'b0);
        get_tx_frame(f);
        if (is_arp_request(f)) begin
            build_arp_reply(arp);
            send_eth_frame(arp);
            get_tx_frame(f);
        end
    endtask

    task automatic run_icmp_ping();
        frame_t req, rep, arp;
        frame_t p;

        p = new[56];
        for (int i = 0; i < 56; i++) p[i] = 8'h30 + i;
        build_icmp_frame(req, LOCAL_MAC, HOST_MAC, HOST_IP, LOCAL_IP,
                         8'd32, 8'h08, 16'h1234, 16'h0001, p);
        send_eth_frame(req);
        get_tx_frame(rep);
        if (is_arp_request(rep)) begin
            build_arp_reply(arp);
            send_eth_frame(arp);
            get_tx_frame(rep);
        end
        check_icmp_reply(rep, 8'd32, 16'h1234, 16'h0001, p);

        p = new[0];
        build_icmp_frame(req, LOCAL_MAC, HOST_MAC, HOST_IP, LOCAL_IP,
                         8'd17, 8'h08, 16'h2222, 16'h0002, p);
        send_eth_frame(req);
        get_tx_frame(rep);
        check_icmp_reply(rep, 8'd17, 16'h2222, 16'h0002, p);

        p = new[1000];
        for (int i = 0; i < 1000; i++) p[i] = i ^ 8'hA5;
        build_icmp_frame(req, LOCAL_MAC, HOST_MAC, HOST_IP, LOCAL_IP,
                         8'd64, 8'h08, 16'h3333, 16'h0003, p);
        send_eth_frame(req);
        get_tx_frame(rep);
        check_icmp_reply(rep, 8'd64, 16'h3333, 16'h0003, p);
        $display("ICMP_PING PASS");
    endtask

    task automatic run_icmp_reject();
        frame_t req, p;
        p = new[16];
        for (int i = 0; i < 16; i++) p[i] = i;

        build_icmp_frame(req, LOCAL_MAC, HOST_MAC, HOST_IP, LOCAL_IP,
                         8'd64, 8'h00, 16'h1111, 16'h0001, p);
        send_eth_frame(req);
        repeat (200) @(posedge clk);
        check(tx_store_rd == tx_store_wr, "ICMP non-echo no reply");

        build_icmp_fragment(req, LOCAL_MAC, HOST_MAC, HOST_IP, LOCAL_IP,
                            8'd64, 8'h08, 16'h1111, 16'h0002, p);
        send_eth_frame(req);
        repeat (200) @(posedge clk);
        check(tx_store_rd == tx_store_wr, "ICMP fragment no reply");

        build_icmp_frame(req, LOCAL_MAC, HOST_MAC, HOST_IP, 32'hC0A8_0163,
                         8'd64, 8'h08, 16'h1111, 16'h0003, p);
        send_eth_frame(req);
        repeat (200) @(posedge clk);
        check(tx_store_rd == tx_store_wr, "ICMP wrong IP no reply");
        $display("ICMP_REJECT PASS");
    endtask

    task automatic run_icmp_backpressure();
        frame_t req, rep, p;
        logic [15:0] id = 16'h4444;
        logic [15:0] seq = 16'h0004;
        resolve_arp();
        p = new[1000];
        for (int i = 0; i < 1000; i++) p[i] = i ^ 8'h3C;
        build_icmp_frame(req, LOCAL_MAC, HOST_MAC, HOST_IP, LOCAL_IP,
                         8'd64, 8'h08, id, seq, p);
        send_eth_frame(req);
        @(negedge clk);
        m_eth_tx_axis_tready = 0;
        repeat (100) @(posedge clk);
        @(negedge clk);
        m_eth_tx_axis_tready = 1;
        get_tx_frame(rep);
        check_icmp_reply(rep, 8'd64, id, seq, p);
        $display("ICMP_BACKPRESSURE PASS");
    endtask

    task automatic run_tx_overflow();
        frame_t p, f;
        int ov_before;
        resolve_arp();
        p = new[1473];
        for (int i = 0; i < 1473; i++) p[i] = i ^ 8'h77;
        ov_before = tx_overflow_cnt;
        send_axis_packet(p, {16'd1234, 16'd4321}, 1'b0);
        repeat (3000) @(posedge clk);
        check(tx_overflow_cnt == ov_before + 1, "overflow error pulse");
        check(tx_store_rd == tx_store_wr, "overflow no frame");
        p = new[64];
        for (int i = 0; i < 64; i++) p[i] = 8'h5A;
        send_axis_packet(p, {16'd1234, 16'd4321}, 1'b0);
        get_tx_frame(f);
        check_udp_frame(f, 16'd1234, 16'd4321, p);
        $display("TX_OVERFLOW PASS");
    endtask

    task automatic run_arp_fail();
        frame_t p;
        int fail_before;
        @(negedge clk);
        clear_arp_cache = 1;
        @(negedge clk);
        clear_arp_cache = 0;
        p = new[32];
        for (int i = 0; i < 32; i++) p[i] = 8'h99;
        fail_before = tx_arp_fail_cnt;
        send_axis_packet(p, {16'd1234, 16'd4321}, 1'b0);
        repeat (3000) @(posedge clk);
        check(tx_arp_fail_cnt > fail_before, "ARP failure pulse");
        // Drain any ARP request frames left in the monitor queue.
        tx_store_rd = tx_store_wr;
        resolve_arp();
        $display("ARP_FAIL PASS");
    endtask

    string test_name;
    initial begin
        rst = 1;
        repeat (20) @(posedge clk);
        rst = 0;
        repeat (20) @(posedge clk);
        if (!$value$plusargs("TEST=%s", test_name)) test_name = "all";
        if (test_name == "smoke") run_smoke();
        if (test_name == "all" || test_name == "tx_basic") run_tx_basic();
        if (test_name == "all" || test_name == "tx_ports") run_tx_ports();
        if (test_name == "all" || test_name == "tx_backtoback") run_tx_backtoback();
        if (test_name == "all" || test_name == "rx_basic") run_rx_basic();
        if (test_name == "all" || test_name == "rx_filter") run_rx_filter();
        if (test_name == "all" || test_name == "icmp_ping") run_icmp_ping();
        if (test_name == "all" || test_name == "icmp_reject") run_icmp_reject();
        if (test_name == "all" || test_name == "icmp_backpressure") run_icmp_backpressure();
        if (test_name == "all" || test_name == "tx_overflow") run_tx_overflow();
        if (test_name == "all" || test_name == "arp_fail") run_arp_fail();
        $display("TESTS: %0d errors", errors);
        if (errors == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end

endmodule
