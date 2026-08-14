package Linux::Event::Stream::Framer::DecimalLength;
use v5.36;
use strict;
use warnings;

use Carp qw(croak);
use bytes ();

sub new ($class, %opt) {
    my $separator = delete $opt{separator} // ' ';
    croak 'separator must be exactly one byte' if bytes::length($separator) != 1;
    croak 'separator must not be an ASCII digit' if $separator =~ /[0-9]/;

    my $include_prefix = delete $opt{include_prefix} // 0;
    my $max_frame = delete $opt{max_frame};
    croak 'max_frame must be >= 0'
        if defined($max_frame) && ($max_frame !~ /\A\d+\z/ || $max_frame < 0);
    croak 'unknown options: ' . join(', ', sort keys %opt) if %opt;

    return bless {
        separator      => $separator,
        include_prefix => $include_prefix ? 1 : 0,
        max_frame      => $max_frame,
    }, $class;
}

sub _native_config ($self) {
    return {
        read_mode      => 7,
        delimiter      => $self->{separator},
        include_prefix => $self->{include_prefix},
        max_frame      => $self->{max_frame},
    };
}

sub frame ($self, $payload) {
    $payload = '' if !defined $payload;
    my $length = length($payload);
    if (defined($self->{max_frame}) && $length > $self->{max_frame}) {
        croak "frame(): payload length $length exceeds max_frame=$self->{max_frame}";
    }
    return $length . $self->{separator} . $payload;
}

sub next_frame ($self, $buffer) {
    my $available = $buffer->length;
    return if $available == 0;

    my $separator = ord($self->{separator});
    my $i = 0;
    my $length = 0;
    while ($i < $available && $buffer->byte($i) != $separator) {
        my $byte = $buffer->byte($i);
        die 'invalid decimal length' if $byte < 48 || $byte > 57;
        die 'decimal length field too long' if $i >= 20;
        $length = $length * 10 + ($byte - 48);
        $i++;
    }

    if ($i == $available) {
        die 'decimal length field too long' if $i > 20;
        return;
    }
    die 'invalid decimal length' if $i == 0;
    die 'invalid decimal length leading zero'
        if $i > 1 && $buffer->byte(0) == ord('0');
    if (defined($self->{max_frame}) && $length > $self->{max_frame}) {
        die "frame exceeds max_frame=$self->{max_frame}";
    }

    my $prefix = $i + 1;
    my $total = $prefix + $length;
    if ($available < $total) {
        $buffer->need($total);
        return;
    }

    return $self->{include_prefix}
        ? (0, $total, $total)
        : ($prefix, $length, $total);
}

1;

__END__

=head1 NAME

Linux::Event::Stream::Framer::DecimalLength - ASCII decimal length framing

=head1 SYNOPSIS

  use Linux::Event::Stream::Framer;

  my $framer = Linux::Event::Stream::Framer->decimal_length(
      separator => ' ',
      max_frame => 1_048_576,
  );

=head1 DESCRIPTION

Frames each payload as its canonical ASCII decimal byte length, one separator
byte, and the payload. The default wire form is C<5 HELLO>, which matches RFC
6587 octet-counted syslog framing. Exact built-in objects parse incoming length
fields and frame boundaries in native code.

=head1 OPTIONS

=head2 separator

One non-digit byte between the decimal length and payload. Default is a space.

=head2 include_prefix

When true, incoming messages include the decimal length and separator. Default
false.

=head2 max_frame

Optional maximum payload length.

=head1 OUTBOUND FRAMING

C<frame($payload)> prepends the decimal payload length and separator. Like the
other built-ins, C<send()> performs this small transformation in Perl and hands
the resulting bytes to the native Stream write engine.

=cut
