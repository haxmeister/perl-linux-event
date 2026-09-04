#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# Cross-extension include path after xsstream -> xsbytestream.
p = ROOT / 'xstls/Makefile.PL'
text = p.read_text().replace('-I../xsstream', '-I../xsbytestream')
p.write_text(text)

# Build-artifact exclusions follow renamed native extension directories/files.
p = ROOT / 'MANIFEST.SKIP'
text = p.read_text()
text = text.replace('^xsstream/', '^xsbytestream/')
text = text.replace('Stream\\.(?:c|bs|xsc)', 'ByteStream\\.(?:c|bs|xsc)')
text = text.replace('^xswakeup/', '^xsevent/')
text = text.replace('Wakeup\\.(?:c|o|bs|xsc)', 'Event\\.(?:c|o|bs|xsc)')
p.write_text(text)

print('coherent core refactor fixups applied')
