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

my $accepted  = 0;
my $cancelled = 0;

my $op1 = $loop->accept(
    fh => $listen,
    on_complete => sub ($op, $res, $ctx) {
        if ($op->is_cancelled) {
            fail('surviving accept should not cancel');
            return;
        }

        ok($res->{fh}, 'surviving accept got connection');
        $accepted++;
    },
);

my $op2 = $loop->accept(
    fh => $listen,
    on_complete => sub ($op, $res, $ctx) {
        if ($op->is_cancelled) {
            pass('second accept cancelled');
            $cancelled++;
            return;
        }

        fail('cancelled accept should not complete');
    },
);

ok($op2->cancel, 'second accept cancel requested');

my $client = IO::Socket::INET->new(
    PeerAddr => '127.0.0.1',
    PeerPort => $port,
    Proto    => 'tcp',
) or die $!;

while ($loop->live_op_count) {
    $loop->run_once;
}

is($accepted,  1, 'one accept completed');
is($cancelled, 1, 'one accept cancelled');

done_testing;
