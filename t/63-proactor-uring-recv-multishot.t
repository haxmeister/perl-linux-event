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
ok($backend, 'found uring backend');
ok($backend->{provided_buffers}, 'provided buffer group exists');

my $size = $backend->{provided_buffer_size};
ok($size > 0, 'provided buffer size is positive');

my $got1 = undef;
my $got2 = undef;

syswrite($right, 'A' x $size) == $size
or die "short write for first message: $!";

$loop->recv(
    fh => $left,
    len => $size,
    on_complete => sub ($op, $res, $ctx) {
        ok(!$op->is_cancelled, 'first recv not cancelled');
        is($res->{bytes}, $size, 'first recv got expected byte count');
        is(length($res->{data}), $size, 'first recv got expected data length');
        is($res->{data}, 'A' x $size, 'first recv data matches');
        ok(!$res->{eof}, 'first recv not eof');
        $got1 = $res->{data};
    },
);

while ($loop->live_op_count) {
    $loop->run_once;
}

ok(defined $got1, 'first recv completed');

syswrite($right, 'B' x $size) == $size
or die "short write for second message: $!";

$loop->recv(
    fh => $left,
    len => $size,
    on_complete => sub ($op, $res, $ctx) {
        ok(!$op->is_cancelled, 'second recv not cancelled');
        is($res->{bytes}, $size, 'second recv got expected byte count');
        is(length($res->{data}), $size, 'second recv got expected data length');
        is($res->{data}, 'B' x $size, 'second recv data matches');
        ok(!$res->{eof}, 'second recv not eof');
        $got2 = $res->{data};
    },
);

while ($loop->live_op_count) {
    $loop->run_once;
}

ok(defined $got2, 'second recv completed');

ok(exists $backend->{recv_sources}{ fileno($left) }, 'recv source exists for fd');
my $src = $backend->{recv_sources}{ fileno($left) };
ok($src, 'recv source record available');
ok(!$src->{armed}, 'recv source disarmed when idle');

done_testing;
