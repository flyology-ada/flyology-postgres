#!/usr/bin/env python3
"""Deterministic bounded-buffer TCP proxy for replication integration tests."""

import argparse
import signal
import socket
import struct
import threading
import time


class Splitter:
    def __init__(self, seed: int, maximum: int) -> None:
        self.state = seed & 0xFFFFFFFF or 1
        self.maximum = maximum

    def next_size(self) -> int:
        value = self.state
        value ^= (value << 13) & 0xFFFFFFFF
        value ^= value >> 17
        value ^= (value << 5) & 0xFFFFFFFF
        self.state = value & 0xFFFFFFFF
        return 1 + self.state % self.maximum


def configure(channel: socket.socket, buffer_size: int) -> None:
    channel.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    channel.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, buffer_size)
    channel.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, buffer_size)


def relay(
    source: socket.socket,
    destination: socket.socket,
    splitter: Splitter,
    read_size: int,
    delay: float,
    totals: list[int],
    index: int,
    reset_after: int,
    reset_channels: tuple[socket.socket, socket.socket],
    reset_done: threading.Event,
    stall_after: int,
    stall_seconds: float,
    trace: bool = False,
) -> None:
    stalled = False
    way = "s2c" if index == 2 else "c2s"

    def note(event: str) -> None:
        if trace:
            print(
                f"{time.monotonic():.4f} {way} {event} total={totals[index]}",
                flush=True,
            )

    try:
        while True:
            note("recv-wait")
            data = source.recv(read_size)
            note(f"recv-got={len(data)}")
            if not data:
                break
            offset = 0
            while offset < len(data):
                end = min(len(data), offset + splitter.next_size())
                view = memoryview(data)[offset:end]
                while view:
                    if reset_after:
                        remaining = reset_after - totals[index]
                        if remaining <= 0:
                            break
                        view = view[:remaining]
                    note(f"send-wait={len(view)}")
                    sent = destination.send(view)
                    note(f"send-done={sent}")
                    if sent == 0:
                        raise ConnectionResetError("zero-byte proxy write")
                    totals[index] += sent
                    totals[index + 1] += 1
                    view = view[sent:]
                if reset_after and totals[index] >= reset_after:
                    reset_done.set()
                    linger = struct.pack("ii", 1, 0)
                    for channel in reset_channels:
                        try:
                            channel.setsockopt(
                                socket.SOL_SOCKET, socket.SO_LINGER, linger
                            )
                            channel.close()
                        except OSError:
                            pass
                    print(
                        f"reset server_bytes={totals[index]}", flush=True
                    )
                    return
                if stall_after and not stalled and totals[index] >= stall_after:
                    stalled = True
                    print(
                        f"stall server_bytes={totals[index]} "
                        f"seconds={stall_seconds}",
                        flush=True,
                    )
                    time.sleep(stall_seconds)
                offset = end
                if delay:
                    time.sleep(delay)
    except (BrokenPipeError, ConnectionResetError, OSError) as error:
        note(f"relay-error={type(error).__name__}")
    finally:
        note("relay-exit")
        if not reset_done.is_set():
            try:
                destination.shutdown(socket.SHUT_WR)
            except OSError:
                pass


def handle(
    connection_id: int,
    client: socket.socket,
    upstream_host: str,
    upstream_port: int,
    seed: int,
    maximum_chunk: int,
    read_size: int,
    buffer_size: int,
    delay: float,
    reset_server_bytes: int,
    stall_server_bytes: int,
    stall_seconds: float,
    trace: bool = False,
) -> None:
    upstream = socket.create_connection((upstream_host, upstream_port), timeout=10)
    client.settimeout(None)
    upstream.settimeout(None)
    configure(client, buffer_size)
    configure(upstream, buffer_size)
    totals = [0, 0, 0, 0]
    reset_done = threading.Event()
    client_to_server = threading.Thread(
        target=relay,
        args=(
            client,
            upstream,
            Splitter(seed ^ (connection_id * 0x9E3779B9), maximum_chunk),
            read_size,
            delay,
            totals,
            0,
            0,
            (client, upstream),
            reset_done,
            0,
            0,
            trace,
        ),
    )
    server_to_client = threading.Thread(
        target=relay,
        args=(
            upstream,
            client,
            Splitter(seed ^ (connection_id * 0x85EBCA6B), maximum_chunk),
            read_size,
            delay,
            totals,
            2,
            reset_server_bytes,
            (client, upstream),
            reset_done,
            stall_server_bytes,
            stall_seconds,
            trace,
        ),
    )
    client_to_server.start()
    server_to_client.start()
    client_to_server.join()
    server_to_client.join()
    client.close()
    upstream.close()
    print(
        f"connection {connection_id} "
        f"client_bytes={totals[0]} client_writes={totals[1]} "
        f"server_bytes={totals[2]} server_writes={totals[3]}",
        flush=True,
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen-port", type=int, required=True)
    parser.add_argument("--upstream-port", type=int, required=True)
    parser.add_argument("--upstream-host", default="127.0.0.1")
    parser.add_argument("--seed", type=int, default=0xF10A09)
    parser.add_argument("--maximum-chunk", type=int, default=257)
    parser.add_argument("--read-size", type=int, default=4096)
    parser.add_argument("--buffer-size", type=int, default=4096)
    parser.add_argument("--delay-microseconds", type=int, default=20)
    parser.add_argument("--reset-server-bytes", type=int, default=0)
    parser.add_argument("--stall-server-bytes", type=int, default=0)
    parser.add_argument("--stall-seconds", type=float, default=0)
    parser.add_argument("--trace", action="store_true")
    args = parser.parse_args()
    if min(args.maximum_chunk, args.read_size, args.buffer_size) <= 0:
        parser.error("chunk and buffer sizes must be positive")
    if min(
        args.reset_server_bytes,
        args.stall_server_bytes,
        args.stall_seconds,
    ) < 0:
        parser.error("reset and stall parameters cannot be negative")

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", args.listen_port))
    listener.listen(16)
    signal.signal(signal.SIGTERM, lambda _signum, _frame: listener.close())
    print(
        f"ready seed={args.seed} maximum_chunk={args.maximum_chunk} "
        f"buffer_size={args.buffer_size}",
        flush=True,
    )
    connection_id = 0
    while True:
        try:
            client, _address = listener.accept()
        except OSError:
            break
        connection_id += 1
        threading.Thread(
            target=handle,
            args=(
                connection_id,
                client,
                args.upstream_host,
                args.upstream_port,
                args.seed,
                args.maximum_chunk,
                args.read_size,
                args.buffer_size,
                args.delay_microseconds / 1_000_000,
                args.reset_server_bytes,
                args.stall_server_bytes,
                args.stall_seconds,
                args.trace,
            ),
            daemon=True,
        ).start()


if __name__ == "__main__":
    main()
