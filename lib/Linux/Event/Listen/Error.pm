package Linux::Event::Listen::Error;
use v5.36;
use strict;
use warnings;

use overload '""' => 'as_string', fallback => 1;

sub new ($class, %arg) {
    return bless {
        type      => $arg{type} // 'listen',
        operation => $arg{operation},
        errno     => $arg{errno},
        message   => $arg{message} // 'listener failure',
        fatal     => $arg{fatal} ? 1 : 0,
        host      => $arg{host},
        port      => $arg{port},
        path      => $arg{path},
    }, $class;
}

sub type      ($self) { $self->{type} }
sub operation ($self) { $self->{operation} }
sub errno     ($self) { $self->{errno} }
sub message   ($self) { $self->{message} }
sub fatal     ($self) { $self->{fatal} }
sub host      ($self) { $self->{host} }
sub port      ($self) { $self->{port} }
sub path      ($self) { $self->{path} }

sub as_string ($self, @ignored) {
    my $text = $self->{message};
    $text = "$self->{operation}: $text" if defined $self->{operation};
    $text .= " (errno=$self->{errno})" if defined $self->{errno};
    return $text;
}

1;

__END__

=head1 NAME

Linux::Event::Listen::Error - typed listener failure

=head1 DESCRIPTION

Linux::Event::Listen passes this object to C<on_error> for accept-resource and
terminal listener failures. Constructor setup errors throw the same object.

=head1 METHODS

=head2 type / operation / errno / message

Return the structured failure details.

=head2 fatal

True when the listener has entered the terminal C<failed> state.

=head2 host / port / path

Return applicable listener target details.

=head2 as_string

Return the operation-prefixed diagnostic used by string overloading.

=cut
