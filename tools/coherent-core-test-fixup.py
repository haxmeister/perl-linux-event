#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# The broad public test rewrite maps Linux::Event::Datagram onto the public
# Dgram leaf. This private backing-timer probe must continue to target the
# implementation helper after the coherent-core move.
p = ROOT / 't/34-loop-introspection.t'
text = p.read_text().replace(
    'Linux::Event::IO::Sock::Dgram::_ReadyTimer',
    'Linux::Event::_Socket::Dgram::_ReadyTimer',
)
p.write_text(text)

print('coherent core test fixups applied')
