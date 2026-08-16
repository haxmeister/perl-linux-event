package Linux::Event::Connect::Error;
use v5.36;
use strict;
use warnings;

use overload '""' => 'as_string', fallback => 1;

sub new ($class, %arg) {
    return bless {
        type             => $arg{type} // 'connect',
        operation        => $arg{operation},
        errno            => $arg{errno},
        message          => $arg{message} // 'connection failed',
        host             => $arg{host},
        port             => $arg{port},
        path             => $arg{path},
        family           => $arg{family},
        attempts         => $arg{attempts} // 0,
        resolver_message => $arg{resolver_message},
    }, $class;
}

sub type             ($self) { $self->{type} }
sub operation        ($self) { $self->{operation} }
sub errno            ($self) { $self->{errno} }
sub message          ($self) { $self->{message} }
sub host             ($self) { $self->{host} }
sub port             ($self) { $self->{port} }
sub path             ($self) { $self->{path} }
sub family           ($self) { $self->{family} }
sub attempts         ($self) { $self->{attempts} }
sub resolver_message ($self) { $self->{resolver_message} }

sub as_string ($self, @ignored) {
    my $text = $self->{message};
    $text = "$self->{operation}: $text" if defined $self->{operation};
    $text .= " (errno=$self->{errno})" if defined $self->{errno};
    return $text;
}

1;

__END__

=head1 NAME

Linux::Event::Connect::Error - typed outbound connection failure

=head1 DESCRIPTION

Linux::Event::Connect passes this object to C<on_error>. Common fields identify
the failure category and operation. Address fields retain the request target,
and C<attempts> reports how many sockets were created before terminal failure.

=head1 METHODS

=head2 type / operation / errno / message

Return the common error fields. C<type> is currently C<resolve>, C<socket>,
C<connect>, or C<timeout>.

=head2 host / port / path / family

Return the applicable request address details.

=head2 attempts

Return the number of socket candidates attempted.

=head2 resolver_message

Return the original resolver diagnostic for a C<resolve> failure.

=head2 as_string

Return the operation-prefixed diagnostic used by string overloading.

=cut
