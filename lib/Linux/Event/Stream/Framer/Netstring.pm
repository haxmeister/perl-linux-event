package Linux::Event::Stream::Framer::Netstring;
use v5.36;
use strict;
use warnings;

use Carp qw(croak);

sub new ($class, %opt) {
    my $max_frame = delete $opt{max_frame};
    croak 'max_frame must be >= 0'
        if defined($max_frame) && ($max_frame !~ /\A\d+\z/ || $max_frame < 0);
    croak 'unknown options: ' . join(', ', sort keys %opt) if %opt;
    return bless { max_frame => $max_frame }, $class;
}

sub _native_config ($self) {
    return {
        read_mode => 5,
        max_frame => $self->{max_frame},
    };
}

sub frame ($self, $payload) {
    $payload = '' if !defined $payload;
    my $length = length($payload);
    if (defined($self->{max_frame}) && $length > $self->{max_frame}) {
        croak "frame(): payload length $length exceeds max_frame=$self->{max_frame}";
    }
    return $length . ':' . $payload . ',';
}

sub next_frame ($self, $buffer) {
    my $available = $buffer->length;
    return if $available == 0;

    my $colon = $buffer->index(':');
    if ($colon < 0) {
        my $first = $buffer->byte(0);
        die 'invalid netstring length' if $first < 48 || $first > 57;
        die 'netstring length field too long' if $available > 20;
        return;
    }

    die 'invalid netstring length' if $colon == 0;
    die 'netstring length field too long' if $colon > 20;

    my $digits = $buffer->peek(0, $colon);
    die 'invalid netstring length' if $digits !~ /\A\d+\z/;
    die 'invalid netstring leading zero' if length($digits) > 1 && substr($digits, 0, 1) eq '0';

    my $length = 0 + $digits;
    if (defined($self->{max_frame}) && $length > $self->{max_frame}) {
        die "frame exceeds max_frame=$self->{max_frame}";
    }

    my $payload_offset = $colon + 1;
    my $total = $payload_offset + $length + 1;
    if ($available < $total) {
        $buffer->need($total);
        return;
    }

    die 'invalid netstring terminator' if $buffer->byte($total - 1) != ord(',');
    return ($payload_offset, $length, $total);
}

1;

__END__

=head1 NAME

Linux::Event::Stream::Framer::Netstring - netstring framing

=head1 SYNOPSIS

  use Linux::Event::Stream::Framer;

  my $framer = Linux::Event::Stream::Framer->netstring(
      max_frame => 1_048_576,
  );

=head1 DESCRIPTION

The normal user-facing constructor is provided by L<Linux::Event::Stream::Framer>. This concrete class remains available for subclassing and direct implementation-level use.

Implements netstrings in the form C<length:payload,>. The exact built-in class
uses native parsing while retaining the same custom-framer contract in Perl.

=head1 OPTIONS

=head2 max_frame

Optional maximum payload length.

=head1 OUTBOUND FRAMING

C<frame($payload)> returns the canonical decimal-length netstring encoding.

=cut
