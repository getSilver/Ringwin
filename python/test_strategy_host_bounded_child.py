"""Controlled pipe faults for the real ManagedHost integration acceptance."""
import os
import struct
import sys
import threading
import time

import strategy_host as host


def main():
    # Independent test cleanup; reaching this limit is never a product success.
    threading.Timer(10, lambda: os._exit(99)).start()
    mode = sys.argv[2]
    if mode == "silent":
        time.sleep(20)
    _, _, _, plan = host.read_frame(sys.stdin.buffer)
    session, hello = host.hello_payload(plan)
    if mode == "prefix":
        sys.stdout.buffer.write(struct.pack("<I", 224))
        sys.stdout.buffer.flush()
    elif mode == "trickle":
        sys.stdout.buffer.write(struct.pack("<I", 224))
        for _ in range(100):
            sys.stdout.buffer.write(b"x")
            sys.stdout.buffer.flush()
            time.sleep(0.08)
    elif mode == "partial":
        sys.stdout.buffer.write(struct.pack("<I", 224) + b"QSHC")
        sys.stdout.buffer.flush()
    else:
        host.write_frame(sys.stdout.buffer, host.HOST_HELLO, session, 1, hello)
        host.write_frame(sys.stdout.buffer, host.HOST_HEARTBEAT, session, 2, struct.pack("<QQ", 0, 0))
        if mode == "ack-hang":
            host.read_frame(sys.stdin.buffer)
            host.write_frame(sys.stdout.buffer, host.SHUTDOWN_ACK, session, 3)
        elif mode == "checkpoint":
            host.read_frame(sys.stdin.buffer)
            host.read_frame(sys.stdin.buffer)
    time.sleep(20)


if __name__ == "__main__":
    main()
