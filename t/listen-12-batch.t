use v5.36;
use strict;
use warnings;
use Test::More;
use Socket qw(AF_INET SOCK_STREAM inet_aton pack_sockaddr_in);

use Linux::Event::XSLoop;

{
    package T::BatchListener;
    use parent 'Linux::Event::Listen';
    sub on_accept ($self, $fh, $peer) {
        push @{ $self->data->{accepted} }, $fh;
        $self->loop->stop
            if @{ $self->data->{accepted} } == $self->data->{target};
    }
    sub on_error ($self, $error) {
        $self->data->{error} = $error;
        $self->loop->stop;
    }
}

my $loop = Linux::Event::XSLoop->new;
my $state = { accepted => [], target => 7 };
my $listener = T::BatchListener->new(
    loop => $loop, host => '127.0.0.1', port => 0, data => $state,
    max_accept_per_tick => 2,
);
my @clients;
for (1 .. $state->{target}) {
    socket(my $client, AF_INET, SOCK_STREAM, 0) or die "socket: $!";
    connect($client,
        pack_sockaddr_in($listener->port, inet_aton('127.0.0.1')))
        or die "connect: $!";
    push @clients, $client;
}
$loop->run;

ok(!$state->{error}, 'bounded accept batches complete without errors');
is(scalar(@{ $state->{accepted} }), $state->{target},
    'level-triggered watcher revisits backlog after each bounded batch');
is($listener->accepted, $state->{target},
    'accepted counter spans multiple native batches');

close $_ for @{ $state->{accepted} }, @clients;
$listener->close;
done_testing;
