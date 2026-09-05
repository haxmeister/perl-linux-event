use v5.36;
use strict;
use warnings;
use Test::More;
use Scalar::Util qw(weaken);
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

use Linux::Event::Loop;
use Linux::Event::IO::Sock::Stream;

{
    package T::CachedClosure::Line;
    use parent 'Linux::Event::IO::Sock::Stream';
    use Linux::Event::Framer 'Delimiter', "\n";

    sub on_message ($stream, $message) {
        $stream->data->{method_calls}++;
    }
}

{
    package T::CachedClosure::Missing;
    use parent 'Linux::Event::IO::Sock::Stream';
    use Linux::Event::Framer 'Delimiter', "\n";
}

{
    package T::CachedClosure::Other;
    use parent 'Linux::Event::IO::Sock::Stream';
    use Linux::Event::Framer 'Fixed', size => 3;

    sub on_message ($stream, $message) {
        $stream->data->{other_method_calls}++;
    }
}

{
    package T::CachedClosure::Raw;
    use parent 'Linux::Event::IO::Sock::Stream';
    sub on_data ($stream, $bytes) { return }
}

sub socket_pair () {
    socketpair(my $stream_fh, my $peer_fh,
        AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
    return ($stream_fh, $peer_fh);
}

sub construction_error ($class, @option) {
    my ($stream_fh, $peer_fh) = socket_pair();
    my $made = eval { $class->new(fh => $stream_fh, @option); 1 };
    my $error = $@;
    close $stream_fh if defined fileno($stream_fh);
    close $peer_fh;
    return ($made, $error);
}

my ($stream_fh, $peer_fh) = socket_pair();
my $loop = Linux::Event::Loop->new;
my $state = { method_calls => 0, messages => [] };
my $captured = 'lexical value';
my $callback = sub ($stream, $message) {
    push @{ $stream->data->{messages} }, "$captured:$message";
};
my $weak_callback = $callback;
weaken($weak_callback);

my $stream = T::CachedClosure::Line->new(
    loop       => $loop,
    fh         => $stream_fh,
    data       => $state,
    on_message => $callback,
);
undef $callback;
ok(defined($weak_callback), 'native stream state retains supplied closure');
ok(!exists($stream->{_instance_message_cb}),
    'Perl stream hash does not retain a second callback reference');

syswrite($peer_fh, "one\ntwo\n");
$loop->run_once(0.1);
is_deeply($state->{messages}, ['lexical value:one', 'lexical value:two'],
    'cached constructor closure receives native framed messages');
is($state->{method_calls}, 0,
    'cached constructor closure overrides the class method CV');

$stream->transition_to('T::CachedClosure::Other', input => 'abc');
is_deeply($state->{messages},
    ['lexical value:one', 'lexical value:two', 'lexical value:abc'],
    'instance closure remains the message sink across framed transition');
is($state->{other_method_calls} // 0, 0,
    'framed transition does not replace the instance closure');

$stream->close;
undef $stream;
ok(!defined($weak_callback), 'closing stream releases cached closure');
close $peer_fh;

($stream_fh, $peer_fh) = socket_pair();
$loop = Linux::Event::Loop->new;
$state = { messages => [] };
$stream = T::CachedClosure::Missing->new(
    loop       => $loop,
    fh         => $stream_fh,
    data       => $state,
    on_message => sub ($object, $message) {
        push @{ $object->data->{messages} }, $message;
    },
);
syswrite($peer_fh, "supplied\n");
$loop->run_once(0.1);
is_deeply($state->{messages}, ['supplied'],
    'constructor callback supplies the sink for a methodless framed class');
$stream->close;
close $peer_fh;

my ($made, $error) = construction_error(
    'T::CachedClosure::Line', on_message => 'not a callback',
);
ok(!$made, 'constructor rejects a non-coderef on_message');
like($error, qr/on_message must be a coderef/,
    'invalid callback diagnostic identifies on_message');

($made, $error) = construction_error(
    'T::CachedClosure::Raw', on_message => sub { return },
);
ok(!$made, 'raw ordered-byte class rejects on_message override');
like($error, qr/on_message requires a framed ordered-byte class/,
    'raw callback-mode mismatch has a clear diagnostic');

done_testing;
