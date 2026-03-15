use v5.36;
use strict;
use warnings;
use Test::More;

use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use Linux::Event::Loop;

plan skip_all => 'IO::Uring not available'
unless eval { require IO::Uring; 1 };

socketpair(my $left, my $right, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
or die "socketpair failed: $!";

my $loop = Linux::Event::Loop->new(
    model   => 'proactor',
    backend => 'uring',
);

my $backend = $loop->{impl}->{backend};
my $size    = $backend->{provided_buffer_size};

my ($completed, $cancelled) = (0, 0);

my $op1 = $loop->recv(
    fh  => $left,
    len => $size,
    on_complete => sub ($op, $res, $ctx) {
        if ($op->is_cancelled) {
            $cancelled++;
            return;
        }

        $completed++;
    },
);

my $op2 = $loop->recv(
    fh  => $left,
    len => $size,
    on_complete => sub ($op, $res, $ctx) {
        if ($op->is_cancelled) {
            fail('second recv should not cancel');
            return;
        }

        is($res->{bytes}, $size, 'surviving recv got expected byte count');
        is(length($res->{data}), $size, 'surviving recv got expected data length');
        $completed++;
    },
);

ok($op1->cancel, 'cancel requested');

syswrite($right, 'Z' x $size) == $size
or die "short write";

while ($loop->live_op_count) {
    $loop->run_once;
}

is($cancelled, 1, 'one recv cancelled');
is($completed, 1, 'one recv completed');

done_testing;
