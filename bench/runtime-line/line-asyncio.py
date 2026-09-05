#!/usr/bin/env python3
import asyncio
import socket
import sys

HOST = sys.argv[1] if len(sys.argv) > 1 else '127.0.0.1'
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 0


async def handle_client(reader, writer):
    sock = writer.get_extra_info('socket')
    if sock is not None:
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

    try:
        while True:
            line = await reader.readline()
            if not line:
                break
            writer.write(line)
            await writer.drain()
    except (ConnectionError, BrokenPipeError):
        pass
    finally:
        writer.close()
        try:
            await writer.wait_closed()
        except (ConnectionError, BrokenPipeError):
            pass


async def main():
    server = await asyncio.start_server(
        handle_client,
        HOST,
        PORT,
        backlog=8192,
        limit=16 * 1024 * 1024,
    )
    port = server.sockets[0].getsockname()[1]
    print(f'READY {port}', flush=True)
    async with server:
        await server.serve_forever()


if __name__ == '__main__':
    asyncio.run(main())
