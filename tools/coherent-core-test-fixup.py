#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# Broad public test rewrites must not rewrite references that intentionally
# probe private implementation helpers.
private_replacements = {
    'Linux::Event::IO::Sock::Dgram::_ReadyTimer':
        'Linux::Event::_Socket::Dgram::_ReadyTimer',
    'Linux::Event::IO::Sock::Stream::_Connection':
        'Linux::Event::_Socket::Connection',
    'Linux::Event::IO::Sock::Stream::_deadline_now':
        'Linux::Event::_ByteStream::_deadline_now',
    'Linux::Event::IO::Sock::Stream::_rearm_stream_deadline':
        'Linux::Event::_ByteStream::_rearm_stream_deadline',
}

for base in (ROOT / 't', ROOT / 'bench'):
    for p in base.rglob('*'):
        if not p.is_file() or p.suffix not in {'.t', '.pl', '.pm'}:
            continue
        text = p.read_text()
        for old, new in private_replacements.items():
            text = text.replace(old, new)
        p.write_text(text)

print('coherent core test fixups applied')
