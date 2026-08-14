package Linux::Event::Stream::Framer::LengthPrefix;
use v5.36;
use strict;
use warnings;

use Carp qw(croak);

sub new ($class, %opt) {
    my $bytes = delete $opt{bytes} // 4;
    croak 'bytes must be 1, 2, or 4' if $bytes != 1 && $bytes != 2 && $bytes != 4;

    my $endian = delete $opt{endian} // 'big';
    croak 'endian must be big or little' if $endian ne 'big' && $endian ne 'little';

    my $include_prefix = delete $opt{include_prefix} // 0;
    my $max_frame = delete $opt{max_frame};
    croak 'max_frame must be >= 0'
        if defined($max_frame) && ($max_frame !~ /\A\d+\z/ || $max_frame < 0);
    croak 'unknown options: ' . join(', ', sort keys %opt) if %opt;

    return bless {
        bytes          => 0 + $bytes,
        endian         => $endian,
        include_prefix => $include_prefix ? 1 : 0,
        max_frame      => $max_frame,
    }, $class;
}

sub _native_config ($self) {
    return {
        read_mode      => 4,
        prefix_bytes   => $self->{bytes},
        prefix_little  => $self->{endian} eq 'little' ? 1 : 0,
        include_prefix => $self->{include_prefix},
        max_frame      => $self->{max_frame},
    };
}

sub _max_value ($self) {
    return 0xff       if $self->{bytes} == 1;
    return 0xffff     if $self->{bytes} == 2;
    return 0xffffffff if $self->{bytes} == 4;
    die 'internal invalid prefix width';
}

sub _decode ($self, $prefix) {
    my @b = unpack('C*', $prefix);
    @b = reverse @b if $self->{endian} eq 'little';
    my $value = 0;
    $value = ($value << 8) | $_ for @b;
    return $value;
}

sub _encode ($self, $value) {
    my @b;
    my $n = $value;
    for (1 .. $self->{bytes}) {
        unshift @b, $n & 0xff;
        $n >>= 8;
    }
    @b = reverse @b if $self->{endian} eq 'little';
    return pack('C*', @b);
}

sub frame ($self, $payload) {
    $payload = '' if !defined $payload;
    my $length = length($payload);
    my $max = $self->_max_value;
    croak "frame(): payload length $length exceeds prefix capacity $max"
        if $length > $max;
    if (defined($self->{max_frame}) && $length > $self->{max_frame}) {
        croak "frame(): payload length $length exceeds max_frame=$self->{max_frame}";
    }
    return $self->_encode($length) . $payload;
}

sub next_frame ($self, $buffer) {
    my $prefix_bytes = $self->{bytes};
    if ($buffer->length < $prefix_bytes) {
        $buffer->need($prefix_bytes);
        return;
    }

    my $length = $self->_decode($buffer->peek(0, $prefix_bytes));
    if (defined($self->{max_frame}) && $length > $self->{max_frame}) {
        die "frame exceeds max_frame=$self->{max_frame}";
    }

    my $total = $prefix_bytes + $length;
    if ($buffer->length < $total) {
        $buffer->need($total);
        return;
    }

    return $self->{include_prefix}
        ? (0, $total, $total)
        : ($prefix_bytes, $length, $total);
}

1;

__END__

=head1 NAME

Linux::Event::Stream::Framer::LengthPrefix - unsigned binary length-prefix framing

=head1 SYNOPSIS

  use Linux::Event::Stream::Framer;

  my $framer = Linux::Event::Stream::Framer->length_prefix(
      bytes  => 4,
      endian => 'big',
  );

=head1 DESCRIPTION

The normal user-facing constructor is provided by L<Linux::Event::Stream::Framer>. This concrete class remains available for subclassing and direct implementation-level use.

Frames payloads using an unsigned 1-, 2-, or 4-byte binary length prefix. The
length describes payload bytes only. Exact built-in objects use native parsing.

=head1 OPTIONS

=head2 bytes

Prefix width: 1, 2, or 4 bytes. Default 4.

=head2 endian

C<big> or C<little>. Default C<big>.

=head2 include_prefix

When true, incoming messages include the prefix bytes. Default false.

=head2 max_frame

Optional maximum payload length.

=head1 OUTBOUND FRAMING

C<frame($payload)> prepends the configured unsigned payload length. It rejects
payloads too large for the configured width or C<max_frame>.

=cut
