use v5.36;
use strict;
use warnings;

use Test::More;
use Scalar::Util qw(weaken);
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

use Linux::Event::Loop;
use Linux::Event::IO::Sock::Stream;
use Linux::Event::Framer ();

{
    package T::RawCachedClosure::A;
    use parent 'Linux::Event::IO::Sock::Stream';
    our $METHOD_CALLS = 0;
    sub stream_options ($class) { return read_size => 4 }
    sub on_data ($stream, $bytes) { $METHOD_CALLS++; return }
}

{
    package T::RawCachedClosure::B;
    use parent 'Linux::Event::IO::Sock::Stream';
    our $METHOD_CALLS = 0;
    sub stream_options ($class) { return read_size => 4 }
    sub on_data ($stream, $bytes) { $METHOD_CALLS++; return }
}

{
    package T::RawCachedClosure::Framed;
    use parent 'Linux::Event::IO::Sock::Stream';
    use Linux::Event::Framer 'Delimiter', "\n";
    sub on_message ($stream, $message) { return }
}

sub socket_pair () {
    socketpair(my $stream_fh, my $peer_fh,
        AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
    return ($stream_fh, $peer_fh);
}

sub pump_until ($loop, $condition) {
    for (1 .. 20) {
        return 1 if $condition->();
        $loop->run_once(100);
    }
    return $condition->() ? 1 : 0;
}

my ($stream_fh, $peer_fh) = socket_pair();
my $loop = Linux::Event::Loop->new;
my $state = { bytes => '', captures => [] };
my $captured = 'lexical value';
my $callback = sub ($stream, $bytes) {
    $stream->data->{bytes} .= $bytes;
    push @{ $stream->data->{captures} }, $captured;
    return;
};
my $weak_callback = $callback;
weaken($weak_callback);

my $stream = T::RawCachedClosure::A->new(
    loop => $loop,
    fh => $stream_fh,
    data => $state,
    on_data => $callback,
);
undef $callback;
ok(defined($weak_callback), 'native raw state retains constructor callback');
ok(!exists($stream->{_instance_data_cb}),
    'established raw Stream does not retain constructor callback in Perl hash');

is(syswrite($peer_fh, 'abcdefgh'), 8, 'peer writes raw bytes');
ok(pump_until($loop, sub { length($state->{bytes}) == 8 }),
    'constructor raw callback receives all bytes');
is($state->{bytes}, 'abcdefgh', 'raw callback receives the original byte stream');
ok(@{ $state->{captures} } > 0, 'raw callback ran at least once');
is_deeply(
    [ do { my %seen; grep { !$seen{$_}++ } @{ $state->{captures} } } ],
    ['lexical value'],
    'raw native dispatch retains lexical state',
);
is($T::RawCachedClosure::A::METHOD_CALLS, 0,
    'constructor callback overrides the class on_data CV');

$stream->transition_to('T::RawCachedClosure::B', input => 'ijkl');
is($state->{bytes}, 'abcdefghijkl',
    'raw transition keeps the instance callback for preserved input');
is($T::RawCachedClosure::B::METHOD_CALLS, 0,
    'transition does not replace instance callback with target class method');

$stream->close;
undef $stream;
ok(!defined($weak_callback), 'raw native teardown releases constructor callback');
close $peer_fh;

my ($plain_fh, $plain_peer) = socket_pair();
my $plain_state = { bytes => '' };
my $plain = T::RawCachedClosure::A->new(
    fh => $plain_fh,
    data => $plain_state,
    on_data => sub ($stream, $bytes) {
        $stream->data->{bytes} .= $bytes;
        return;
    },
);
my $plain_loop = Linux::Event::Loop->new;
$plain_loop->add($plain);
is(syswrite($plain_peer, 'wxyz'), 4,
    'unattached constructor callback test writes bytes');
ok(pump_until($plain_loop, sub { length($plain_state->{bytes}) == 4 }),
    'constructor callback works when object is attached later');
is($plain_state->{bytes}, 'wxyz', 'later attachment uses native instance callback');
$plain->close;
close $plain_peer;

my ($bad_fh, $bad_peer) = socket_pair();
my $made = eval {
    T::RawCachedClosure::A->new(fh => $bad_fh, on_data => 'not a callback');
    1;
};
my $error = $@;
ok(!$made, 'raw ordered-byte socket rejects non-coderef on_data override');
like($error, qr/on_data must be a coderef/,
    'invalid raw callback has a clear diagnostic');
close $bad_fh if defined fileno($bad_fh);
close $bad_peer;

my ($framed_fh, $framed_peer) = socket_pair();
$made = eval {
    T::RawCachedClosure::Framed->new(
        fh => $framed_fh,
        on_data => sub { return },
    );
    1;
};
$error = $@;
ok(!$made, 'framed ordered-byte socket rejects on_data override');
like($error, qr/on_data requires a raw ordered-byte class/,
    'raw callback-mode mismatch has a clear diagnostic');
close $framed_fh if defined fileno($framed_fh);
close $framed_peer;

done_testing;
