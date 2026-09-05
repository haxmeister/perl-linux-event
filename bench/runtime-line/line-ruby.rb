#!/usr/bin/env ruby
# frozen_string_literal: true

require 'async'
require 'socket'

host = ARGV[0] || '127.0.0.1'
port = Integer(ARGV[1] || 0)

server = TCPServer.new(host, port)
server.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1)
server.listen(8192)

STDOUT.sync = true
puts "READY #{server.local_address.ip_port}"

Async do |task|
  loop do
    socket = server.accept
    socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)

    task.async do
      begin
        while (line = socket.gets)
          socket.write(line)
        end
      rescue Errno::EPIPE, Errno::ECONNRESET, IOError
      ensure
        socket.close unless socket.closed?
      end
    end
  end
ensure
  server.close unless server.closed?
end
