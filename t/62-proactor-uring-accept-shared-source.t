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

my $backend = $loop->{impl}->{backend};
ok($backend, 'found uring backend object');

my $listen = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1',
    LocalPort => 0,
    Proto     => 'tcp',
    Listen    => 16,
    ReuseAddr => 1,
) or die $!;

my $fd   = fileno($listen);
my $port = $listen->sockport;

my $accepted = 0;

$loop->accept(
    fh => $listen,
    on_complete => sub ($op, $res, $ctx) {
        ok($res->{fh}, 'first accept completed');
        $accepted++;
    },
);

$loop->accept(
    fh => $listen,
    on_complete => sub ($op, $res, $ctx) {
        ok($res->{fh}, 'second accept completed');
        $accepted++;
    },
);

ok(exists $backend->{accept_sources}{$fd}, 'accept source created for listening fd');

my $src = $backend->{accept_sources}{$fd};
ok($src, 'accept source record available');

is(scalar(@{ $src->{waiters} }), 2, 'two public waiters queued on one source');
ok($src->{armed}, 'shared multishot accept source is armed');
ok(defined $src->{ring_token}, 'shared source has one ring token');

is(scalar(keys %{ $backend->{accept_sources} }), 1, 'only one accept source exists');

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

is($accepted, 2, 'both accepts completed');

is(scalar(@{ $src->{waiters} }), 0, 'no waiters remain after completion');
ok(!$src->{armed}, 'shared multishot source is disarmed when idle');

done_testing;
