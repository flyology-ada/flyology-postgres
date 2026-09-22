#!/usr/bin/env python3
"""Check role-specific SCRAM mock challenges from the Flyology server."""

import base64
import hashlib
import hmac
import socket
import ssl
import struct
import sys


def receive(connection, size):
    result = b""
    while len(result) < size:
        part = connection.recv(size - len(result))
        if not part:
            raise RuntimeError("server closed during SCRAM exchange")
        result += part
    return result


def frame(connection):
    tag = receive(connection, 1)
    size = struct.unpack("!I", receive(connection, 4))[0]
    return tag, receive(connection, size - 4)


def challenge(role, port):
    connection = socket.create_connection(("127.0.0.1", port), timeout=3)
    connection.sendall(struct.pack("!II", 8, 80877103))
    if receive(connection, 1) != b"S":
        raise RuntimeError("server rejected SSLRequest")

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    with context.wrap_socket(connection, server_hostname="localhost") as secure:
        startup = (
            b"\x00\x03\x00\x00user\x00"
            + role.encode()
            + b"\x00database\x00postgres\x00\x00"
        )
        secure.sendall(struct.pack("!I", len(startup) + 4) + startup)
        tag, body = frame(secure)
        if tag != b"R" or struct.unpack("!I", body[:4])[0] != 10:
            raise RuntimeError("expected AuthenticationSASL")

        first = b"n,,n=,r=flyology-scram-mock-check"
        response = b"SCRAM-SHA-256\x00" + struct.pack("!I", len(first)) + first
        secure.sendall(b"p" + struct.pack("!I", len(response) + 4) + response)
        tag, body = frame(secure)
        if tag != b"R" or struct.unpack("!I", body[:4])[0] != 11:
            raise RuntimeError("expected AuthenticationSASLContinue")

        fields = dict(
            part.split("=", 1) for part in body[4:].decode().split(",")
        )
        return fields["s"], fields["i"]


port = int(sys.argv[1])
unknown_a = challenge("unknown-a", port)
unknown_a_again = challenge("unknown-a", port)
unknown_b = challenge("unknown-b", port)
known = challenge("flyology", port)
published_salt = "Zml4ZWQgZHVtbXkgc2FsdA=="
expected_unknown_a = base64.b64encode(
    hmac.new(bytes([0x47]) * 32, b"unknown-a", hashlib.sha256).digest()[:16]
).decode()

if unknown_a != unknown_a_again:
    raise RuntimeError("the same absent role received unstable mock challenges")
if unknown_a[0] != expected_unknown_a:
    raise RuntimeError("mock salt did not match the configured secret and role")
if unknown_a[0] == unknown_b[0]:
    raise RuntimeError("different absent roles received the same mock salt")
if published_salt in (unknown_a[0], unknown_b[0]):
    raise RuntimeError("an absent role received the old published mock salt")
if unknown_a[0] == known[0] or unknown_b[0] == known[0]:
    raise RuntimeError("an absent role received the known role's salt")
if unknown_a[1] != "4096" or unknown_b[1] != "4096":
    raise RuntimeError(
        "mock challenge did not use the approved iteration count"
    )

print("Flyology SCRAM role-specific mock challenges passed")
