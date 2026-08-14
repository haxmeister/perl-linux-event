package Linux::Event::Stream::Framer::Buffer;
use v5.36;
use strict;
use warnings;

use Carp qw(croak);

# Stable framing view.  It can sit over either the old Perl reference scalar or
# the native XS input buffer.  Custom framers deliberately cannot tell which
# storage engine is in use, so later buffer-layout changes do not break them.
sub _new ($class, $bufref) {
    return bless {
        bufref => $bufref,
        state  => undef,
        need   => 0,
    }, $class;
}

sub _new_xs ($class, $state) {
    return bless {
        bufref => undef,
        state  => $state,
        need   => 0,
    }, $class;
}

sub length ($self) {
    return $self->{state}->_input_length if $self->{state};
    return CORE::length(${ $self->{bufref} });
}

sub index ($self, $needle, $start = 0) {
    croak 'index(): needle must be defined' if !defined $needle;
    croak 'index(): start must be >= 0' if $start < 0;
    return $self->{state}->_input_index($needle, $start) if $self->{state};
    return CORE::index(${ $self->{bufref} }, $needle, $start);
}

sub byte ($self, $offset) {
    croak 'byte(): offset must be >= 0' if $offset < 0;
    return $self->{state}->_input_byte($offset) if $self->{state};
    return undef if $offset >= $self->length;
    return ord(substr(${ $self->{bufref} }, $offset, 1));
}

sub peek ($self, $offset, $length) {
    croak 'peek(): offset must be >= 0' if $offset < 0;
    croak 'peek(): length must be >= 0' if $length < 0;
    croak 'peek(): range exceeds available buffer'
        if $offset + $length > $self->length;
    return $self->{state}->_input_peek($offset, $length) if $self->{state};
    return substr(${ $self->{bufref} }, $offset, $length);
}

sub need ($self, $minimum_total_bytes) {
    croak 'need(): byte count must be >= 0' if $minimum_total_bytes < 0;
    if ($self->{state}) {
        $self->{state}->_input_need($minimum_total_bytes);
    } else {
        $self->{need} = $minimum_total_bytes;
    }
    return;
}

sub _needed ($self) {
    return $self->{state}->_input_needed if $self->{state};
    return $self->{need} // 0;
}

sub _clear_need ($self) {
    if ($self->{state}) {
        $self->{state}->_input_clear_need;
    } else {
        $self->{need} = 0;
    }
    return;
}

# Internal Stream operation.  Public framers return boundaries; only Stream
# extracts and consumes bytes.  Keeping this operation on the view avoids ever
# exposing native storage ownership to plug-ins.
sub _extract_consume ($self, $offset, $length, $consume) {
    if ($self->{state}) {
        return $self->{state}->_input_extract_consume($offset, $length, $consume);
    }

    my $message = substr(${ $self->{bufref} }, $offset, $length);
    substr(${ $self->{bufref} }, 0, $consume, '');
    return $message;
}

1;

__END__

=head1 NAME

Linux::Event::Stream::Framer::Buffer - stable read-only view for custom framers

=head1 DESCRIPTION

Custom Perl framers inspect Stream input through this object instead of
receiving the Stream's actual storage. The normal implementation now uses a
native XS buffer, while the development reference backend uses a Perl scalar.
The public view is identical for both.

=head1 METHODS

=head2 length

Returns currently buffered bytes.

=head2 index($needle, $start = 0)

Finds an arbitrary byte sequence without requiring the framer to copy the
whole buffer into Perl.

=head2 byte($offset)

Returns the integer value of one byte, or undef when the offset is beyond the
current buffer.

=head2 peek($offset, $length)

Returns a copy of only the requested byte range. Use this for headers that
require inspection, such as a binary length prefix.

=head2 need($minimum_total_bytes)

Records a scheduling hint. Stream avoids another custom-Perl-framer callback
until at least that many total bytes are buffered.

=cut
