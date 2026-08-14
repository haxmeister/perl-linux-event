package Linux::Event::Stream::Framer::Fixed;
use v5.36;
use strict;
use warnings;

use Carp qw(croak);

sub new ($class, %opt) {
    my $size = delete $opt{size};
    croak 'new(): missing size' if !defined $size;
    croak 'new(): size must be a positive integer'
        if $size !~ /\A\d+\z/ || $size <= 0;
    croak 'unknown options: ' . join(', ', sort keys %opt) if %opt;

    return bless { size => 0 + $size }, $class;
}

sub _native_config ($self) {
    return {
        read_mode  => 3,
        fixed_size => $self->{size},
    };
}

sub frame ($self, $payload) {
    $payload = '' if !defined $payload;
    my $length = length($payload);
    croak "frame(): payload length $length does not equal fixed size $self->{size}"
        if $length != $self->{size};
    return $payload;
}

sub next_frame ($self, $buffer) {
    my $size = $self->{size};
    if ($buffer->length < $size) {
        $buffer->need($size);
        return;
    }
    return (0, $size, $size);
}

1;

__END__

=head1 NAME

Linux::Event::Stream::Framer::Fixed - fixed-size binary message framing

=head1 SYNOPSIS

  use Linux::Event::Stream::Framer;

  my $framer = Linux::Event::Stream::Framer->fixed(size => 32);

=head1 DESCRIPTION

The normal user-facing constructor is provided by L<Linux::Event::Stream::Framer>. This concrete class remains available for subclassing and direct implementation-level use.

Frames a byte stream into messages of exactly C<size> bytes. The exact built-in
class uses the native Stream framing path. Subclasses remain ordinary custom
Perl framers so overridden behavior is never bypassed.

=head1 OPTIONS

=head2 size

Required positive frame size in bytes.

=head1 OUTBOUND FRAMING

C<frame($payload)> accepts only payloads whose length exactly matches C<size>.
C<send($payload)> therefore preserves the fixed-size wire contract.

=cut
