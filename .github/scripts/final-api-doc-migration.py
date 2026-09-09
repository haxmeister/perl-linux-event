from pathlib import Path


def replace(path, old, new, count=1):
    p = Path(path)
    text = p.read_text()
    if text.count(old) < count:
        raise SystemExit(f"{path}: expected text not found: {old[:100]!r}")
    p.write_text(text.replace(old, new, count))


replace(
    'lib/Linux/Event/IO/Sock/Stream.pm',
    """=item * L<Linux::Event::TLS> identity, verification, ALPN, and role policy;
""",
    """=item * reusable TLS defaults such as ALPN and transport timeouts, without
making TLS part of the Stream class identity;
""",
)

replace(
    'lib/Linux/Event/IO/Sock/Stream.pm',
    """Byte counts are integers. Timeout values are finite non-negative seconds and
may be fractional. Constructor timeout values override class defaults for one
Stream; the other values are class policy.

=head2 socket_options
""",
    """Byte counts are integers. Timeout values are finite non-negative seconds and
may be fractional.

=head2 tune

C<tune> changes the mutable ordered-byte policy of an existing Stream without
reconstructing it:

  $stream->tune(
      read_size         => 131_072,
      read_budget_bytes => 524_288,
      high_watermark    => 2_097_152,
      low_watermark     => 524_288,
      idle_timeout      => 30,
  );

The supported keys are the same eleven values documented by C<stream_tuning>:
C<read_size>, C<read_budget_bytes>, C<read_batch_bytes>,
C<message_batch_size>, C<high_watermark>, C<low_watermark>,
C<max_pending_bytes>, C<max_buffer>, C<idle_timeout>, C<read_timeout>, and
C<write_timeout>.

Effective precedence is class C<stream_tuning()> defaults, then Listener
C<stream =E<gt> { tuning =E<gt> {...} }> deployment overrides for accepted
connections, then C<tune()> on the live object.

Mutable values are copied into native per-Stream state when policy changes.
Ordinary reads and writes do not consult Perl hashes or perform class-versus-
instance resolution. Changing message batching settles work owned by the old
batch policy first. Watermark changes immediately reconcile backpressure.
Lowering C<max_pending_bytes> or C<max_buffer> does not discard bytes already
queued or buffered; later growth must satisfy the new limit. Timeout changes
re-arm or cancel established deadline state as needed.

Framer identity, callback structure, native-consumer identity, and transport
kind are not C<tune()> values. C<tune()> returns the Stream and rejects calls
on a closed Stream.

=head2 socket_options
""",
)

replace(
    'lib/Linux/Event/IO/Sock/Stream.pm',
    """=head1 TLS

A stream-socket subclass opts into TLS declaratively:

  package SecureClient;
  use parent 'Linux::Event::IO::Sock::Stream';
  use Linux::Event::TLS
      verify => 1,
      alpn   => ['http/1.1'];

Outbound C<connect> selects client mode and derives the default server name from
C<host>. A listener that accepts a TLS-declared class selects server mode; that
class must declare C<cert_file> and C<key_file>. Framing and callbacks receive
plaintext. See L<Linux::Event::TLS>.
""",
    """=head1 TLS

TLS is acquisition policy for a Stream socket rather than a separate Stream
class identity. For accepted connections a Listener selects TLS in its generated
Stream recipe:

  my $listener = Linux::Event::IO::Sock::Listener->new(
      loop => $loop,
      host => '0.0.0.0',
      port => 9443,
      stream => {
          class => 'ServerConnection',
          tls => {
              cert_file => $cert_file,
              key_file  => $key_file,
              alpn      => ['my-protocol/1'],
          },
      },
  );

The same C<ServerConnection> class may be used by another Listener without a
C<tls> recipe and is then plain. A subclass may define C<tls_defaults()> for
reusable policy such as ALPN and handshake/shutdown timeouts, but those defaults
do not activate TLS. The Listener prepares one reusable server context and each
accepted TLS Stream receives independent connection state.

Existing class-level L<Linux::Event::TLS> declarations remain available for
explicit outbound client policy and adopted-handle compatibility. Outbound
C<connect> derives the default server name from C<host>. Framing and callbacks
always receive plaintext. See L<Linux::Event::TLS>.
""",
)

replace(
    'lib/Linux/Event/TLS.pm',
    """  sub tls_defaults ($class) {
      return (
          cert_file => '/etc/app/server.crt',
          key_file  => '/etc/app/server.key',
          alpn      => ['echo/1'],
      );
  }
""",
    """  sub tls_defaults ($class) {
      return (
          alpn              => ['echo/1'],
          handshake_timeout => 10,
          shutdown_timeout  => 5,
      );
  }
""",
)

replace(
    'lib/Linux/Event/TLS.pm',
    """Listener C<stream =E<gt> { tls =E<gt> {...} }> values override those defaults.
If neither C<tls_defaults()> nor a Listener TLS recipe is present, the Stream is
plain and allocates no TLS state.
""",
    """Listener C<stream =E<gt> { tls =E<gt> {...} }> values override those defaults.
C<tls_defaults()> does not activate TLS by itself: an accepted connection is TLS
only when its Listener recipe contains a C<tls> key. Certificate and key paths
are normally deployment values in that Listener recipe. A Listener without a
C<tls> recipe generates plain Streams and allocates no TLS state even when the
Stream class defines C<tls_defaults()>.
""",
)

replace(
    'docs/FIRST-CLASS-STREAM-CALLBACKS.md',
    """The public `IO::Sock::Stream` leaf may be used directly for raw I/O when its
required `on_data` callback is supplied to the constructor. A subclass remains
necessary when declaring a framer, native consumer, TLS, `stream_tuning()`, or
`socket_options()` because those are cached class policy.

Framer selection, tuning, transport, and socket behavior remain class-level
policy even when the effective application callback is constructor-supplied.
""",
    """The public `IO::Sock::Stream` leaf may be used directly for raw I/O when its
required `on_data` callback is supplied to the constructor. A subclass remains
the reusable policy mechanism for a framer, native consumer, `stream_tuning()`,
`socket_options()`, named callbacks, and optional TLS defaults. Accepted TLS is
selected independently by the Listener recipe and is not part of Stream class
identity.

Framer selection and socket defaults remain class policy. Listener recipe
tuning can override class `stream_tuning()` for generated connections and a
live Stream can subsequently change mutable ordered-byte policy with `tune()`.
""",
)

replace(
    'docs/FIRST-CLASS-STREAM-CALLBACKS.md',
    """Raw, framed, batched, and native-consumer modes remain explicit. `on_data`
cannot be used on a framed class; `on_message` and `on_messages` cannot be used
on a raw class; `on_messages` requires `message_batch_size`; and Perl message
callbacks cannot replace a native consumer. Invalid combinations fail during
construction rather than during dispatch.
""",
    """Raw, framed, batched, and native-consumer modes remain explicit. `on_data`
cannot be used on a framed class and message callbacks cannot be used on a raw
class. A framed class may provide both `on_message` and `on_messages` so a live
`tune(message_batch_size => ...)` can switch delivery policy without changing
protocol class; the callback required by the initial effective policy must
exist. Perl message callbacks cannot replace a native consumer. Invalid
combinations fail during construction rather than during dispatch.
""",
)

replace(
    'docs/FIRST-CLASS-STREAM-CALLBACKS.md',
    """An `IO::Sock::Listener` accepts the complete connected-Stream callback set as
templates for its accepted Streams:

```perl
my $listener = Linux::Event::IO::Sock::Listener->new(
    loop => $loop,
    stream_class => 'Linux::Event::IO::Sock::Stream',
    host => '127.0.0.1',
    port => 9999,
    on_data => sub ($stream, $bytes) {
        $stream->write($bytes);
    },
);
```

The Listener retains one CV and supplies that same CV to every accepted
Stream. Per-connection identity and mutable state normally belong in the
Stream's `data`. Creating a fresh closure per connection is unnecessary unless
the application truly needs distinct lexical state, and carries measurable
construction cost.

The Listener constructor's callback options configure accepted Streams. The
Listener's own `on_accept` and `on_error` policies remain subclass methods.
""",
    """An `IO::Sock::Listener` accepts the complete connected-Stream callback set in
its generated-Stream recipe:

```perl
my $listener = Linux::Event::IO::Sock::Listener->new(
    loop => $loop,
    host => '127.0.0.1',
    port => 9999,
    stream => {
        on_data => sub ($stream, $bytes) {
            $stream->write($bytes);
        },
    },
);
```

The Listener resolves the recipe once, retains one CV, and supplies that same
CV to every accepted Stream. Per-connection identity and initial mutable state
belong in `stream => { data => ... }`. Creating a fresh closure per connection
is unnecessary unless the application truly needs distinct lexical state, and
carries measurable construction cost.

Top-level `on_accept` and `on_error` belong to the Listener itself. Stream
callbacks such as `on_data` and Stream `on_error` belong inside `stream => {}`.
""",
)
