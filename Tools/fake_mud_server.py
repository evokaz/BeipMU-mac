#!/usr/bin/env python3
"""Deterministic MU* fixture server.

Scenario JSON is an array of actions:
  {"send": "text"}
  {"send_hex": "fffb19"}
  {"expect": "text"}
  {"expect_hex": "fffd19"}
  {"delay_ms": 50}
  {"disconnect": true}

Each send can set ``chunks`` to split output at explicit byte offsets.
"""

import argparse
import asyncio
import json
import pathlib
import ssl


def payload(action, key, hex_key):
    if key in action:
        return action[key].encode("utf-8")
    return bytes.fromhex(action[hex_key])


async def run_scenario(reader, writer, scenario):
    try:
        for action in scenario:
            if "delay_ms" in action:
                await asyncio.sleep(action["delay_ms"] / 1000)
            elif "send" in action or "send_hex" in action:
                data = payload(action, "send", "send_hex")
                boundaries = [0] + action.get("chunks", []) + [len(data)]
                for start, end in zip(boundaries, boundaries[1:]):
                    writer.write(data[start:end])
                    await writer.drain()
            elif "expect" in action or "expect_hex" in action:
                expected = payload(action, "expect", "expect_hex")
                actual = await reader.readexactly(len(expected))
                if actual != expected:
                    raise AssertionError(f"expected {expected!r}, received {actual!r}")
            elif action.get("disconnect"):
                break
    finally:
        writer.close()
        await writer.wait_closed()


async def main(args):
    scenario = json.loads(pathlib.Path(args.scenario).read_text())
    context = None
    if args.certificate and args.key:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(args.certificate, args.key)
    server = await asyncio.start_server(
        lambda reader, writer: run_scenario(reader, writer, scenario),
        args.host,
        args.port,
        ssl=context,
    )
    addresses = ", ".join(str(sock.getsockname()) for sock in server.sockets)
    print(f"Fake MU* server listening on {addresses}", flush=True)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("scenario")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8888)
    parser.add_argument("--certificate")
    parser.add_argument("--key")
    asyncio.run(main(parser.parse_args()))

