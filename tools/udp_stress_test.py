#!/usr/bin/env python3
"""UDP echo stress test for the Z7-LITE verilog-ethernet example.

Sends back-to-back UDP packets of several payload sizes to the FPGA and
measures the echoed throughput.  The FPGA design echoes UDP port 1234 to
the fixed ECHO_DEST_IP (default 192.168.10.100), so run this on the host
that owns that address.

Examples:
    python udp_stress_test.py
    python udp_stress_test.py --count 20000
    python udp_stress_test.py --sizes 64,256,1024,1472 --count 20000
"""
import argparse
import socket
import struct
import sys
import threading
import time

DEFAULT_SIZES = "1,2,4,8,16,32,64,128,256,512,1024,1400,1472"


def build_payload(seq, size):
    if size >= 4:
        return struct.pack("!I", seq & 0xFFFFFFFF) + bytes([seq & 0xFF]) * (size - 4)
    return bytes([seq & 0xFF]) * size


def run_one(sock, dut, size, count, warmup_timeout, drain_timeout, pps):
    # Warm up / resolve ARP first.
    sock.sendto(build_payload(0, size), dut)
    try:
        data, _ = sock.recvfrom(65535)
    except socket.timeout:
        print(f"{size:5d}  no reply to warm-up packet")
        return False
    if len(data) != size:
        print(f"{size:5d}  warm-up reply length {len(data)} != {size}")

    # The receiver thread must exit quickly when the test is over.
    sock.settimeout(0.2)

    stats = {"count": 0, "bytes": 0, "last": None, "lat": []}
    lock = threading.Lock()
    stop = threading.Event()
    send_times = {}

    def receiver():
        while not stop.is_set():
            try:
                data, _ = sock.recvfrom(65535)
            except socket.timeout:
                continue
            except OSError:
                break
            now = time.perf_counter()
            latency = None
            if len(data) >= 4:
                seq = struct.unpack("!I", data[:4])[0]
                sent_at = send_times.get(seq)
                if sent_at is not None:
                    latency = (now - sent_at) * 1000.0
            with lock:
                stats["count"] += 1
                stats["bytes"] += len(data)
                stats["last"] = now
                if latency is not None:
                    stats["lat"].append(latency)

    thread = threading.Thread(target=receiver, daemon=True)
    thread.start()

    send_errors = 0
    start = time.perf_counter()
    for seq in range(count):
        if pps > 0:
            target = start + (seq + 1) / pps
            now = time.perf_counter()
            if target > now:
                time.sleep(target - now)
        payload = build_payload(seq, size)
        send_times[seq] = time.perf_counter()
        try:
            sock.sendto(payload, dut)
        except OSError:
            send_errors += 1
            time.sleep(0.001)
            if send_errors > 20:
                break
    send_end = time.perf_counter()

    # Wait for the echo to drain.
    while time.perf_counter() - send_end < drain_timeout:
        with lock:
            if stats["count"] >= count:
                break
        time.sleep(0.01)

    stop.set()
    thread.join(timeout=1.0)

    with lock:
        recv_count = stats["count"]
        recv_bytes = stats["bytes"]
        lat = list(stats["lat"])
        last = stats["last"]

    elapsed = (last if last is not None else send_end) - start
    if elapsed <= 0:
        elapsed = send_end - start

    send_pps = count / max(send_end - start, 1e-9)
    recv_pps = recv_count / max(elapsed, 1e-9)
    payload_mbps = recv_bytes * 8.0 / max(elapsed, 1e-9) / 1e6

    # One-way wire estimate: max(64, Ethernet header 14 + IP 20 + UDP 8 + payload + FCS 4)
    # plus 8-byte preamble and 12-byte IFG.  The echo doubles this load on the link.
    frame_bytes = max(64, 14 + 20 + 8 + size + 4)
    wire_mbps = recv_count * (frame_bytes + 8 + 12) * 8.0 / max(elapsed, 1e-9) / 1e6

    loss = max(0.0, (count - recv_count) * 100.0 / count)
    if lat:
        lat_min = min(lat)
        lat_avg = sum(lat) / len(lat)
        lat_max = max(lat)
        lat_text = f"{lat_min:.3f}/{lat_avg:.3f}/{lat_max:.3f}"
    else:
        lat_text = "n/a"

    print(
        f"{size:5d}  {count:7d}  {recv_count:7d}  {loss:6.1f}%  "
        f"{send_pps:9.0f}  {recv_pps:9.0f}  {payload_mbps:10.2f}  "
        f"{wire_mbps:9.2f}  {lat_text}"
    )
    if send_errors:
        print(f"       {send_errors} sendto errors (OS send buffer full)")
    return recv_count > 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dut-ip", default="192.168.10.128")
    parser.add_argument("--dut-port", type=int, default=1234)
    parser.add_argument("--local-ip", default="192.168.10.100")
    parser.add_argument("--sizes", default=DEFAULT_SIZES)
    parser.add_argument("--count", type=int, default=5000)
    parser.add_argument("--pps", type=float, default=0,
                        help="optional send rate limit in packets/s (0 = max)")
    parser.add_argument("--warmup-timeout", type=float, default=5.0)
    parser.add_argument("--drain-timeout", type=float, default=2.0)
    args = parser.parse_args()

    sizes = [int(s) for s in args.sizes.split(",") if s.strip()]
    sizes = [s for s in sizes if s > 0]
    if not sizes:
        print("no valid payload sizes")
        return 1

    print(f"target {args.dut_ip}:{args.dut_port} from {args.local_ip}")
    print(
        "  size    sent     recv    loss    send_pps   recv_pps   "
        "payload_Mbps  wire_Mbps  lat_min/avg/max(ms)"
    )

    any_reply = False
    for size in sizes:
        if size > 1472:
            print(f"{size:5d}  skipped: design MAX_PAYLOAD_LEN is 1472")
            continue

        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 * 1024 * 1024)
        except OSError:
            pass
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1 * 1024 * 1024)
        except OSError:
            pass
        sock.bind((args.local_ip, 0))
        sock.settimeout(args.warmup_timeout)

        # Run the receiver with a short timeout after the warm-up.
        try:
            ok = run_one(
                sock,
                (args.dut_ip, args.dut_port),
                size,
                args.count,
                args.warmup_timeout,
                args.drain_timeout,
                args.pps,
            )
        except OSError as exc:
            print(f"{size:5d}  error: {exc}")
            ok = False
        finally:
            sock.close()

        # Let the OS release the UDP buffers before the next size.
        time.sleep(0.3)

        if ok:
            any_reply = True
        else:
            print("       stopping: no echo replies")
            break

    if not any_reply:
        print()
        print("No replies.  Check:")
        print("  - FPGA is programmed with a working bit (rev110 with MDIO fallback,")
        print("    or rev109 with PUDC_B JP1 pin 37 strapped to 3.3V)")
        print("  - PC Ethernet is 192.168.10.100/24 and ping 192.168.10.128 works")
        print("  - The board's RJ45 link/activity LEDs are on")
        return 1

    print()
    print("wire_Mbps is a one-way Ethernet estimate; the echo doubles the link load.")
    print("Small-packet rates can be limited by the Python sender/receiver, not the FPGA.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
