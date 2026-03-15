use v5.36;
use strict;
use warnings;
use Test::More;

use Linux::Event::Loop;

plan skip_all => 'IO::Uring not available'
    unless eval { require IO::Uring; 1 };

pipe(my $read1, my $write1) or die "pipe1 failed: $!";
pipe(my $read2, my $write2) or die "pipe2 failed: $!";

my $loop = Linux::Event::Loop->new(
    model   => 'proactor',
    backend => 'uring',
);

my $data = "hello splice";
syswrite($write1, $data) == length($data)
    or die "write failed";

my $done;

$loop->splice(
    in_fh  => $read1,
    out_fh => $write2,
    len    => length($data),

    on_complete => sub ($op, $res, $ctx) {
        ok(!$op->is_cancelled, 'splice not cancelled');
        is($res->{bytes}, length($data), 'splice transferred correct bytes');
        $done = 1;
    },
);

while ($loop->live_op_count) {
    $loop->run_once;
}

ok($done, 'splice completed');

my $buf;
sysread($read2, $buf, 1024);

is($buf, $data, 'data transferred correctly');

done_testing;
