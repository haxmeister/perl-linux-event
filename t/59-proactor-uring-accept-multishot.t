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

my $accepted = 0;

$loop->accept(
    fh => $listen,
    on_complete => sub ($op, $res, $ctx) {
        ok($res->{fh}, 'first connection accepted');
        $accepted++;
    },
);

$loop->accept(
    fh => $listen,
    on_complete => sub ($op, $res, $ctx) {
        ok($res->{fh}, 'second connection accepted');
        $accepted++;
    },
);

my $c1 = IO::Socket::INET->new(
    PeerAddr => '127.0.0.1',
    PeerPort => $port,
    Proto    => 'tcp',
) or die $!;

my $c2 = IO::Socket::INET->new(
    PeerAddr => '127.0.0.1',
    PeerPort => $port,
    Proto    => 'tcp',
) or die $!;

while ($loop->live_op_count) {
    $loop->run_once;
}

is($accepted, 2, 'two accept operations completed');

done_testing;
