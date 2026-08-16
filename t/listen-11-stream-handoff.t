use v5.36;
use strict;
use warnings;
use Test::More;
use Socket qw(AF_INET SOCK_STREAM inet_aton pack_sockaddr_in);

use Linux::Event::XSLoop;

{
    package T::LineEchoStream;
    use parent 'Linux::Event::Stream';
    use Linux::Event::Stream::Framer 'Delimiter', "\n";
    sub on_message ($self, $message) {
        $self->send($message);
        $self->data->{messages}++;
        $self->loop->stop;
    }
}

{
    package T::LineEchoListener;
    use parent 'Linux::Event::Listen';
    sub on_accept ($self, $fh, $peer) {
        push @{ $self->data->{streams} }, T::LineEchoStream->new(
            loop => $self->loop, fh => $fh, data => $self->data,
        );
    }
    sub on_error ($self, $error) {
        $self->data->{error} = $error;
        $self->loop->stop;
    }
}

my $loop = Linux::Event::XSLoop->new;
my $state = { streams => [], messages => 0 };
my $listener = T::LineEchoListener->new(
    loop => $loop, host => '127.0.0.1', port => 0, data => $state,
);
socket(my $client, AF_INET, SOCK_STREAM, 0) or die "socket: $!";
connect($client, pack_sockaddr_in($listener->port, inet_aton('127.0.0.1')))
    or die "connect: $!";
is(syswrite($client, "hello\n"), 6, 'client sends one framed line');
$loop->run;
$loop->run_once(0);

ok(!$state->{error}, 'listener-to-Stream handoff succeeds');
is($state->{messages}, 1, 'Stream parses one line');
is(sysread($client, my $echo, 6), 6, 'client receives complete echo');
is($echo, "hello\n", 'send reapplies the declared line delimiter');

$_->close for @{ $state->{streams} };
$listener->close;
close $client;
done_testing;
