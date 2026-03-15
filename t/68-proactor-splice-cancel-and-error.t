use v5.36;
use strict;
use warnings;
use Test::More;

use Linux::Event::Loop;
use Linux::Event::Error;

subtest 'fake backend splice success' => sub {
    my $loop = Linux::Event::Loop->new(
        model   => 'proactor',
        backend => 'fake',
    );

    my $called = 0;
    my $seen;

    my $op = $loop->splice(
        in_fh       => 'IN',
        out_fh      => 'OUT',
        len         => 123,
        on_complete => sub ($op, $res, $ctx) {
            $called++;
            $seen = [$op, $res, $ctx];
        },
        data => 'ctx',
    );

    ok($op, 'got splice operation');

    my $token = $op->_backend_token;
    ok(defined $token, 'splice token assigned');

    my $backend = $loop->{impl}->{backend};
    ok($backend->can('_fake_complete_splice_success'),
       'fake backend exposes splice completion helper');

    $backend->_fake_complete_splice_success($token, 123);

    is($called, 0, 'callback still deferred');

    $loop->run_once;

    is($called, 1, 'callback ran once');
    ok($seen->[0]->is_done, 'operation marked done');
    ok(!$seen->[0]->is_cancelled, 'operation not cancelled');
    ok(!$seen->[0]->failed, 'operation not failed');
    is($seen->[1]{bytes}, 123, 'splice byte count returned');
    is($seen->[2], 'ctx', 'callback data passed through');
};

subtest 'fake backend splice cancel' => sub {
    my $loop = Linux::Event::Loop->new(
        model   => 'proactor',
        backend => 'fake',
    );

    my $called    = 0;
    my $cancelled = 0;

    my $op = $loop->splice(
        in_fh       => 'IN',
        out_fh      => 'OUT',
        len         => 50,
        on_complete => sub ($op, $res, $ctx) {
            $called++;
            $cancelled++ if $op->is_cancelled;
        },
    );

    ok($op->cancel, 'cancel requested');
    is($called, 0, 'cancel callback still deferred');

    $loop->run_once;

    is($called, 1, 'cancel callback ran once');
    is($cancelled, 1, 'operation reported cancelled');
    ok($op->is_terminal, 'operation is terminal');
};

subtest 'fake backend splice error' => sub {
    my $loop = Linux::Event::Loop->new(
        model   => 'proactor',
        backend => 'fake',
    );

    my $called = 0;
    my $failed;
    my $err;

    my $op = $loop->splice(
        in_fh       => 'IN',
        out_fh      => 'OUT',
        len         => 99,
        on_complete => sub ($op, $res, $ctx) {
            $called++;
            $failed = $op->failed;
            $err    = $op->error;
        },
    );

    my $token   = $op->_backend_token;
    my $backend = $loop->{impl}->{backend};

    ok($backend->can('_fake_complete_splice_error'),
       'fake backend exposes splice error helper');

    $backend->_fake_complete_splice_error(
        $token,
        code    => 32,
        name    => 'EPIPE',
        message => 'Broken pipe',
    );

    is($called, 0, 'error callback still deferred');

    $loop->run_once;

    is($called, 1, 'error callback ran once');
    ok($failed, 'operation failed');
    isa_ok($err, 'Linux::Event::Error');
    is($err->code, 32, 'error code preserved');
    is($err->name, 'EPIPE', 'error name preserved');
};

done_testing;
