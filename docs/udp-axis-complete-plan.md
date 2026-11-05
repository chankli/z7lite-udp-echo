# UDP AXIS Complete Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `rtl/udp_axis_complete.v` (UDP payload AXIS wrapper with per-packet `TDEST` ports and built-in ARP/ICMP) and `rtl/icmp_echo.v` (cut-through ICMP echo responder), plus a self-checking ModelSim/Questa `vsim` testbench.

**Architecture:** One shared `udp_complete` stack (ARP + IPv4 + UDP) behind `eth_axis_tx/rx`. TX uses a 4 KB byte FIFO plus a small metadata FIFO (`{len, src_port, dst_port, tuser, drop}`) so packet length is derived from `tlast` and UDP/IP headers can be generated before streaming payload. RX filters UDP by destination IP, latches source/destination ports into 32-bit `TDEST`, and routes non-UDP IP packets to a cut-through `icmp_echo` responder that adjusts the ICMP checksum incrementally.

**Tech Stack:** Verilog-2001 RTL, SystemVerilog testbench, ModelSim/Questa `vsim`/`vlog` 2020.4, GNU Make.

**Spec:** `docs/superpowers/specs/2026-11-02-udp-axis-complete-design.md`

## Global Constraints

- Start from a feature branch: `git checkout -b feature/udp-axis-complete master`. Never commit directly to `master`.
- RTL files in `rtl/` are Verilog-2001 only: `` `resetall ``, `` `timescale 1ns / 1ps ``, `` `default_nettype none ``. No SystemVerilog syntax in `rtl/`.
- Do not modify existing RTL modules; only add the two new files.
- `TX_FIFO_DEPTH` must be a power of two. `MAX_PAYLOAD_LEN <= TX_FIFO_DEPTH`. When `UDP_CHECKSUM_GEN_ENABLE=1`, `UDP_CHECKSUM_PAYLOAD_FIFO_DEPTH >= MAX_PAYLOAD_LEN + 8`.
- `TDEST` packing is fixed: `TDEST[31:16] = source port`, `TDEST[15:0] = destination port` on both TX and RX.
- Every git commit ends with:
  ```
  Co-Authored-By: Claude Code <noreply@anthropic.com>
  ```
- Simulator commands run from `tb/udp_axis_complete/`; `vsim`, `vlog`, and `vlib` are on PATH.
- Testbench is SystemVerilog (`.sv`) and compiled with `vlog -sv`; RTL is compiled with `vlog`.

## File Structure

| File | Responsibility |
|---|---|
| `rtl/icmp_echo.v` | Cut-through ICMP echo responder on the IP interface of `udp_complete` |
| `rtl/udp_axis_complete.v` | UDP payload AXIS wrapper: TX FIFO/metadata, RX filter/TDEST, ARP/UDP stack integration |
| `tb/udp_axis_complete/Makefile` | `vlib`/`vlog`/`vsim` flow with `TEST=<name>` selection |
| `tb/udp_axis_complete/tb_udp_axis_complete.sv` | Self-checking testbench, MAC-side frame model, UDP/ICMP/ARP checks |

---

### Task 1: Testbench Scaffolding and Module Stubs

**Files:**
- Create: `tb/udp_axis_complete/Makefile`
- Create: `tb/udp_axis_complete/tb_udp_axis_complete.sv`
- Create: `rtl/icmp_echo.v` (stub)
- Create: `rtl/udp_axis_complete.v` (stub)

**Interfaces:**
- Consumes: nothing.
- Produces: DUT port/parameter names exactly as specified in the spec, plus the TB helper tasks used by later tasks:
  - `send_axis_packet(frame_t payload, logic [31:0] tdest, logic tuser)`
  - `send_eth_frame(frame_t f)`
  - `get_tx_frame(output frame_t f)`
  - `get_rx_frame(output frame_t f, output logic [31:0] tdest)`
  - `build_udp_frame`, `build_icmp_frame`, `build_icmp_fragment`, `build_arp_reply`
  - `check_udp_frame`, `check_icmp_reply`, `check`, `csum`

- [ ] **Step 1: Create the feature branch**

Run:
```bash
cd C:/XJ_FPGA_work/pre_search/verilog-ethernet
git checkout -b feature/udp-axis-complete master
```

- [ ] **Step 2: Write the testbench framework**

Create `tb/udp_axis_complete/tb_udp_axis_complete.sv` with the following complete framework (test bodies for later tasks are added in those tasks; this file must compile and pass `TEST=smoke`):

```systemverilog
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
        .ICMP_ECHO_ENABLE(0), // enabled in Task 5
        .ICMP_FIFO_DEPTH(64),
        .ARP_CACHE_ADDR_WIDTH(9),
        .ARP_REQUEST_RETRY_COUNT(1),
        .ARP_REQUEST_RETRY_INTERVAL(20),
        .ARP_REQUEST_TIMEOUT(100)
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

    // TX monitor
    frame_t tx_store[0:255];
    int tx_store_wr = 0;
    mailbox #(int) tx_mbx = new();

    initial begin
        frame_t f;
        int len = 0;
        forever begin
            @(posedge clk);
            if (m_eth_tx_axis_tvalid && m_eth_tx_axis_tready) begin
                f = new[len+1](f);
                f[len] = m_eth_tx_axis_tdata;
                len++;
                if (m_eth_tx_axis_tlast) begin
                    tx_store[tx_store_wr] = f;
                    tx_mbx.put(tx_store_wr);
                    tx_store_wr++;
                    len = 0;
                end
            end
        end
    end

    // RX monitor
    frame_t rx_store[0:255];
    int rx_store_wr = 0;
    mailbox #(int) rx_mbx = new();
    logic [31:0] rx_tdest_store[0:255];

    initial begin
        frame_t f;
        int len = 0;
        forever begin
            @(posedge clk);
            if (m_axis_rx_tvalid && m_axis_rx_tready) begin
                f = new[len+1](f);
                f[len] = m_axis_rx_tdata;
                len++;
                if (m_axis_rx_tlast) begin
                    rx_store[rx_store_wr] = f;
                    rx_tdest_store[rx_store_wr] = m_axis_rx_tdest;
                    rx_mbx.put(rx_store_wr);
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
        for (int i = 0; i < payload.size(); i++) begin
            @(negedge clk);
            s_axis_tx_tdata  = payload[i];
            s_axis_tx_tvalid = 1;
            s_axis_tx_tlast  = (i == payload.size()-1);
            s_axis_tx_tuser  = tuser;
            s_axis_tx_tdest  = tdest;
            @(posedge clk);
            while (!s_axis_tx_tready) @(posedge clk);
        end
        @(negedge clk);
        s_axis_tx_tvalid = 0;
        s_axis_tx_tlast  = 0;
        s_axis_tx_tuser  = 0;
    endtask

    task automatic send_eth_frame(input frame_t f);
        for (int i = 0; i < f.size(); i++) begin
            @(negedge clk);
            s_eth_rx_axis_tdata  = f[i];
            s_eth_rx_axis_tvalid = 1;
            s_eth_rx_axis_tlast  = (i == f.size()-1);
            s_eth_rx_axis_tuser  = 0;
            @(posedge clk);
            while (!s_eth_rx_axis_tready) @(posedge clk);
        end
        @(negedge clk);
        s_eth_rx_axis_tvalid = 0;
        s_eth_rx_axis_tlast  = 0;
    endtask

    task automatic get_tx_frame(output frame_t f);
        int idx;
        int n = 0;
        while (!tx_mbx.try_get(idx)) begin
            @(posedge clk);
            n++;
            if (n > 20000) begin
                $display("ERROR: timeout waiting for TX frame");
                errors++;
                $finish;
            end
        end
        f = tx_store[idx];
    endtask

    task automatic get_rx_frame(output frame_t f, output logic [31:0] tdest);
        int idx;
        int n = 0;
        while (!rx_mbx.try_get(idx)) begin
            @(posedge clk);
            n++;
            if (n > 20000) begin
                $display("ERROR: timeout waiting for RX frame");
                errors++;
                $finish;
            end
        end
        f = rx_store[idx];
        tdest = rx_tdest_store[idx];
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
        f[20] = 8'h20; // MF=1, fragment offset 0
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
        for (int i = 0; i < n; i++) check(f[42+i] == payload[i], "ICMP payload");
    endtask

    task automatic run_smoke();
        check(tx_busy == 0, "smoke tx_busy");
        check(rx_busy == 0, "smoke rx_busy");
        check(tx_mbx.num() == 0, "smoke no tx frame");
        $display("SMOKE PASS");
    endtask

    string test_name;
    initial begin
        rst = 1;
        repeat (20) @(posedge clk);
        rst = 0;
        repeat (20) @(posedge clk);
        if (!$value$plusargs("TEST=%s", test_name)) test_name = "all";
        if (test_name == "smoke") run_smoke();
        $display("TESTS: %0d errors", errors);
        if (errors == 0) $display("PASS"); else $display("FAIL");
        $finish;
    end

endmodule
```

- [ ] **Step 3: Write the module stubs**

Create `rtl/udp_axis_complete.v`:
```verilog
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
    assign s_axis_tx_tready = 1'b0;
    assign m_axis_rx_tdata = 8'd0;
    assign m_axis_rx_tvalid = 1'b0;
    assign m_axis_rx_tlast = 1'b0;
    assign m_axis_rx_tuser = 1'b0;
    assign m_axis_rx_tdest = 32'd0;
    assign s_eth_rx_axis_tready = 1'b0;
    assign m_eth_tx_axis_tdata = 8'd0;
    assign m_eth_tx_axis_tvalid = 1'b0;
    assign m_eth_tx_axis_tlast = 1'b0;
    assign m_eth_tx_axis_tuser = 1'b0;
    assign tx_busy = 1'b0;
    assign rx_busy = 1'b0;
    assign tx_error_overflow = 1'b0;
    assign tx_error_arp_failed = 1'b0;
    assign tx_error_payload_early_termination = 1'b0;
    assign rx_error_header_early_termination = 1'b0;
    assign rx_error_payload_early_termination = 1'b0;
    assign rx_error_invalid_header = 1'b0;
    assign rx_error_invalid_checksum = 1'b0;
    assign rx_drop_ip_mismatch = 1'b0;
    assign icmp_error_overflow = 1'b0;
endmodule

`resetall
```

Create `rtl/icmp_echo.v`:
```verilog
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
    assign s_ip_hdr_ready = 1'b0;
    assign s_ip_payload_axis_tready = 1'b1;
    assign m_ip_hdr_valid = 1'b0;
    assign m_ip_dscp = 6'd0;
    assign m_ip_ecn = 2'd0;
    assign m_ip_length = 16'd0;
    assign m_ip_ttl = 8'd0;
    assign m_ip_protocol = 8'd0;
    assign m_ip_source_ip = 32'd0;
    assign m_ip_dest_ip = 32'd0;
    assign m_ip_payload_axis_tdata = 8'd0;
    assign m_ip_payload_axis_tvalid = 1'b0;
    assign m_ip_payload_axis_tlast = 1'b0;
    assign m_ip_payload_axis_tuser = 1'b0;
    assign busy = 1'b0;
    assign error_overflow = 1'b0;
endmodule

`resetall
```

- [ ] **Step 4: Write the vsim Makefile**

Create `tb/udp_axis_complete/Makefile`:
```make
SIM ?= vsim
TEST ?= all
WORK = work

RTL = ../../rtl
AXIS = ../../lib/axis/rtl
SRC = \
  $(RTL)/udp_axis_complete.v \
  $(RTL)/icmp_echo.v \
  $(RTL)/eth_axis_rx.v \
  $(RTL)/eth_axis_tx.v \
  $(RTL)/udp_complete.v \
  $(RTL)/udp.v \
  $(RTL)/udp_ip_rx.v \
  $(RTL)/udp_ip_tx.v \
  $(RTL)/udp_checksum_gen.v \
  $(RTL)/ip_complete.v \
  $(RTL)/ip.v \
  $(RTL)/ip_eth_rx.v \
  $(RTL)/ip_eth_tx.v \
  $(RTL)/ip_arb_mux.v \
  $(RTL)/arp.v \
  $(RTL)/arp_cache.v \
  $(RTL)/arp_eth_rx.v \
  $(RTL)/arp_eth_tx.v \
  $(RTL)/eth_arb_mux.v \
  $(AXIS)/axis_fifo.v \
  $(AXIS)/axis_srl_fifo.v \
  $(AXIS)/axis_async_fifo.v \
  $(AXIS)/axis_async_fifo_adapter.v \
  $(AXIS)/arbiter.v \
  $(AXIS)/priority_encoder.v \
  $(AXIS)/sync_reset.v

.PHONY: sim clean

sim:
	vlib $(WORK)
	vlog -work $(WORK) $(SRC)
	vlog -sv -work $(WORK) tb_udp_axis_complete.sv
	$(SIM) -c -work $(WORK) tb_udp_axis_complete +TEST=$(TEST) -do "run -all; quit -f"

clean:
	rm -rf $(WORK) transcript vsim.wlf
```

- [ ] **Step 5: Run the smoke test**

Run:
```bash
make -C tb/udp_axis_complete sim TEST=smoke
```
Expected:
```
SMOKE PASS
TESTS: 0 errors
PASS
```

- [ ] **Step 6: Commit**

```bash
git add rtl/udp_axis_complete.v rtl/icmp_echo.v tb/udp_axis_complete
git commit -m "feat: add udp_axis_complete scaffold and vsim testbench" -m "Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 2: Full Wrapper Implementation (TX/RX/ARP) and Basic UDP TX Test

**Files:**
- Modify: `rtl/udp_axis_complete.v` (replace stub with full implementation)
- Modify: `tb/udp_axis_complete/tb_udp_axis_complete.sv` (add `run_tx_basic` and dispatch)
- Test: `tb/udp_axis_complete/tb_udp_axis_complete.sv`

**Interfaces:**
- Consumes: Task 1 DUT ports/parameters and TB helpers.
- Produces: working TX path (data FIFO + metadata FIFO + read FSM), RX path (filter/TDEST), ARP/UDP stack integration. `tx_error_overflow`, `tx_error_arp_failed`, `rx_drop_ip_mismatch` wired.

- [ ] **Step 1: Add the failing TX test**

Add the following tasks before the `string test_name;` declaration and add dispatch in the `initial` block:

```systemverilog
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
```

Dispatch:
```systemverilog
        if (test_name == "smoke") run_smoke();
        if (test_name == "all" || test_name == "tx_basic") run_tx_basic();
```

- [ ] **Step 2: Run the test and confirm it fails**

Run:
```bash
make -C tb/udp_axis_complete sim TEST=tx_basic
```
Expected: `FAIL` with `UDP frame length` / mailbox timeout (the stub never sends a frame).

- [ ] **Step 3: Implement the full wrapper**

Replace `rtl/udp_axis_complete.v` with the complete implementation below. This includes both TX and RX paths; ICMP is instantiated but the `icmp_echo` module remains a stub until Task 5 (`ICMP_ECHO_ENABLE=0` in the TB).

```verilog
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
```

- [ ] **Step 4: Run the basic TX test**

Run:
```bash
make -C tb/udp_axis_complete sim TEST=tx_basic
```
Expected: `TX_BASIC PASS`, `TESTS: 0 errors`, `PASS`.

- [ ] **Step 5: Commit**

```bash
git add rtl/udp_axis_complete.v tb/udp_axis_complete/tb_udp_axis_complete.sv
git commit -m "feat: implement udp_axis_complete TX/RX and ARP integration" -m "Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 3: TX Port and Back-to-Back Tests

**Files:**
- Modify: `tb/udp_axis_complete/tb_udp_axis_complete.sv`
- Test: same file

**Interfaces:**
- Consumes: Task 2 wrapper.
- Produces: tests for `TDEST` source/destination ports and back-to-back packets.

- [ ] **Step 1: Add the tests**

Add these tasks and dispatch entries:

```systemverilog
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
```

Dispatch:
```systemverilog
        if (test_name == "all" || test_name == "tx_ports") run_tx_ports();
        if (test_name == "all" || test_name == "tx_backtoback") run_tx_backtoback();
```

- [ ] **Step 2: Run both tests**

Run:
```bash
make -C tb/udp_axis_complete sim TEST=tx_ports
make -C tb/udp_axis_complete sim TEST=tx_backtoback
```
Expected: `TX_PORTS PASS` and `TX_BACKTOBACK PASS`, `0 errors`.

- [ ] **Step 3: Commit**

```bash
git add tb/udp_axis_complete/tb_udp_axis_complete.sv
git commit -m "test: cover udp_axis_complete TX ports and back-to-back packets" -m "Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 4: RX Path and Destination IP Filter Tests

**Files:**
- Modify: `tb/udp_axis_complete/tb_udp_axis_complete.sv`
- Test: same file

**Interfaces:**
- Consumes: Task 2 RX path (`m_axis_rx_*`, `rx_drop_ip_mismatch`).
- Produces: RX payload/TDEST verification and IP mismatch drop verification.

- [ ] **Step 1: Add the tests**

Add these tasks and dispatch entries:

```systemverilog
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
        // Wrong destination IP: must be dropped.
        build_udp_frame(f, LOCAL_MAC, HOST_MAC, HOST_IP, 32'hC0A8_0163,
                        16'd5000, 16'd7000, p);
        drop_before = rx_drop_cnt;
        send_eth_frame(f);
        repeat (100) @(posedge clk);
        check(rx_mbx.num() == 0, "RX filter no output");
        check(rx_drop_cnt == drop_before + 1, "RX filter drop pulse");
        // Matching packet still works.
        build_udp_frame(f, LOCAL_MAC, HOST_MAC, HOST_IP, LOCAL_IP,
                        16'd5001, 16'd7001, p);
        send_eth_frame(f);
        get_rx_frame(f, tdest);
        check(tdest == {16'd5001, 16'd7001}, "RX filter TDEST");
        check(f.size() == p.size(), "RX filter payload length");
        for (int i = 0; i < p.size(); i++) check(f[i] == p[i], "RX filter payload");
        $display("RX_FILTER PASS");
    endtask
```

Dispatch:
```systemverilog
        if (test_name == "all" || test_name == "rx_basic") run_rx_basic();
        if (test_name == "all" || test_name == "rx_filter") run_rx_filter();
```

- [ ] **Step 2: Run both tests**

Run:
```bash
make -C tb/udp_axis_complete sim TEST=rx_basic
make -C tb/udp_axis_complete sim TEST=rx_filter
```
Expected: `RX_BASIC PASS` and `RX_FILTER PASS`, `0 errors`.

- [ ] **Step 3: Commit**

```bash
git add tb/udp_axis_complete/tb_udp_axis_complete.sv
git commit -m "test: cover udp_axis_complete RX payload, TDEST, and IP filter" -m "Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 5: ICMP Echo Implementation and Integration

**Files:**
- Modify: `rtl/icmp_echo.v` (replace stub with full implementation)
- Modify: `tb/udp_axis_complete/tb_udp_axis_complete.sv` (set `ICMP_ECHO_ENABLE(1)`, add ICMP tests)
- Test: same file

**Interfaces:**
- Consumes: Task 2 wrapper's `s_ip_*`/`m_ip_*` integration.
- Produces: cut-through ICMP echo responder; reply type/code/checksum/id/seq/payload, mirrored TTL, IP addresses.

- [ ] **Step 1: Enable ICMP in the TB and add failing tests**

Change the DUT parameter:
```systemverilog
        .ICMP_ECHO_ENABLE(1),
```

Add these tasks and dispatch entries:

```systemverilog
    task automatic run_icmp_ping();
        frame_t req, rep, arp;
        frame_t p;
        // 56-byte payload
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

        // 0-byte payload (ICMP header only)
        p = new[0];
        build_icmp_frame(req, LOCAL_MAC, HOST_MAC, HOST_IP, LOCAL_IP,
                         8'd17, 8'h08, 16'h2222, 16'h0002, p);
        send_eth_frame(req);
        get_tx_frame(rep);
        check_icmp_reply(rep, 8'd17, 16'h2222, 16'h0002, p);

        // 1000-byte payload
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
        logic [31:0] tdest;
        p = new[16];
        for (int i = 0; i < 16; i++) p[i] = i;
        // Non-echo type
        build_icmp_frame(req, LOCAL_MAC, HOST_MAC, HOST_IP, LOCAL_IP,
                         8'd64, 8'h00, 16'h1111, 16'h0001, p);
        send_eth_frame(req);
        repeat (200) @(posedge clk);
        check(tx_mbx.num() == 0, "ICMP non-echo no reply");
        // Fragmented (MF=1)
        build_icmp_fragment(req, LOCAL_MAC, HOST_MAC, HOST_IP, LOCAL_IP,
                            8'd64, 8'h08, 16'h1111, 16'h0002, p);
        send_eth_frame(req);
        repeat (200) @(posedge clk);
        check(tx_mbx.num() == 0, "ICMP fragment no reply");
        // Wrong destination IP
        build_icmp_frame(req, LOCAL_MAC, HOST_MAC, HOST_IP, 32'hC0A8_0163,
                         8'd64, 8'h08, 16'h1111, 16'h0003, p);
        send_eth_frame(req);
        repeat (200) @(posedge clk);
        check(tx_mbx.num() == 0, "ICMP wrong IP no reply");
        $display("ICMP_REJECT PASS");
    endtask

    task automatic run_icmp_backpressure();
        frame_t req, rep, p;
        logic [15:0] id = 16'h4444;
        logic [15:0] seq = 16'h0004;
        p = new[1000];
        for (int i = 0; i < 1000; i++) p[i] = i ^ 8'h3C;
        build_icmp_frame(req, LOCAL_MAC, HOST_MAC, HOST_IP, LOCAL_IP,
                         8'd64, 8'h08, id, seq, p);
        send_eth_frame(req);
        // Stall the MAC TX while the reply is streaming.
        m_eth_tx_axis_tready = 0;
        repeat (100) @(posedge clk);
        m_eth_tx_axis_tready = 1;
        get_tx_frame(rep);
        check_icmp_reply(rep, 8'd64, id, seq, p);
        $display("ICMP_BACKPRESSURE PASS");
    endtask
```

Dispatch:
```systemverilog
        if (test_name == "all" || test_name == "icmp_ping") run_icmp_ping();
        if (test_name == "all" || test_name == "icmp_reject") run_icmp_reject();
        if (test_name == "all" || test_name == "icmp_backpressure") run_icmp_backpressure();
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run:
```bash
make -C tb/udp_axis_complete sim TEST=icmp_ping
```
Expected: `FAIL` (stub `icmp_echo` produces no reply).

- [ ] **Step 3: Implement `rtl/icmp_echo.v`**

Replace the stub with:

```verilog
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
```

- [ ] **Step 4: Run the ICMP tests**

Run:
```bash
make -C tb/udp_axis_complete sim TEST=icmp_ping
make -C tb/udp_axis_complete sim TEST=icmp_reject
make -C tb/udp_axis_complete sim TEST=icmp_backpressure
```
Expected: `ICMP_PING PASS`, `ICMP_REJECT PASS`, `ICMP_BACKPRESSURE PASS`, `0 errors`.

- [ ] **Step 5: Commit**

```bash
git add rtl/icmp_echo.v tb/udp_axis_complete/tb_udp_axis_complete.sv
git commit -m "feat: add cut-through ICMP echo responder and integration tests" -m "Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 6: Overflow, ARP Failure, and Full Regression

**Files:**
- Modify: `tb/udp_axis_complete/tb_udp_axis_complete.sv`
- Test: same file

**Interfaces:**
- Consumes: Tasks 1-5.
- Produces: `tx_error_overflow`, `tx_error_arp_failed`, and full `TEST=all` regression.

- [ ] **Step 1: Add the edge-case tests**

Add these tasks and dispatch entries:

```systemverilog
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

    task automatic run_tx_overflow();
        frame_t p, f;
        int ov_before;
        resolve_arp();
        p = new[1473];
        for (int i = 0; i < 1473; i++) p[i] = i ^ 8'h77;
        ov_before = tx_overflow_cnt;
        send_axis_packet(p, {16'd1234, 16'd4321}, 1'b0);
        repeat (200) @(posedge clk);
        check(tx_overflow_cnt == ov_before + 1, "overflow error pulse");
        check(tx_mbx.num() == 0, "overflow no frame");
        // Next good packet still works
        p = new[64];
        for (int i = 0; i < 64; i++) p[i] = 8'h5A;
        send_axis_packet(p, {16'd1234, 16'd4321}, 1'b0);
        get_tx_frame(f);
        check_udp_frame(f, 16'd1234, 16'd4321, p);
        $display("TX_OVERFLOW PASS");
    endtask

    task automatic run_arp_fail();
        frame_t p, f, arp;
        int fail_before;
        // Clear ARP cache and do not answer the ARP request.
        @(negedge clk);
        clear_arp_cache = 1;
        @(negedge clk);
        clear_arp_cache = 0;
        p = new[32];
        for (int i = 0; i < 32; i++) p[i] = 8'h99;
        fail_before = tx_arp_fail_cnt;
        send_axis_packet(p, {16'd1234, 16'd4321}, 1'b0);
        repeat (2000) @(posedge clk);
        check(tx_arp_fail_cnt > fail_before, "ARP failure pulse");
        // Drain any ARP request frames left in the monitor queue.
        begin
            int idx;
            while (tx_mbx.try_get(idx)) ;
        end
        // Re-resolve for subsequent tests.
        resolve_arp();
        $display("ARP_FAIL PASS");
    endtask
```

Dispatch:
```systemverilog
        if (test_name == "all" || test_name == "tx_overflow") run_tx_overflow();
        if (test_name == "all" || test_name == "arp_fail") run_arp_fail();
```

- [ ] **Step 2: Run the edge-case tests**

Run:
```bash
make -C tb/udp_axis_complete sim TEST=tx_overflow
make -C tb/udp_axis_complete sim TEST=arp_fail
```
Expected: `TX_OVERFLOW PASS`, `ARP_FAIL PASS`, `0 errors`.

- [ ] **Step 3: Run the full regression**

Run:
```bash
make -C tb/udp_axis_complete sim TEST=all
```
Expected: all test PASS lines, `TESTS: 0 errors`, `PASS`.

- [ ] **Step 4: Commit**

```bash
git add tb/udp_axis_complete/tb_udp_axis_complete.sv
git commit -m "test: cover TX overflow, ARP failure, and full regression" -m "Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

### Task 7: Synthesis Smoke Check and Final Verification

**Files:**
- No RTL changes expected.
- Create: `tb/udp_axis_complete/synth_check.tcl` (optional, for Vivado smoke check)

**Interfaces:**
- Consumes: complete RTL.
- Produces: evidence that the new RTL elaborates/synthesizes without latches or multiple drivers.

- [ ] **Step 1: Run the full vsim regression once more**

Run:
```bash
make -C tb/udp_axis_complete clean
make -C tb/udp_axis_complete sim TEST=all
```
Expected: `TESTS: 0 errors`, `PASS`.

- [ ] **Step 2: Run a Vivado synthesis smoke check**

Create `tb/udp_axis_complete/synth_check.tcl`:
```tcl
set_part xc7a200tsbg484-1
read_verilog [list \
  ../../rtl/udp_axis_complete.v \
  ../../rtl/icmp_echo.v \
  ../../rtl/eth_axis_rx.v \
  ../../rtl/eth_axis_tx.v \
  ../../rtl/udp_complete.v \
  ../../rtl/udp.v \
  ../../rtl/udp_ip_rx.v \
  ../../rtl/udp_ip_tx.v \
  ../../rtl/udp_checksum_gen.v \
  ../../rtl/ip_complete.v \
  ../../rtl/ip.v \
  ../../rtl/ip_eth_rx.v \
  ../../rtl/ip_eth_tx.v \
  ../../rtl/ip_arb_mux.v \
  ../../rtl/arp.v \
  ../../rtl/arp_cache.v \
  ../../rtl/arp_eth_rx.v \
  ../../rtl/arp_eth_tx.v \
  ../../rtl/eth_arb_mux.v \
  ../../lib/axis/rtl/axis_fifo.v \
  ../../lib/axis/rtl/axis_srl_fifo.v \
  ../../lib/axis/rtl/axis_async_fifo.v \
  ../../lib/axis/rtl/axis_async_fifo_adapter.v \
  ../../lib/axis/rtl/arbiter.v \
  ../../lib/axis/rtl/priority_encoder.v \
  ../../lib/axis/rtl/sync_reset.v \
]
synth_design -top udp_axis_complete -part xc7a200tsbg484-1
report_utilization -file udp_axis_complete_util.rpt
```

Run (use `vivado.bat` on this Windows host; `vivado` resolves to the Linux launcher):
```bash
cd tb/udp_axis_complete
cmd.exe /c "C:\\Xilinx\\Vivado\\2024.2\\bin\\vivado.bat -mode batch -source synth_check.tcl"
```
Expected: synthesis completes with 0 errors; no latch inferred. (If the `cmd.exe` invocation has path issues, use the Vivado MCP session or the shim described in the project memory.)

- [ ] **Step 3: Review the diff**

Run:
```bash
git status --short
git diff --stat master...HEAD
```
Expected: only the four new files under `rtl/` and `tb/udp_axis_complete/` plus the plan/spec docs.

- [ ] **Step 4: Final commit (if synthesis script was added)**

```bash
git add tb/udp_axis_complete/synth_check.tcl
git commit -m "test: add udp_axis_complete synthesis smoke check" -m "Co-Authored-By: Claude Code <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- TX payload AXIS + 32-bit TDEST: Tasks 1-3.
- Data FIFO + metadata FIFO + `tlast` length: Task 2.
- Source/destination port packing: Task 2/3.
- RX filter by destination IP, `TDEST` packing, `rx_drop_ip_mismatch`: Task 2/4.
- ARP/UDP integration and UDP checksum: Task 2/3.
- ICMP echo cut-through, incremental checksum, mirrored TTL, IP-interface arbitration: Task 5.
- Overflow, ARP failure, status outputs: Task 6.
- vsim testbench: Task 1 and all test tasks.
- Synthesis smoke: Task 7.

**Placeholder scan:** No `TBD`/`TODO`; every task contains concrete code and commands.

**Type consistency:** DUT port/parameter names match the spec; TB helper names are used consistently across tasks; `TDEST` packing is `{src_port, dst_port}` everywhere.

**Known follow-ups (out of scope):** Nexys Video example integration, 64-bit/10G variant, and optional ICMP `error_overflow` accounting (currently tied to 0 because cut-through backpressure prevents overflow).
