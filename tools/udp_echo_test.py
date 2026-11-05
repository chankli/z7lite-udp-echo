#!/usr/bin/env python3
"""UDP echo test for the Z7-LITE verilog-ethernet example.

The FPGA design listens on UDP port 1234 at 192.168.10.128 and echoes the
payload back to the fixed ECHO_DEST_IP (default 192.168.10.100).  Run this
script on the host that owns that address.

Examples:
    python udp_echo_test.py
    python udp_echo_test.py "hello" --count 10
    python udp_echo_test.py --local-ip 192.168.10.100 --dut-ip 192.168.10.128
"""
import argparse
import socket
import sys
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dut-ip", default="192.168.10.128")
    parser.add_argument("--dut-port", type=int, default=1234)
    parser.add_argument("--local-ip", default="192.168.10.100",
                        help="must match ECHO_DEST_IP in fpga.v/fpga_core.v")
    parser.add_argument("--local-port", type=int, default=0,
                        help="0 = let the OS choose the source port")
    parser.add_argument("--timeout", type=float, default=2.0)
    parser.add_argument("--count", type=int, default=1)
    parser.add_argument("--interval", type=float, default=0.2)
    parser.add_argument("payload", nargs="?", default="hello z7-lite")
    args = parser.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.bind((args.local_ip, args.local_port))
    except OSError as exc:
        print(f"bind {args.local_ip}:{args.local_port} failed: {exc}")
        print("Set the Ethernet adapter to 192.168.10.100/24, or pass "
              "--local-ip with the address that matches ECHO_DEST_IP.")
        return 1
    sock.settimeout(args.timeout)

    local = sock.getsockname()
    print(f"local {local[0]}:{local[1]} -> {args.dut_ip}:{args.dut_port}")

    passed = 0
    for index in range(args.count):
        if args.count == 1:
            payload = args.payload.encode()
        else:
            payload = f"{args.payload} #{index}".encode()

        sock.sendto(payload, (args.dut_ip, args.dut_port))
        try:
            data, addr = sock.recvfrom(2048)
        except socket.timeout:
            print(f"[{index}] timeout (no reply)")
            continue

        print(f"[{index}] reply from {addr[0]}:{addr[1]}: {data!r}")
        if data == payload:
            print(f"[{index}] PASS")
            passed += 1
        else:
            print(f"[{index}] FAIL: payload mismatch")

        if index + 1 < args.count:
            time.sleep(args.interval)

    print(f"{passed}/{args.count} passed")
    return 0 if passed == args.count else 1


if __name__ == "__main__":
    sys.exit(main())
