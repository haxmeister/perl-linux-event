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

syswrite($right, 'Q' x $size) == $size
    or die "short write";

# give uring a chance to deliver CQE before waiter exists
$loop->run_once;

my $done;

$loop->recv(
    fh  => $left,
    len => $size,
    on_complete => sub ($op, $res, $ctx) {
        ok(!$op->is_cancelled, 'recv not cancelled');
        is($res->{bytes}, $size, 'bytes match');
        is($res->{data}, 'Q' x $size, 'data matches');
        $done = 1;
    },
);

while ($loop->live_op_count) {
    $loop->run_once;
}

ok($done, 'recv completed');

my $src = $backend->{recv_sources}{ fileno($left) };
ok($src, 'recv source exists');

is(@{ $src->{ready_results} }, 0, 'ready queue drained');

done_testing;
