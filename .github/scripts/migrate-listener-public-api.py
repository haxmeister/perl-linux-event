from pathlib import Path


def replace(path, old, new, count=1):
    file = Path(path)
    text = file.read_text()
    if text.count(old) < count:
        raise SystemExit(f"{path}: expected text not found")
    file.write_text(text.replace(old, new, count))


replace(
    "lib/Linux/Event/IO/Sock/Stream.pm",
    """  my $server = Linux::Event::IO::Sock::Listener->new(
      loop         => $loop,
      stream_class => 'Linux::Event::IO::Sock::Stream',
      host         => '127.0.0.1',
      port         => 0,
      on_data      => sub ($stream, $bytes) {
          $stream->write($bytes);
      },
  );
""",
    """  my $server = Linux::Event::IO::Sock::Listener->new(
      loop => $loop,
      host => '127.0.0.1',
      port => 0,
      stream => {
          on_data => sub ($stream, $bytes) {
              $stream->write($bytes);
          },
      },
  );
""",
)

replace(
    "README.md",
    """my $listener = Linux::Event::IO::Sock::Listener->new(
    loop         => $loop,
    stream_class => 'EchoConnection',
    host         => '127.0.0.1',
    port         => 9999,
);
""",
    """my $listener = Linux::Event::IO::Sock::Listener->new(
    loop => $loop,
    host => '127.0.0.1',
    port => 9999,
    stream => {
        class => 'EchoConnection',
    },
);
""",
)

replace(
    "README.md",
    """my $listener = Linux::Event::IO::Sock::Listener->new(
    loop         => $loop,
    stream_class => 'Linux::Event::IO::Sock::Stream',
    host         => '127.0.0.1',
    port         => 9999,
    on_data      => sub ($stream, $bytes) {
        store_bytes($database, $stream, $bytes);
        $stream->write($bytes);
    },
);
""",
    """my $listener = Linux::Event::IO::Sock::Listener->new(
    loop => $loop,
    host => '127.0.0.1',
    port => 9999,
    stream => {
        on_data => sub ($stream, $bytes) {
            store_bytes($database, $stream, $bytes);
            $stream->write($bytes);
        },
    },
);
""",
)

replace(
    "README.md",
    """## TLS

TLS is transport policy on a stream-socket subclass:

```perl
{
    package SecureConnection;
    use parent 'Linux::Event::IO::Sock::Stream';
    use Linux::Event::TLS
        verify => 1,
        alpn   => ['my-protocol/1'];

    sub on_data ($self, $bytes) {
        process_plaintext($bytes);
    }
}
```

Server-side TLS declarations also provide `cert_file` and `key_file`. Accepted
connections automatically use server handshake semantics; outbound `connect()`
uses client handshake semantics. Framing operates on plaintext after the TLS
transport layer.
""",
    """## TLS

TLS is acquisition policy for stream sockets. A server enables it in the
Listener's generated-Stream recipe, so the same connection class can be used by
both plain and TLS listeners:

```perl
my $secure = Linux::Event::IO::Sock::Listener->new(
    loop => $loop,
    host => '0.0.0.0',
    port => 9443,
    stream => {
        class => 'EchoConnection',
        tls => {
            cert_file => $cert_file,
            key_file  => $key_file,
            alpn      => ['my-protocol/1'],
        },
    },
);
```

The Listener validates TLS policy and prepares reusable server context once;
accepted connections allocate only their independent connection state. Plain
Listeners allocate no TLS connection state. A Stream subclass may provide
`tls_defaults()` for reusable policy such as ALPN or timeout defaults, but those
defaults do not activate TLS. Outbound TLS remains selected by client
acquisition policy. Framing operates on plaintext after the TLS transport layer.
""",
)
