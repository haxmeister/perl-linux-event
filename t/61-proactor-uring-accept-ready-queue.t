use v5.36;
use strict;
use warnings;
use Test::More;

use IO::Socket::INET;

use Linux::Event::Loop;

plan skip_all => 'IO::Uring not available'
    unless eval { require IO::Uring; 1 };

my $loop = Linux::Event::Loop->new(
    model   => 'proactor',
    backend => 'uring',
);

my $listen = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1',
    LocalPort => 0,
    Proto     => 'tcp',
    Listen    => 16,
    ReuseAddr => 1,
) or die $!;

my $port = $listen->sockport;

my $accepted1 = 0;
my $accepted2 = 0;

$loop->accept(
    fh => $listen,
    on_complete => sub ($op, $res, $ctx) {
        ok($res->{fh}, 'first accept got connection');
        $accepted1++;
    },
);

my $c1 = IO::Socket::INET->new(
    PeerAddr => '127.0.0.1',
    PeerPort => $port,
    Proto    => 'tcp',
) or die $!;

while ($loop->live_op_count) {
    $loop->run_once;
}

is($accepted1, 1, 'first accept completed');

# Now connect a second client before posting the next public accept waiter.
my $c2 = IO::Socket::INET->new(
    PeerAddr => '127.0.0.1',
    PeerPort => $port,
    Proto    => 'tcp',
) or die $!;

# Give the backend a chance to receive and queue the accepted socket internally.
for (1 .. 20) {
    $loop->run_once;
    last if !$loop->live_op_count;
}

$loop->accept(
    fh => $listen,
    on_complete => sub ($op, $res, $ctx) {
        ok($res->{fh}, 'second accept got queued connection');
        $accepted2++;
    },
);

while ($loop->live_op_count) {
    $loop->run_once;
}

is($accepted2, 1, 'second accept completed from queued ready result');

done_testing;
