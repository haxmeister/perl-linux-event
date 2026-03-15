use v5.36;
use strict;
use warnings;
use Test::More;

use Linux::Event::Loop;

subtest 'splice zero-byte success still settles correctly' => sub {

    my $loop = Linux::Event::Loop->new(
        model   => 'proactor',
        backend => 'fake',
    );

    my $called = 0;
    my $bytes;

    my $op = $loop->splice(
        in_fh       => 'IN',
        out_fh      => 'OUT',
        len         => 100,
        on_complete => sub ($op, $res, $ctx) {
            $called++;
            $bytes = $res->{bytes};
        },
    );

    my $token   = $op->_backend_token;
    my $backend = $loop->{impl}->{backend};

    $backend->_fake_complete_splice_success($token, 0);

    is($called, 0, 'callback deferred');

    $loop->run_once;

    is($called, 1, 'callback fired');
    is($bytes, 0, 'zero-byte splice preserved');
};

done_testing;
