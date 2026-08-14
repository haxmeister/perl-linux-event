package Linux::Event::Stream::Error;
use v5.36;
use strict;
use warnings;

use overload '""' => 'as_string', fallback => 1;

sub new ($class, %arg) {
    return bless {
        type      => $arg{type} // 'stream',
        operation => $arg{operation},
        errno     => $arg{errno},
        message   => $arg{message} // 'stream error',
    }, $class;
}

sub type      ($self) { $self->{type} }
sub operation ($self) { $self->{operation} }
sub errno     ($self) { $self->{errno} }
sub message   ($self) { $self->{message} }

sub as_string ($self, @ignored) {
    my $text = $self->{message};
    $text = "$self->{operation}: $text" if defined $self->{operation};
    $text .= " (errno=$self->{errno})" if defined $self->{errno};
    return $text;
}

1;
