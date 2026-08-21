package Linux::Event::Stream::_Resolver;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.100_029';

use Hash::Util::FieldHash qw(fieldhash);
use Scalar::Util qw(weaken);

require XSLoader;
XSLoader::load(__PACKAGE__, $VERSION);

fieldhash my %FOR_LOOP;

sub for_loop ($class, $loop) {
    return $FOR_LOOP{$loop} //= $class->_new($loop);
}

sub _new ($class, $loop) {
    my $self = bless {
        loop     => $loop,
        native   => Linux::Event::Stream::_Resolver::_Native->new(2),
        requests => {},
    }, $class;
    weaken($self->{loop});
    my $ready = sub { $self->_ready };
    $loop->watch(
        fd      => $self->{native}->event_fd,
        read    => $ready,
        no_args => 1,
        lean    => 1,
    );
    return $self;
}

sub submit ($self, $connection, $host, $port) {
    my $id = $self->{native}->submit($host, "$port");
    $self->{requests}{$id} = $connection;
    return $id;
}

sub cancel ($self, $id) {
    return defined($id) ? !!delete($self->{requests}{$id}) : 0;
}

sub _ready ($self) {
    for my $result (@{ $self->{native}->drain }) {
        my $connection = delete $self->{requests}{ $result->{id} };
        next if !$connection;
        $connection->_resolver_completed($result);
    }
    return;
}

sub DESTROY ($self) {
    delete $self->{requests};
    delete $self->{native};
    return;
}

1;
