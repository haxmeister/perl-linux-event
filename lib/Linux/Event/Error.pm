package Linux::Event::Error;
use v5.36;
use strict;
use warnings;

use Carp qw(croak);

sub new ($class, %arg) {
    croak 'code is required' unless exists $arg{code};

    my $self = bless {
        code    => $arg{code},
        name    => defined $arg{name}    ? $arg{name}    : 'EUNKNOWN',
        message => defined $arg{message} ? $arg{message} : '',
    }, $class;

    return $self;
}

sub code    ($self) { return $self->{code} }
sub name    ($self) { return $self->{name} }
sub message ($self) { return $self->{message} }

1;

__END__

=pod

=head1 NAME

Linux::Event::Error - Lightweight error object for Linux::Event::Proactor

=head1 SYNOPSIS

  my $err = $op->error;
  warn $err->code;
  warn $err->name;
  warn $err->message;

=head1 DESCRIPTION

Linux::Event::Error is a compact object used to report operation failures from
L<Linux::Event::Proactor>. It stores an errno-style numeric code, a short
symbolic name, and a human-readable message.

=head1 METHODS

=head2 new

  my $err = Linux::Event::Error->new(
    code    => $code,
    name    => $name,
    message => $message,
  );

C<code> is required. C<name> defaults to C<EUNKNOWN>. C<message> defaults to
the empty string.

=head2 code

Returns the numeric error code.

=head2 name

Returns the symbolic error name.

=head2 message

Returns the descriptive message.

=head1 SEE ALSO

L<Linux::Event::Operation>, L<Linux::Event::Proactor>

=cut
