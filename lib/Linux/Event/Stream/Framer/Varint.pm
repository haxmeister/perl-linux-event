package Linux::Event::Stream::Framer::Varint;
use v5.36;
use strict;
use warnings;

use Carp qw(croak);
use Config;

sub new ($class, %opt) {
    my $include_prefix = delete $opt{include_prefix} // 0;
    my $max_frame = delete $opt{max_frame};
    croak 'max_frame must be >= 0'
        if defined($max_frame) && ($max_frame !~ /\A\d+\z/ || $max_frame < 0);
    croak 'unknown options: ' . join(', ', sort keys %opt) if %opt;

    return bless {
        include_prefix => $include_prefix ? 1 : 0,
        max_frame      => $max_frame,
    }, $class;
}

sub _native_config ($self) {
    return {
        read_mode      => 6,
        include_prefix => $self->{include_prefix},
        max_frame      => $self->{max_frame},
    };
}

sub _encode ($self, $value) {
    my @bytes;
    do {
        my $byte = $value % 128;
        $value = int($value / 128);
        $byte |= 0x80 if $value;
        push @bytes, $byte;
    } while ($value);
    return pack('C*', @bytes);
}

sub frame ($self, $payload) {
    $payload = '' if !defined $payload;
    my $length = length($payload);
    if (defined($self->{max_frame}) && $length > $self->{max_frame}) {
        croak "frame(): payload length $length exceeds max_frame=$self->{max_frame}";
    }
    return $self->_encode($length) . $payload;
}

sub next_frame ($self, $buffer) {
    my $available = $buffer->length;
    return if $available == 0;

    my $length = 0;
    my $prefix;
    my $uv_bits = 8 * $Config::Config{uvsize};
    for my $i (0 .. 9) {
        return if $i >= $available;
        my $byte = $buffer->byte($i);
        my $low = $byte & 0x7f;

        die 'varint length overflow' if $i == 9 && ($low > 1 || ($byte & 0x80));
        my $shift = 7 * $i;
        if ($low) {
            die 'varint length exceeds native UV'
                if $shift >= $uv_bits || $low >= 2 ** ($uv_bits - $shift);
            $length |= $low << $shift;
        }
        if (!($byte & 0x80)) {
            die 'non-canonical varint length' if $i > 0 && $low == 0;
            $prefix = $i + 1;
            last;
        }
    }
    die 'varint length prefix too long' if !defined $prefix && $available >= 10;
    return if !defined $prefix;

    if (defined($self->{max_frame}) && $length > $self->{max_frame}) {
        die "frame exceeds max_frame=$self->{max_frame}";
    }

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

Linux::Event::Stream::Framer::Varint - unsigned LEB128 length-prefix framing

=head1 SYNOPSIS

  use Linux::Event::Stream::Framer;

  my $framer = Linux::Event::Stream::Framer->varint(
      max_frame => 1_048_576,
  );

=head1 DESCRIPTION

Frames each payload with its length encoded as an unsigned canonical LEB128
integer. Prefixes use one to ten bytes and describe payload bytes only. Exact
built-in objects parse incoming prefixes and frame boundaries in native code.

The encoding is also commonly called an unsigned base-128 varint. It uses the
low seven bits of each byte for the value and the high bit to indicate that
another prefix byte follows. Overlong and non-canonical encodings are rejected.

=head1 OPTIONS

=head2 include_prefix

When true, incoming messages include the encoded prefix. Default false.

=head2 max_frame

Optional maximum payload length.

=head1 OUTBOUND FRAMING

C<frame($payload)> prepends the canonical varint payload length. Like the other
built-ins, C<send()> calls this Perl method before handing the resulting bytes
to the native Stream write engine.

=cut
