# UDP AXIS Complete 设计文档

- 日期：2026-11-02
- 状态：待评审
- 目标仓库：`verilog-ethernet`
- 新增文件：`rtl/udp_axis_complete.v`、`rtl/icmp_echo.v`
- 测试目录：`tb/udp_axis_complete/`

## 1. 背景与目标

现有 `udp_complete` 同时暴露以太网、IP、UDP 三组并行头字段接口，应用侧接入需要处理大量协议细节。本设计提供一个精简封装：

- 应用侧只暴露两组 AXI4-Stream：
  - TX：UDP payload 输入，32-bit `TDEST` 同时给出本包源端口和目的端口。
  - RX：UDP payload 输出，32-bit `TDEST` 同时给出本包源端口和目的端口。
- 模块内部根据 `tlast` 自动推导 payload 长度，并生成 UDP/IP 头。
- 复用现有成熟模块：`udp_complete`（ARP/IP/UDP/checksum）、`eth_axis_tx`、`eth_axis_rx`。
- 内置 ICMP echo 响应（可选），用于 bring-up 阶段的 ping 调试。
- MAC 侧暴露完整以太网帧的 AXIS 接口，便于直接连接 `eth_mac_1g` 系列。

## 2. 范围

### 2.1 包含

- 8-bit 数据通路的单时钟域模块。
- 固定源 MAC/IP、固定目的 IP；源端口和目的端口逐包由 `TDEST[31:16]` / `TDEST[15:0]` 给出。
- ARP 自动解析（复用 `udp_complete`）。
- UDP checksum 默认生成（可参数关闭）。
- TX 整包缓存 + 每包元数据缓存，允许边发边收。
- 超长包检测与丢弃。
- RX 目的 IP 过滤：只接受 `m_udp_ip_dest_ip == LOCAL_IP` 的包，其余静默丢弃。
- 内置 ICMP echo 响应（`ICMP_ECHO_ENABLE=1`），支持 ping。
- ARP 失败、RX 提前结束等错误状态输出。

### 2.2 不包含

- 10G/25G 64-bit 数据通路。
- 运行时修改 IP/MAC/端口（本期使用参数）。
- RX UDP 端口过滤（目的 IP 匹配的 UDP 包都输出，不按端口筛选）。
- RX 广播/组播接收（目的 IP 只接受 `LOCAL_IP`）。
- ICMP 以外的其他 IP 协议（TCP、IGMP 等，收到后直接丢弃）。
- 分片 ICMP 请求（`fragment_offset != 0` 或 MF 置位的包直接丢弃）。
- IP 分片重组（沿用 `udp_complete` 的行为）。
- 多对端 ARP/路由（固定单一目的 IP，超出子网时走网关）。
- 与 Nexys Video example 的集成改造（后续可单独做）。

## 3. 模块接口

### 3.1 参数

```verilog
module udp_axis_complete #(
    parameter [47:0] LOCAL_MAC            = 48'h02_00_00_00_00_01,
    parameter [31:0] LOCAL_IP             = 32'hC0A8_0180, // 192.168.1.128
    parameter [31:0] GATEWAY_IP           = 32'hC0A8_0101, // 192.168.1.1
    parameter [31:0] SUBNET_MASK          = 32'hFF_FF_FF_00,
    parameter [31:0] DEST_IP              = 32'hC0A8_0164, // 192.168.1.100

    parameter        TX_FIFO_DEPTH        = 4096,
    parameter        MAX_PAYLOAD_LEN      = 1472,
    parameter        META_FIFO_DEPTH      = 8,

    parameter        UDP_CHECKSUM_GEN_ENABLE          = 1,
    parameter        UDP_CHECKSUM_PAYLOAD_FIFO_DEPTH  = 2048,
    parameter        UDP_CHECKSUM_HEADER_FIFO_DEPTH   = 8,

    parameter        ICMP_ECHO_ENABLE     = 1,
    parameter        ICMP_FIFO_DEPTH      = 64,

    parameter        ARP_CACHE_ADDR_WIDTH       = 9,
    parameter        ARP_REQUEST_RETRY_COUNT    = 4,
    parameter        ARP_REQUEST_RETRY_INTERVAL = 125000000*2,
    parameter        ARP_REQUEST_TIMEOUT        = 125000000*30
) (
    input  wire        clk,
    input  wire        rst,

    /*
     * 应用 TX：UDP payload 输入
     */
    input  wire [7:0]  s_axis_tx_tdata,
    input  wire        s_axis_tx_tvalid,
    output wire        s_axis_tx_tready,
    input  wire        s_axis_tx_tlast,
    input  wire        s_axis_tx_tuser,
    input  wire [31:0] s_axis_tx_tdest,

    /*
     * 应用 RX：UDP payload 输出
     */
    output wire [7:0]  m_axis_rx_tdata,
    output wire        m_axis_rx_tvalid,
    input  wire        m_axis_rx_tready,
    output wire        m_axis_rx_tlast,
    output wire        m_axis_rx_tuser,
    output wire [31:0] m_axis_rx_tdest,

    /*
     * MAC RX：完整以太网帧输入
     */
    input  wire [7:0]  s_eth_rx_axis_tdata,
    input  wire        s_eth_rx_axis_tvalid,
    output wire        s_eth_rx_axis_tready,
    input  wire        s_eth_rx_axis_tlast,
    input  wire        s_eth_rx_axis_tuser,

    /*
     * MAC TX：完整以太网帧输出
     */
    output wire [7:0]  m_eth_tx_axis_tdata,
    output wire        m_eth_tx_axis_tvalid,
    input  wire        m_eth_tx_axis_tready,
    output wire        m_eth_tx_axis_tlast,
    output wire        m_eth_tx_axis_tuser,

    /*
     * 状态与错误
     */
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

    /*
     * 配置
     */
    input  wire        clear_arp_cache
);
```

### 3.2 握手语义

- 应用 TX：标准 AXIS；一包由 `tlast` 结束；`TDEST` 在该包第一拍即需有效，模块在包开始时锁存。
  - `TDEST[15:0]`：本包目的 UDP 端口。
  - `TDEST[31:16]`：本包源 UDP 端口。
- 应用 RX：标准 AXIS；`TDEST` 在整个包期间保持不变。
  - `TDEST[15:0]`：本包目的 UDP 端口。
  - `TDEST[31:16]`：本包源 UDP 端口。
- MAC TX/RX：8-bit、1-bit `tuser` 的完整以太网帧 AXIS（不含 FCS，与 `eth_mac_1g` 系列一致）。

## 4. 总体结构

```
应用 TX AXIS ──► 数据 FIFO(4KB) + 元数据 FIFO ──► udp_complete ──► eth_axis_tx ──► MAC TX AXIS
(TDEST={源端口,目的端口})   (写侧/读侧并行)          │
                                                   │
应用 RX AXIS ◄── RX 端口锁存 + payload 直通 ◄───────┘◄── eth_axis_rx ◄── MAC RX AXIS
(TDEST={源端口,目的端口})
```

### 4.1 协议栈实现框图

![udp_axis_complete 协议栈实现框图](./2026-11-02-udp-axis-complete-protocol-stack.svg)

可编辑源文件：[`2026-11-02-udp-axis-complete-protocol-stack.drawio`](./2026-11-02-udp-axis-complete-protocol-stack.drawio)

图中：
- 黑色实线：TX/RX 数据通路。
- 紫色虚线：ICMP echo 回复路径（`m_ip_*` → `icmp_echo` → `s_ip_*` → `ip_arb_mux`）。
- 黄色：封装层的 FIFO / FSM / 过滤。
- 蓝色：`udp_complete` 内部与 `eth_axis_tx/rx`。
- 橙色：MAC / PHY。

内部实例：

| 实例 | 作用 |
|---|---|
| `axis_fifo` | TX payload 字节 FIFO，`DEPTH=TX_FIFO_DEPTH`，8-bit |
| `axis_srl_fifo` | TX 每包元数据：`{len, source_port, dest_port, tuser, drop}` |
| `udp_complete` | ARP + IPv4 + UDP + checksum |
| `icmp_echo` | 消费 `udp_complete.m_ip_*`，对 ICMP echo request 生成 reply 并送回 `udp_complete.s_ip_*` |
| `eth_axis_rx` | MAC RX 原始帧 → 以太网头 + payload |
| `eth_axis_tx` | 以太网头 + payload → MAC TX 原始帧 |

## 5. TX 数据通路

### 5.1 写侧（接收应用包）

状态：`IDLE`、`WRITE`、`OVERFLOW`。

- `IDLE`：等待 `s_axis_tx_tvalid`，且数据 FIFO 剩余空间 ≥ `MAX_PAYLOAD_LEN`。满足后：
  - 锁存 `pkt_dest_port = s_axis_tx_tdest[15:0]`。
  - 锁存 `pkt_source_port = s_axis_tx_tdest[31:16]`。
  - 进入 `WRITE`。
  - 预留整个 `MAX_PAYLOAD_LEN` 的目的是保证任何单包都能完整放入 FIFO，避免「FIFO 满但包长未知、发送侧无法开始读」的死锁。
- `WRITE`：
  - `s_axis_tx_tready = 1`，逐字节写入数据 FIFO。
  - `payload_cnt` 递增；`tuser_acc` 对 `s_axis_tx_tuser` 做 OR。
  - `s_axis_tx_tlast` 时：向元数据 FIFO 写入
    `{len=payload_cnt, dest_port=pkt_dest_port, source_port=pkt_source_port, tuser=tuser_acc, drop=0}`，回到 `IDLE`。
  - 若本拍不是 `tlast`，且 `payload_cnt+1 == MAX_PAYLOAD_LEN`：说明包超过上限。
    该字节仍写入 FIFO（预留空间足够），随后进入 `OVERFLOW`。
- `OVERFLOW`：
  - `s_axis_tx_tready = 1`，忽略数据，继续接收直到 `s_axis_tx_tlast`。
  - 在 `tlast` 时写入元数据
    `{len=MAX_PAYLOAD_LEN, dest_port=pkt_dest_port, source_port=pkt_source_port, tuser=0, drop=1}`，回到 `IDLE`。
  - 错误脉冲 `tx_error_overflow` 在读侧真正丢弃该包时产生（见 5.2）。

### 5.2 读侧（发送包）

状态：`IDLE`、`HDR`、`SEND`、`DROP`。

- `IDLE`：元数据 FIFO 非空时弹出队首条目并锁存；`drop=1` 进入 `DROP`，否则进入 `HDR`。
- `HDR`：
  - 驱动 `udp_complete` 的 UDP 头：
    - `s_udp_ip_dscp = 0`、`s_udp_ip_ecn = 0`
    - `s_udp_ip_ttl = 64`
    - `s_udp_ip_source_ip = LOCAL_IP`
    - `s_udp_ip_dest_ip = DEST_IP`
    - `s_udp_source_port = meta_source_port`
    - `s_udp_dest_port = meta_dest_port`
    - `s_udp_length = meta_len + 8`
    - `s_udp_checksum = 0`（checksum 生成使能时由 `udp_complete` 填充；关闭时 0 表示不发 UDP checksum，IPv4 允许）
  - `s_udp_hdr_valid` 拉高；`s_udp_hdr_ready` 后进入 `SEND`。
  - 若 ARP 未解析，`s_udp_hdr_ready` 可能保持低，读侧在此等待；ARP 失败由 `udp_complete` 丢包并置 `tx_error_arp_failed`。
- `SEND`：
  - 从数据 FIFO 读取，驱动 `s_udp_payload_axis_*`。
  - `tlast = (send_cnt == meta_len-1)`；`tuser = meta_tuser && tlast`。
  - 最后一拍握手完成后回到 `IDLE`。
- `DROP`：
  - 从数据 FIFO 读并丢弃 `meta_len` 字节，不发包。
  - 丢弃完成时脉冲 `tx_error_overflow` 一拍，回到 `IDLE`。

### 5.3 并发与吞吐

- 写侧和读侧是独立状态机，可同时工作。
- 读侧发送当前包时，写侧可在数据 FIFO 剩余空间足够时接收下一包。
- 4 KB FIFO + 1472 字节上限：最多可同时容纳 2 个满载包，背靠背满载包可接近线速。
- 当 FIFO 剩余空间 < `MAX_PAYLOAD_LEN` 时，写侧通过 `s_axis_tx_tready=0` 反压应用。

### 5.4 数据 FIFO 占用统计

- 维护 `wr_bytes` / `rd_bytes` 两个计数器，在各自 AXIS 握手时递增。
- `used = wr_bytes - rd_bytes`；`free = TX_FIFO_DEPTH - used`。
- 计数器位宽 `$clog2(TX_FIFO_DEPTH)+1`，利用模运算即可正确表示不超过深度的占用。
- `TX_FIFO_DEPTH` 必须为 2 的幂（`axis_fifo` 会向上取整），默认 4096。

### 5.5 FIFO 实例参数

- 数据 FIFO（`axis_fifo`）：
  - `DEPTH=TX_FIFO_DEPTH`、`DATA_WIDTH=8`
  - `KEEP_ENABLE=0`、`LAST_ENABLE=0`、`USER_ENABLE=0`、`ID_ENABLE=0`、`DEST_ENABLE=0`
  - `FRAME_FIFO=0`（按字节流处理，包边界由元数据长度决定）
- 元数据 FIFO（`axis_srl_fifo`）：
  - `DATA_WIDTH = $clog2(MAX_PAYLOAD_LEN+1)`（长度）
  - `DEST_ENABLE=1`、`DEST_WIDTH=32`（`[15:0]=目的端口`，`[31:16]=源端口`）
  - `USER_ENABLE=1`、`USER_WIDTH=1`（tuser）
  - `LAST_ENABLE=1`（`tlast` 复用为 `drop` 标志）
  - `DEPTH=META_FIFO_DEPTH`

## 6. RX 数据通路与目的 IP 过滤

- `eth_axis_rx` 把 MAC RX 原始帧拆成以太网头 + payload，送入 `udp_complete.s_eth_*`。
- 当 `m_udp_hdr_valid && m_udp_hdr_ready`：
  - 锁存 `rx_source_port_reg = m_udp_source_port`、`rx_dest_port_reg = m_udp_dest_port`。
  - 计算 `rx_ip_match = (m_udp_ip_dest_ip == LOCAL_IP)`。
  - 置 `rx_active=1`；`rx_drop = !rx_ip_match`。
- `m_udp_hdr_ready = !rx_active`：总是接收帧头，即使目的 IP 不匹配也不反压上游，避免阻塞 IP 接收通路。
- 匹配时（`rx_drop=0`）payload 直通：
  - `m_axis_rx_tdata   = m_udp_payload_axis_tdata`
  - `m_axis_rx_tvalid  = m_udp_payload_axis_tvalid && rx_active && !rx_drop`
  - `m_axis_rx_tlast   = m_udp_payload_axis_tlast`
  - `m_axis_rx_tuser   = m_udp_payload_axis_tuser`
  - `m_axis_rx_tdest   = {rx_source_port_reg, rx_dest_port_reg}`
  - `m_udp_payload_axis_tready = m_axis_rx_tready`
- 不匹配时（`rx_drop=1`）：
  - `m_udp_payload_axis_tready = 1'b1`，payload 被静默读走丢弃。
  - `m_axis_rx_tvalid = 0`，应用侧看不到该包。
  - payload 最后一拍握手后脉冲 `rx_drop_ip_mismatch` 一拍。
- 最后一拍握手后清除 `rx_active`。
- 不做 UDP 端口过滤；目的 IP 匹配的 UDP 包都输出。

### 6.1 非 UDP IP 包与 ICMP echo

`udp_complete` 把非 UDP 的 IP 包从 `m_ip_*` 输出。封装模块内部接 `icmp_echo`：

- `ICMP_ECHO_ENABLE=1`（默认）：
  - `icmp_echo` 接收 `udp_complete.m_ip_*`。
  - 只处理：非分片（`fragment_offset == 0` 且 MF=0）、IHL=5（无 IP options）、目的 IP == `LOCAL_IP`、ICMP type=8/code=0 的 echo request。
  - 其他非 UDP 包（ICMP 其他类型、TCP、IGMP 等）接收后直接丢弃，避免阻塞 RX 通路。
  - **cut-through 回复**：解析 ICMP 前 4 字节（type/code/checksum）后立即开始回复，不等待整包。
    - type 改为 0、code 改为 0。
    - checksum 采用增量调整：`new_csum = old_csum + 0x0800`（带进位折叠）。因为只有 type 从 `0x08` 变为 `0x00`，16 位字从 `0x0800` 变为 `0x0000`。
    - id/sequence/payload 原样透传；用 `ICMP_FIFO_DEPTH`（默认 64 字节）的弹性 FIFO 延迟输入字节并吸收下游反压。
    - 若输出反压导致 FIFO 满，则拉低 `s_ip_payload_axis_tready` 反压上游。
  - **不校验请求的 ICMP checksum**（cut-through 的代价）；假设请求 checksum 有效。
  - 回复通过 `udp_complete.s_ip_*` 发送；IP header checksum、ARP、以太网头由 `ip_complete` 负责。
  - 回复 IP 头的 TTL **镜像请求的 `m_ip_ttl`**：锁存请求的 TTL，回复时通过 `s_ip_ttl` 原样送出。
  - TTL 属于 IP 头，不参与 ICMP checksum，所以上面的增量 checksum 算法与 TTL 取值无关；IP 头 checksum 由 `ip_complete` 的 `ip_eth_tx` 重新计算（包含 TTL）。
  - 请求短于 8 字节、分片、目的 IP 不匹配或 `tuser` 置位时不回复；若回复中途 `tuser` 置位，则把 `tuser` 透传到回复最后一拍，由 MAC 标记坏帧。
- `ICMP_ECHO_ENABLE=0`：把 `m_ip_*` 接成「接收即丢弃」（`m_ip_hdr_ready=1`、`m_ip_payload_axis_tready=1`），`s_ip_*` 输入接 0。

#### ICMP 与 UDP 的仲裁

不需要额外的以太网层仲裁器，`udp_complete` 内部已经有两级仲裁：

1. `udp_complete` 内部的 `ip_arb_mux`（2 路）：
   - 路 0：外部 `s_ip_*`（我们的 ICMP 回复）
   - 路 1：内部 UDP TX 的 `udp_tx_ip_*`
   - 按 **IP 包**粒度仲裁；`acknowledge` 只在被授权路的 payload `tlast` 时产生，因此一个包不会被中途打断。
   - 当前配置 `ARB_LSB_HIGH_PRIORITY=1`，外部 IP（ICMP）优先；ping 速率很低，对 UDP 数据流影响可忽略。
2. `ip_complete` 内部的 `eth_arb_mux`：ARP 帧与 IP 帧按以太网帧粒度仲裁。

最终只有一路以太网帧流进入 `eth_axis_tx` → MAC，所以 ICMP 回复和 UDP 包不会在 MAC 上冲突。

`icmp_echo` 是独立模块 `rtl/icmp_echo.v`，接口为：

- IP RX：`s_ip_hdr_valid/ready`、`s_ip_ihl`、`s_ip_ttl`、`s_ip_source_ip`、`s_ip_dest_ip`、`s_ip_protocol`、`s_ip_length`、`s_ip_flags`、`s_ip_fragment_offset`、`s_ip_payload_axis_*`
- IP TX：`m_ip_hdr_valid/ready`、`m_ip_dscp/ecn/length/ttl/protocol/source_ip/dest_ip`、`m_ip_payload_axis_*`；其中 `m_ip_ttl` 来自锁存的请求 TTL。
- 状态：`busy`、`error_overflow`

参数：`LOCAL_IP`、`FIFO_DEPTH`（默认 64）。

## 7. 状态与错误

| 信号 | 来源/含义 |
|---|---|
| `tx_busy` | 写侧非 IDLE，或读侧非 IDLE，或元数据 FIFO 非空 |
| `rx_busy` | `rx_active` 或 `m_udp_hdr_valid` |
| `tx_error_overflow` | 应用发送的 payload 超过 `MAX_PAYLOAD_LEN`，该包被丢弃 |
| `tx_error_arp_failed` | `udp_complete.ip_tx_error_arp_failed`，ARP 解析失败导致丢包 |
| `tx_error_payload_early_termination` | `udp_complete.udp_tx_error_payload_early_termination`（正常流程不应出现） |
| `rx_error_header_early_termination` | `eth_axis_rx.error_header_early_termination` 或 `udp_complete.udp_rx_error_header_early_termination` |
| `rx_error_payload_early_termination` | `udp_complete.udp_rx_error_payload_early_termination` |
| `rx_error_invalid_header` | `udp_complete.ip_rx_error_invalid_header` |
| `rx_error_invalid_checksum` | `udp_complete.ip_rx_error_invalid_checksum` |
| `rx_drop_ip_mismatch` | RX 目的 IP 不等于 `LOCAL_IP`，该包被静默丢弃；payload 结束时脉冲一拍 |
| `icmp_error_overflow` | ICMP 弹性 FIFO 溢出（正常 AXIS 反压下不应发生）；出现时当前回复被丢弃 |

`clear_arp_cache` 直接接入 `udp_complete.clear_arp_cache`。

## 8. 参数配置到 `udp_complete`

| `udp_complete` 端口 | 连接 |
|---|---|
| `local_mac` | `LOCAL_MAC` |
| `local_ip` | `LOCAL_IP` |
| `gateway_ip` | `GATEWAY_IP` |
| `subnet_mask` | `SUBNET_MASK` |
| `clear_arp_cache` | 同名输入 |
| `ARP_*` 参数 | 同名参数 |
| `UDP_CHECKSUM_GEN_ENABLE` | 同名参数 |
| `UDP_CHECKSUM_PAYLOAD_FIFO_DEPTH` | 同名参数 |
| `UDP_CHECKSUM_HEADER_FIFO_DEPTH` | 同名参数 |

## 9. 多通道 ADC 应用说明（典型用例）

本模块的典型使用场景是多通道 ADC 数据上传：应用侧把每个通道的数据切成完整 UDP payload，用 `TDEST[15:0]` 指定该通道的目的端口（例如 `BASE_PORT + channel`），主机按端口区分通道。

### 9.1 带宽预算

- 总数据率 ≤ 500 Mbps 时，1G 链路（约 950 Mbps UDP 有效吞吐）留有余量。
- 推荐 payload 1024–1472 字节；500 Mbps 时 1472 字节约 42k 包/秒。
- 不建议长期使用小于 256 字节的小包，否则协议头开销和包速率都会显著上升。

### 9.2 应用侧职责

模块保持精简，以下逻辑由应用侧实现：

1. ADC 样本按字节打包（确定大小端）。
2. 每通道 packetizer：攒够 N 个样本后输出一包，最后一拍拉高 `tlast`。
3. 多通道仲裁：任一时刻只把**一个完整包**送到 `s_axis_tx_*`，不能在包中间切换通道。
4. `TDEST` 赋值：`TDEST[15:0] = 通道目的端口`；`TDEST[31:16] = 源端口`（可用固定服务端口，也可按通道区分）。

推荐在 payload 开头加应用层小头，例如：

```
{magic, channel_id, sequence, timestamp}
```

用于主机检测丢包、乱序和做多通道时间对齐。UDP/IP 本身不保证这些。

### 9.3 缓冲深度

- 1472 字节包：4 KB FIFO 可容纳约 2 包；`META_FIFO_DEPTH=8` 足够。
- 小包（如 256 字节）：可同时容纳更多包，但元数据 FIFO 深度会先成为限制；需要更多在途包时增大 `META_FIFO_DEPTH`。
- 应用侧仲裁器必须等当前包完全进入 FIFO（`tlast` 被接收）后才能切换通道。

### 9.4 主机侧

- 最简单：每个通道目的端口一个 UDP socket。
- 若用单 socket 收所有通道，需要 `recvmsg` + `IP_PKTINFO`（Linux）或 raw socket 来获取目的端口。
- 建议监控 `tx_error_arp_failed` / `tx_error_overflow`，并通过 payload 序列号检测丢包。

### 9.5 延迟

- store-and-forward 每包增加最多一个包时间的延迟（1472 字节 @1G 约 12 µs）。
- 首包还要等待 ARP 解析；之后 ARP 缓存命中，延迟稳定。

## 10. 限制与已知行为

1. 单时钟域，8-bit 数据通路。
2. 目的 IP 固定；只面向一个对端（或网关）。
3. 最小 payload 为 1 字节：8-bit AXIS 无法表达 0 字节包。
4. 最大 payload 为 `MAX_PAYLOAD_LEN`（默认 1472）；更长包被丢弃并报 `tx_error_overflow`。
5. 需要 `MAX_PAYLOAD_LEN <= TX_FIFO_DEPTH`，在 `initial` 中做 elaboration 检查。
6. ARP 未解析时，第一包会等待解析；解析失败则丢包并脉冲 `tx_error_arp_failed`。
7. UDP checksum 默认开启；需要 `UDP_CHECKSUM_PAYLOAD_FIFO_DEPTH >= MAX_PAYLOAD_LEN + 8`（默认 2048 > 1480）。
8. TX `tuser` 按整包 OR，并附加到最后一拍；`axis_gmii_tx` 用 `tuser[0]` 标记坏帧。
9. RX `tuser` 原样透传。
10. 接收只接受目的 IP == `LOCAL_IP` 的 UDP 包；不做 UDP 端口过滤；广播/组播不接收。IP 分片处理沿用 `udp_complete`。
11. TX 源端口完全由 `TDEST[31:16]` 给出，模块没有默认源端口参数；`TDEST[31:16]=0` 表示源端口为 0。
12. RX `TDEST[31:16] = 源端口`、`TDEST[15:0] = 目的端口`。
13. 内置 ICMP echo 只响应非分片、目的 IP == `LOCAL_IP` 的 type=8/code=0 请求；其他非 UDP IP 包接收后丢弃。
14. ICMP 采用 cut-through：不校验请求 checksum；回复 checksum 由请求 checksum 增量调整得到，请求 checksum 错误时回复也会错误。
15. ICMP 回复经 `ip_complete` 发送，目的 MAC 由 ARP 解析；通常 pinger 的 MAC 已在 ARP 缓存中，否则首包会多一次 ARP。
16. `ICMP_FIFO_DEPTH`（默认 64 字节）只用于延迟和反压吸收，不限制 ICMP 消息总长；正常 AXIS 反压下不会溢出。
17. 请求短于 8 字节、分片、目的 IP 不匹配或 `tuser` 置位时不回复。
18. ICMP 回复的 IP TTL **镜像请求的 `m_ip_ttl`**：在接收请求头时锁存，回复时通过 `s_ip_ttl` 送出。

## 11. 验证方案（vsim）

本机使用 ModelSim/Questa（`vsim`）仿真，不依赖 cocotb。

### 11.1 目录与构建

新增 `tb/udp_axis_complete/`：

- `tb_udp_axis_complete.v`：顶层 testbench。
- `Makefile`：目标 `sim` 使用 `vlib` / `vlog` / `vsim -c`；`clean` 删除 `work/` 与波形。

编译源包括：

- `rtl/udp_axis_complete.v`、`rtl/icmp_echo.v`
- `rtl/eth_axis_rx.v`、`rtl/eth_axis_tx.v`
- `rtl/udp_complete.v`、`rtl/udp.v`、`rtl/udp_ip_rx.v`、`rtl/udp_ip_tx.v`、`rtl/udp_checksum_gen.v`
- `rtl/ip_complete.v`、`rtl/ip.v`、`rtl/ip_eth_rx.v`、`rtl/ip_eth_tx.v`、`rtl/ip_arb_mux.v`
- `rtl/arp.v`、`rtl/arp_cache.v`、`rtl/arp_eth_rx.v`、`rtl/arp_eth_tx.v`
- `rtl/eth_arb_mux.v`
- `lib/axis/rtl/axis_fifo.v`、`axis_srl_fifo.v`、`axis_async_fifo.v`、`axis_async_fifo_adapter.v`、`arbiter.v`、`priority_encoder.v`、`sync_reset.v`

### 11.2 Testbench 模型

- 时钟/复位。
- MAC 侧模型：
  - 监视 `m_eth_tx_axis_*`，收集完整帧，解析 Ethernet/IP/UDP 头。
  - 驱动 `s_eth_rx_axis_*`，注入构造好的以太网帧。
  - ARP 响应器：检测 ARP 请求，按 `DEST_IP` 返回 ARP reply。
- 记分板：payload、端口、长度、checksum 比对，统计 pass/fail。

### 11.3 测试用例

1. **ARP 解析**：TX 发一包 → 观察到 ARP 请求 → TB 回 ARP reply → 观察到 UDP 帧。
2. **基本 TX**：1 字节、100 字节、1472 字节；校验 MAC/IP/UDP 头、长度、IP/UDP checksum、目的端口、payload。
3. **不同端口**：连续发送 `TDEST={16'd1234,16'd1234}`、`TDEST={16'd4321,16'd4321}`、`TDEST={16'd6000,16'd1234}` 的包；校验源端口分别为 1234/4321/6000，目的端口分别为 1234/4321/1234。
4. **背靠背**：连续发送多个 1472 字节包，验证边发边收与长度正确。
5. **RX**：注入目的 IP = `LOCAL_IP`、源端口 5000、目的端口 7000 的 UDP 帧，校验 `m_axis_rx_tdest={16'd5000,16'd7000}`、payload、`tlast`。
6. **RX IP 过滤**：注入目的 IP ≠ `LOCAL_IP` 的 UDP 帧，确认应用侧无输出、`rx_drop_ip_mismatch` 脉冲；随后注入匹配包，确认仍能正常输出。
7. **溢出**：发送 >1472 字节包，校验 `tx_error_overflow`，并确认后续正常包仍可发送。
8. **ARP 失败**（可选）：把 ARP 重试/超时参数调小，不回应 ARP，校验 `tx_error_arp_failed`。
9. **ICMP ping**：注入目的 IP = `LOCAL_IP` 的 ICMP echo request（type=8/code=0），校验回复：type=0/code=0、ICMP checksum = 请求 checksum + `0x0800`（带进位折叠）、id/sequence/payload 原样、源 IP=`LOCAL_IP`、目的 IP=请求源 IP、**IP TTL = 请求 TTL**；用 8/56/1000 字节 payload 验证流式与反压；再注入非 echo ICMP、目的 IP 不匹配、分片、短于 8 字节的请求，确认均不回复。另做下游反压测试：拉低 `s_ip_payload_axis_tready`，确认输入被正确反压且无丢字节。

## 12. 验收标准

- `rtl/udp_axis_complete.v` 和 `rtl/icmp_echo.v` 可在 Vivado 2024.2 下综合，无 latch、无多驱动。
- `tb/udp_axis_complete` 的 vsim 回归全部通过。
- 模块端口、参数与本文档一致。
- 应用侧仅通过 AXIS 接入；MAC 侧仅通过裸帧 AXIS 接入。
