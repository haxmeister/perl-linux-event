use v5.36;
use strict;
use warnings;
use Test::More;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

use Linux::Event;
use Linux::Event::Loop;
use Linux::Event::Stream;

{
    package T::FutureDelimitedStream;
    use parent 'Linux::Event::Stream';
    use Linux::Event::Framer 'Delimiter', '<END>';
}

{
    package T::CallbackDelimitedStream;
    use parent 'Linux::Event::Stream';
    use Linux::Event::Framer 'Delimiter', '<END>';
    sub on_message ($stream, $message) { return }
}

async sub receive_one ($stream) {
    return await $stream->recv;
}

socketpair(my $left, my $right, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
    or die "socketpair: $!";
my $loop = Linux::Event::Loop->new;
my $stream = T::FutureDelimitedStream->new(
    loop => $loop,
    fh   => $left,
);

my $first = receive_one($stream);
isa_ok($first, 'Linux::Event::Future',
    'async receiver returns native Future');
ok(!$first->is_ready, 'recv waits for a complete frame');

syswrite($right, 'hello<EN');
$loop->run_once(0);
ok(!$first->is_ready, 'partial native frame does not complete recv');

syswrite($right, 'D>world<END>');
is($loop->run($first), 'hello',
    'Loop drives async receiver to first decoded message');

my $second = $stream->recv;
ok($second->is_ready, 'second decoded message remains in native queue');
is($loop->run($second), 'world', 'queued message keeps wire order');

my $cancelled = $stream->recv;
$cancelled->cancel;
my $after_cancel = $stream->recv;
ok(!$after_cancel->is_ready,
    'cancelled recv releases the single-receiver slot');
syswrite($right, 'after-cancel<END>');
is($loop->run($after_cancel), 'after-cancel',
    'message after cancellation reaches the next receiver');

my $eof = $stream->recv;
close $right;
is($loop->run($eof), undef, 'clean EOF resolves recv with undef');
$stream->close;

socketpair(my $close_left, my $close_right,
    AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
my $closing = T::FutureDelimitedStream->new(
    loop => $loop,
    fh   => $close_left,
);
my $pending = $closing->recv;
$closing->close;
my $closed = eval { $pending->get; 1 };
ok(!$closed, 'explicit close fails a pending recv');
isa_ok($@, 'Linux::Event::Error');
is($@->type, 'closed', 'explicit close reports typed recv failure');
close $close_right;

socketpair(my $callback_left, my $callback_right,
    AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
my $callback_stream = T::CallbackDelimitedStream->new(
    loop => $loop,
    fh   => $callback_left,
);
my $mixed = eval { $callback_stream->recv; 1 };
ok(!$mixed, 'recv and callback delivery cannot consume the same Stream');
like($@, qr/cannot be combined/, 'mixed delivery error is explicit');
$callback_stream->close;
close $callback_right;

done_testing;
