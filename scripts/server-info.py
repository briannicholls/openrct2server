#!/usr/bin/env python3
import argparse
import json
import socket
import struct


MAGIC = 0x3254524F
PROTOCOL_VERSION = 2
GAME_INFO_COMMAND = 9
HEADER = struct.Struct("!IHII")
MAX_PACKET_SIZE = 1024 * 1024


def read_exact(connection: socket.socket, size: int) -> bytes:
    chunks = []
    remaining = size
    while remaining:
        chunk = connection.recv(remaining)
        if not chunk:
            raise RuntimeError("connection closed before the packet completed")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def query(host: str, port: int, timeout: float) -> dict:
    with socket.create_connection((host, port), timeout) as connection:
        connection.settimeout(timeout)
        connection.sendall(HEADER.pack(MAGIC, PROTOCOL_VERSION, 0, GAME_INFO_COMMAND))
        for _ in range(10):
            magic, version, size, command = HEADER.unpack(read_exact(connection, HEADER.size))
            if magic != MAGIC or version != PROTOCOL_VERSION:
                raise RuntimeError("unexpected OpenRCT2 response header")
            if size > MAX_PACKET_SIZE:
                raise RuntimeError("invalid OpenRCT2 response size")
            payload = read_exact(connection, size)
            if command != GAME_INFO_COMMAND:
                continue

            encoded_json, separator, _ = payload.partition(b"\0")
            if not separator:
                raise RuntimeError("OpenRCT2 response did not contain JSON")
            result = json.loads(encoded_json)
            if not isinstance(result, dict):
                raise RuntimeError("OpenRCT2 response was not an object")
            return result

    raise RuntimeError("OpenRCT2 did not return gameInfo")


def main() -> None:
    parser = argparse.ArgumentParser(description="Query OpenRCT2 gameInfo")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--timeout", type=float, default=5)
    parser.add_argument("--field")
    args = parser.parse_args()

    result = query(args.host, args.port, args.timeout)
    if args.field:
        value = result[args.field]
        if isinstance(value, (dict, list)):
            print(json.dumps(value, separators=(",", ":")))
        elif isinstance(value, bool):
            print(str(value).lower())
        else:
            print(value)
    else:
        print(json.dumps(result, separators=(",", ":"), sort_keys=True))


if __name__ == "__main__":
    main()
