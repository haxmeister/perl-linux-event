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
        pending_bytes => $arg{pending_bytes},
        limit         => $arg{limit},
    }, $class;
}

sub type      ($self) { $self->{type} }
sub operation ($self) { $self->{operation} }
sub errno     ($self) { $self->{errno} }
sub message   ($self) { $self->{message} }
sub pending_bytes ($self) { $self->{pending_bytes} }
sub limit         ($self) { $self->{limit} }

sub as_string ($self, @ignored) {
    my $text = $self->{message};
    $text = "$self->{operation}: $text" if defined $self->{operation};
    $text .= " (errno=$self->{errno})" if defined $self->{errno};
    return $text;
}

1;

__END__

=head1 NAME

Linux::Event::Stream::Error - typed Stream failure details

=head1 DESCRIPTION

Stream passes this object to C<on_error>. C<type>, C<operation>, C<errno>, and
C<message> describe ordinary I/O, framing, and provider failures. A TLS
provider uses C<type> C<tls> and identifies handshake/read/write/shutdown in
C<operation>. An C<output_limit>
failure also provides C<pending_bytes> and C<limit>, which report the attempted
pending-output count and the class's configured C<max_pending_bytes> bound.

=head1 METHODS

=head2 type / operation / errno / message

Return the common error fields. Fields that do not apply are undefined.

=head2 pending_bytes / limit

Return hard output-limit details. Both are undefined for other error types.

=head2 as_string

Return the operation-prefixed diagnostic used by string overloading.

=cut
