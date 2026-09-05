'use strict';

const net = require('node:net');
const readline = require('node:readline');

const host = process.argv[2] || '127.0.0.1';
const port = Number(process.argv[3] || 0);

const server = net.createServer((socket) => {
  socket.setNoDelay(true);

  const lines = readline.createInterface({
    input: socket,
    terminal: false,
    crlfDelay: Infinity,
  });

  lines.on('line', (line) => {
    if (!socket.write(line + '\n')) {
      lines.pause();
      socket.once('drain', () => lines.resume());
    }
  });

  socket.on('error', () => {
    lines.close();
    socket.destroy();
  });
});

server.on('error', (error) => {
  console.error(error && error.stack ? error.stack : String(error));
  process.exit(1);
});

server.listen({host, port, backlog: 8192}, () => {
  const address = server.address();
  process.stdout.write(`READY ${address.port}\n`);
});
