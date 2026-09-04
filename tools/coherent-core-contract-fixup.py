#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text()


def write(path, text):
    (ROOT / path).write_text(text)


# The shared Timer implementation is compiled into Loop.xs. The structural
# pass moves the descriptor package, but Timer's object XSUB package must move
# with it so subclasses inherit _new_native(), reschedule(), now(), and the
# native lifecycle methods from the public Kernel::Timer leaf.
p = ROOT / 'xsloop/Loop.xs'
text = p.read_text()
text = text.replace(
    'PACKAGE = Linux::Event::Timer::_Descriptor',
    'PACKAGE = Linux::Event::Kernel::Timer::_Descriptor',
)
text = text.replace(
    'PACKAGE = Linux::Event::Timer\n',
    'PACKAGE = Linux::Event::Kernel::Timer\n',
)
p.write_text(text)


# Public-surface inventory: require the permanent implementation tree and
# explicitly reject the retired implementation hosts instead of requiring
# compatibility files to remain present.
p = ROOT / 't/20-public-surface.t'
text = p.read_text()
retired_required = [
    "    'lib/Linux/Event/Signal.pm',\n",
    "    'lib/Linux/Event/Wakeup.pm',\n",
    "    'lib/Linux/Event/Listener.pm',\n",
    "    'lib/Linux/Event/Stream.pm',\n",
    "    'lib/Linux/Event/Socket.pm',\n",
    "    'lib/Linux/Event/Socket/_Descriptor.pm',\n",
    "    'lib/Linux/Event/Socket/_Connection.pm',\n",
    "    'lib/Linux/Event/Stream/_Descriptor.pm',\n",
    "    'lib/Linux/Event/Timer.pm',\n",
    "    'lib/Linux/Event/Datagram.pm',\n",
    "    'lib/Linux/Event/Process.pm',\n",
]
for line in retired_required:
    text = text.replace(line, '')
text = text.replace(
    "    'lib/Linux/Event/Kernel/Process.pm',\n",
    "    'lib/Linux/Event/Kernel/Process.pm',\n"
    "    'lib/Linux/Event/_IO.pm',\n"
    "    'lib/Linux/Event/_ByteStream.pm',\n"
    "    'lib/Linux/Event/_ByteStream/Descriptor.pm',\n"
    "    'lib/Linux/Event/_Socket.pm',\n"
    "    'lib/Linux/Event/_Socket/Descriptor.pm',\n"
    "    'lib/Linux/Event/_Socket/Connection.pm',\n"
    "    'lib/Linux/Event/_Socket/Stream.pm',\n"
    "    'lib/Linux/Event/_Socket/Listener.pm',\n"
    "    'lib/Linux/Event/_Socket/Dgram.pm',\n",
    1,
)
text = text.replace("    'xswakeup/Makefile.PL',\n", "    'xsevent/Makefile.PL',\n")
text = text.replace("    'xswakeup/Wakeup.xs',\n", "    'xsevent/Event.xs',\n")
text = text.replace(
    "    'xstls/check_openssl.c',\n",
    "    'xstls/check_openssl.c',\n"
    "    'xsbytestream/Makefile.PL',\n"
    "    'xsbytestream/ByteStream.xs',\n",
    1,
)
removed_anchor = "    'lib/Linux/Event/Stream/_Resolver.pm',\n"
retired_removed = (
    "    'lib/Linux/Event/Stream.pm',\n"
    "    'lib/Linux/Event/Stream',\n"
    "    'lib/Linux/Event/Socket.pm',\n"
    "    'lib/Linux/Event/Socket',\n"
    "    'lib/Linux/Event/Listener.pm',\n"
    "    'lib/Linux/Event/Datagram.pm',\n"
    "    'lib/Linux/Event/Timer.pm',\n"
    "    'lib/Linux/Event/Signal.pm',\n"
    "    'lib/Linux/Event/Wakeup.pm',\n"
    "    'lib/Linux/Event/Process.pm',\n"
    "    'xsstream',\n"
    "    'xswakeup',\n"
)
if "    'lib/Linux/Event/Stream.pm',\n" not in text.split('for my $removed (', 1)[1]:
    text = text.replace(removed_anchor, removed_anchor + retired_removed, 1)
p.write_text(text)


# Private architecture is now permanent, not a migration bridge.
write('t/architecture-00-private-layers.t', r'''use v5.36;
use strict;
use warnings;

use Test::More;

use Linux::Event::_IO ();
use Linux::Event::_ByteStream ();
use Linux::Event::_Socket ();
use Linux::Event::_Socket::Stream ();
use Linux::Event::_Socket::Listener ();
use Linux::Event::_Socket::Dgram ();

ok(Linux::Event::_ByteStream->isa('Linux::Event::_IO'),
    '_ByteStream is an internal IO specialization');
ok(Linux::Event::_Socket->isa('Linux::Event::_IO'),
    '_Socket is an internal IO specialization');
ok(!Linux::Event::_ByteStream->isa('Linux::Event::_Socket'),
    '_ByteStream is not socket-specific');
ok(!Linux::Event::_Socket->isa('Linux::Event::_ByteStream'),
    '_Socket does not imply ordered-byte semantics');

ok(Linux::Event::_Socket::Stream->isa('Linux::Event::_Socket'),
    'stream-socket implementation is socket-specific');
ok(Linux::Event::_Socket::Stream->isa('Linux::Event::_ByteStream'),
    'stream-socket implementation reuses the ordered-byte engine');
ok(Linux::Event::_Socket::Listener->isa('Linux::Event::_Socket'),
    'listener implementation is socket-specific');
ok(!Linux::Event::_Socket::Listener->isa('Linux::Event::_ByteStream'),
    'listener implementation is not an ordered-byte connection');
ok(Linux::Event::_Socket::Dgram->isa('Linux::Event::_Socket'),
    'datagram implementation is socket-specific');
ok(!Linux::Event::_Socket::Dgram->isa('Linux::Event::_ByteStream'),
    'datagram implementation preserves packet rather than byte-stream semantics');

for my $retired (qw(
    Linux::Event::Stream
    Linux::Event::Socket
    Linux::Event::Listener
    Linux::Event::Datagram
)) {
    ok(!$retired->can('new'), "$retired is not retained as an implementation base");
}

done_testing;
''')


# Public leaves should point at the coherent implementation tree. Kernel
# resources own their implementations directly, so no top-level compatibility
# parent is part of the contract.
write('t/architecture-10-public-leaves.t', r'''use v5.36;
use strict;
use warnings;

use Test::More;
use File::Temp qw(tempfile);
use Socket qw(AF_UNIX SOCK_DGRAM SOCK_STREAM);

use Linux::Event::IO ();
use Linux::Event::IO::Pipe ();
use Linux::Event::IO::TTY ();
use Linux::Event::IO::Sock ();
use Linux::Event::IO::Sock::Stream ();
use Linux::Event::IO::Sock::Listener ();
use Linux::Event::IO::Sock::Dgram ();
use Linux::Event::Kernel ();
use Linux::Event::Kernel::Timer ();
use Linux::Event::Kernel::Signal ();
use Linux::Event::Kernel::Event ();
use Linux::Event::Kernel::Process ();

{
    package T::ArchitecturePipe;
    use parent 'Linux::Event::IO::Pipe';
    sub on_data ($self, $bytes) { }
}
{
    package T::ArchitectureTTY;
    use parent 'Linux::Event::IO::TTY';
    sub on_data ($self, $bytes) { }
}
{
    package T::ArchitectureSockStream;
    use parent 'Linux::Event::IO::Sock::Stream';
    sub on_data ($self, $bytes) { }
}
{
    package T::ArchitectureDgram;
    use parent 'Linux::Event::IO::Sock::Dgram';
    sub on_datagram ($self, $bytes, $peer) { }
}
{
    package T::ArchitectureEventMissing;
    use parent 'Linux::Event::Kernel::Event';
}
{
    package T::ArchitectureEvent;
    use parent 'Linux::Event::Kernel::Event';
    sub on_event ($self, $count) { }
}

ok(Linux::Event::IO::Pipe->isa('Linux::Event::_ByteStream'),
    'Pipe leaf uses the ordered-byte implementation');
ok(Linux::Event::IO::TTY->isa('Linux::Event::_ByteStream'),
    'TTY leaf uses the ordered-byte implementation');
ok(Linux::Event::IO::Sock::Stream->isa('Linux::Event::_Socket::Stream'),
    'Sock::Stream uses the connected stream-socket implementation');
ok(Linux::Event::IO::Sock::Listener->isa('Linux::Event::_Socket::Listener'),
    'Sock::Listener uses the listener implementation');
ok(Linux::Event::IO::Sock::Dgram->isa('Linux::Event::_Socket::Dgram'),
    'Sock::Dgram uses the datagram implementation');

pipe(my $pipe_read, my $pipe_write) or die "pipe: $!";
my $pipe = T::ArchitecturePipe->new(read_fh => $pipe_read);
ok($pipe->has_read && !$pipe->has_write, 'Pipe leaf preserves directional IO');
$pipe->close;
close $pipe_write;

my ($regular_fh) = tempfile();
my $pipe_error = eval { T::ArchitecturePipe->new(read_fh => $regular_fh); 1 }
    ? '' : "$@";
like($pipe_error, qr/not a pipe or FIFO/, 'Pipe leaf rejects a non-pipe handle');
close $regular_fh;

pipe(my $not_tty_read, my $not_tty_write) or die "pipe: $!";
my $tty_error = eval { T::ArchitectureTTY->new(read_fh => $not_tty_read); 1 }
    ? '' : "$@";
like($tty_error, qr/not a TTY or PTY/, 'TTY leaf rejects a non-terminal handle');
close $not_tty_read;
close $not_tty_write;

SKIP: {
    open my $ptmx, '+<', '/dev/ptmx'
        or skip '/dev/ptmx is unavailable for TTY validation', 1;
    skip '/dev/ptmx is not reported as a TTY on this system', 1 if !-t $ptmx;
    my $tty = T::ArchitectureTTY->new(fh => $ptmx);
    ok($tty->isa('Linux::Event::IO::TTY'), 'TTY leaf accepts a real pseudo-terminal handle');
    $tty->close;
}

socketpair(my $stream_fh, my $stream_peer, AF_UNIX, SOCK_STREAM, 0)
    or die "stream socketpair: $!";
my $stream = T::ArchitectureSockStream->new(fh => $stream_fh);
ok($stream->isa('Linux::Event::IO::Sock::Stream'),
    'connected SOCK_STREAM constructs through the public leaf');
$stream->close;
close $stream_peer;

socketpair(my $pipe_socket, my $pipe_socket_peer, AF_UNIX, SOCK_STREAM, 0)
    or die "stream socketpair: $!";
$pipe_error = eval { T::ArchitecturePipe->new(fh => $pipe_socket); 1 }
    ? '' : "$@";
like($pipe_error, qr/not a pipe or FIFO/,
    'Pipe leaf rejects a stream socket even though both carry ordered bytes');
close $pipe_socket;
close $pipe_socket_peer;

socketpair(my $dgram_fh, my $dgram_peer, AF_UNIX, SOCK_DGRAM, 0)
    or die "datagram socketpair: $!";
my $dgram = T::ArchitectureDgram->new(fh => $dgram_fh);
ok($dgram->isa('Linux::Event::IO::Sock::Dgram'),
    'SOCK_DGRAM constructs through the public leaf');
$dgram->close;
close $dgram_peer;

my $event_error = eval { T::ArchitectureEventMissing->new; 1 } ? '' : "$@";
like($event_error, qr/must define on_event/, 'Kernel::Event subclasses require on_event');
my $event = T::ArchitectureEvent->new;
ok($event->isa('Linux::Event::Kernel::Event'),
    'eventfd abstraction constructs through Kernel::Event');
$event->cancel;

for my $retired (qw(
    Linux::Event::Timer
    Linux::Event::Signal
    Linux::Event::Wakeup
    Linux::Event::Process
)) {
    ok(!$retired->can('new'), "$retired is not retained as a kernel implementation base");
}

done_testing;
''')


# Native-consumer test hooks are private engine diagnostics. The declaration
# target remains a supported public IO leaf; test-only methods do not leak onto
# that public class.
write('t/architecture-20-native-consumer.t', r'''use v5.36;
use strict;
use warnings;

use Test::More;

use Linux::Event::Loop;
use Linux::Event::IO::Pipe;
use Linux::Event::_ByteStream ();
use Linux::Event::Framer;

{
    package T::ArchitectureNativeConsumer;
    use parent 'Linux::Event::IO::Pipe';
    use Linux::Event::Framer 'Delimiter', "\n";

    Linux::Event::Framer->declare_native_consumer(
        __PACKAGE__,
        Linux::Event::_ByteStream->_test_consumer_definition,
    );
}

is(Linux::Event::_ByteStream->_native_consumer_abi_version, 1,
    'native consumer ABI v1 is owned by the ordered-byte engine');
ok(!Linux::Event::IO::Pipe->can('_test_consumer_definition'),
    'test-only native consumer helpers are not public leaf API');

pipe(my $read_fh, my $write_fh) or die "pipe: $!";
my $loop = Linux::Event::Loop->new;
my $pipe = T::ArchitectureNativeConsumer->new(loop => $loop, read_fh => $read_fh);
ok($pipe->isa('Linux::Event::IO::Pipe'),
    'native consumer attaches to the public IO::Pipe leaf');

$pipe->{xs_state}->_test_consumer_arm(sub { $loop->stop });
is(syswrite($write_fh, "consumer-api\n"), 13,
    'wrote one framed payload to the pipe');
$loop->run;

is($pipe->{xs_state}->_test_consumer_take, 'consumer-api',
    'framed message reaches the native consumer');
ok($pipe->{xs_state}->consumer_paused,
    'pull consumer returns to paused state after receive');

$pipe->close;
close $write_fh;

done_testing;
''')


# The taxonomy test is intentionally about retired names. The broad mechanical
# test conversion must not turn its forbidden-name list into current public
# package names. Restore that list after the structural pass.
p = ROOT / 't/37-current-doc-taxonomy.t'
text = p.read_text()
text = re.sub(
    r"for my \$private \(qw\(\n.*?\n\)\) \{",
    "for my $private (qw(\n"
    "    Linux::Event::Stream\n"
    "    Linux::Event::Socket\n"
    "    Linux::Event::Listener\n"
    "    Linux::Event::Datagram\n"
    "    Linux::Event::Timer\n"
    "    Linux::Event::Signal\n"
    "    Linux::Event::Wakeup\n"
    "    Linux::Event::Process\n"
    ")) {",
    text,
    flags=re.S,
)
p.write_text(text)


# The public datagram leaf is now the subclassing base itself. It is therefore
# rejected for lacking the required callback, not because a retired abstract
# implementation class sits above it.
p = ROOT / 't/datagram-00-api.t'
text = p.read_text()
text = text.replace(
    "like(exception(sub { Linux::Event::IO::Sock::Dgram->new }), qr/abstract base class/,\n    'base Datagram class is abstract');",
    "like(exception(sub { Linux::Event::IO::Sock::Dgram->new }), qr/must define on_datagram/,\n    'public Dgram subclassing base requires on_datagram');",
)
p.write_text(text)

print('coherent core contract fixups applied')
