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

my $provided = $backend->{provided_buffer_size};
ok($provided > 0, 'provided buffer size exists');

my $len = int($provided / 2);
ok($len > 0, 'fallback length valid');

my $data = 'X' x $len;

syswrite($right, $data) == $len
    or die "short write: $!";

my $result;

$loop->recv(
    fh => $left,
    len => $len,
    on_complete => sub ($op, $res, $ctx) {
        ok(!$op->is_cancelled, 'recv not cancelled');
        is($res->{bytes}, $len, 'bytes match');
        is($res->{data}, $data, 'data matches');
        $result = 1;
    },
);

while ($loop->live_op_count) {
    $loop->run_once;
}

ok($result, 'recv completed');

ok(!exists $backend->{recv_sources}{ fileno($left) },
   'fallback recv did not create multishot source');

done_testing;
