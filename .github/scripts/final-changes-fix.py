from pathlib import Path

p = Path('Changes')
text = p.read_text()
text = text.replace(
    'accepted_stream_tuning hook from the public design.',
    'accepted_stream_options hook from the public design.',
    1,
)
text = text.replace(
    '    - Add cached class-level stream_tuning for read size, watermarks, and\n'
    '      framed-buffer limits.\n',
    '    - Add cached class-level stream_options for read size, watermarks, and\n'
    '      framed-buffer limits.\n',
    1,
)
marker = 'Revision history for Linux-Event\n\n'
entry = '''Unreleased
    - Replace Listener stream_class and flat accepted-Stream constructor
      templates with one resolved stream => {...} recipe. Listener bind/listen/
      accept policy remains top-level while class, data, tuning, TLS, and Stream
      callbacks belong to the generated-connection recipe.
    - Rename the ordered-byte class tuning hook from stream_options() to
      stream_tuning(), add live $stream->tune(...), and keep effective mutable
      values in native per-Stream state with no new steady-state Perl lookup.
    - Define deterministic live tuning transitions for batching, watermarks,
      hard output/input limits, and established idle/read/write deadlines.
    - Make accepted TLS acquisition-time policy selected by stream->{tls} rather
      than Stream class identity. Listener construction validates deployment
      policy and prepares one reusable server SSL_CTX; accepted connections
      allocate independent SSL state from that prepared context.
    - Add regression coverage for recipe validation and precedence, live tuning,
      plain/TLS reuse of one Stream class, prepared TLS context cloning, and
      lowered max_pending_bytes/max_buffer grandfathering behavior.
    - Add a dedicated accepted-TLS setup benchmark alongside the existing
      steady-state encrypted-I/O microbenchmark, and update public POD, examples,
      README, and architecture documents to the new API.

'''
if not text.startswith(marker):
    raise SystemExit('Changes header not found')
if '\nUnreleased\n' not in text and not text.startswith(marker + 'Unreleased\n'):
    text = text.replace(marker, marker + entry, 1)
p.write_text(text)
