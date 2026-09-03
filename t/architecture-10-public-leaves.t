use v5.36;
use strict;
use warnings;

use Test::More;
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
    package T::ArchitectureEvent;
    use parent 'Linux::Event::Kernel::Event';
    sub on_event ($self, $count) { }
}

ok(
    Linux::Event::IO::Pipe->isa('Linux::Event::Stream'),
    'Pipe leaf currently delegates to proven byte-stream implementation',
);
ok(
    Linux::Event::IO::TTY->isa('Linux::Event::Stream'),
    'TTY leaf currently delegates to proven byte-stream implementation',
);
ok(
    Linux::Event::IO::Sock::Stream->isa('Linux::Event::Socket'),
    'Sock::Stream currently delegates to proven stream-socket implementation',
);
ok(
    Linux::Event::IO::Sock::Listener->isa('Linux::Event::Listener'),
    'Sock::Listener currently delegates to proven listener implementation',
);
ok(
    Linux::Event::IO::Sock::Dgram->isa('Linux::Event::Datagram'),
    'Sock::Dgram currently delegates to proven datagram implementation',
);

pipe(my $pipe_read, my $pipe_write) or die "pipe: $!";
my $pipe = T::ArchitecturePipe->new(read_fh => $pipe_read);
ok($pipe->has_read && !$pipe->has_write, 'Pipe leaf preserves directional IO');
$pipe->close;
close $pipe_write;

socketpair(my $stream_fh, my $stream_peer, AF_UNIX, SOCK_STREAM, 0)
    or die "stream socketpair: $!";
my $stream = T::ArchitectureSockStream->new(fh => $stream_fh);
ok($stream->isa('Linux::Event::IO::Sock::Stream'),
    'connected SOCK_STREAM constructs through new leaf');
$stream->close;
close $stream_peer;

socketpair(my $dgram_fh, my $dgram_peer, AF_UNIX, SOCK_DGRAM, 0)
    or die "datagram socketpair: $!";
my $dgram = T::ArchitectureDgram->new(fh => $dgram_fh);
ok($dgram->isa('Linux::Event::IO::Sock::Dgram'),
    'SOCK_DGRAM constructs through new leaf');
$dgram->close;
close $dgram_peer;

my $event_error = eval { Linux::Event::Kernel::Event->new; 1 } ? '' : "$@";
like($event_error, qr/must define on_event/, 'Kernel::Event requires on_event');
my $event = T::ArchitectureEvent->new;
ok($event->isa('Linux::Event::Kernel::Event'),
    'eventfd abstraction constructs through Kernel::Event');
$event->cancel;

ok(Linux::Event::Kernel::Timer->isa('Linux::Event::Timer'),
    'Kernel::Timer preserves timer implementation');
ok(Linux::Event::Kernel::Signal->isa('Linux::Event::Signal'),
    'Kernel::Signal preserves signal implementation');
ok(Linux::Event::Kernel::Process->isa('Linux::Event::Process'),
    'Kernel::Process preserves process implementation');

done_testing;
