package Linux::Event::Stream::Framer::Delimiter;
use v5.36;
use strict;
use warnings;

use Carp qw(croak);

sub new ($class, %opt) {
    my $delimiter = delete $opt{delimiter};
    croak 'new(): missing delimiter' if !defined $delimiter;
    croak 'new(): delimiter must not be empty' if $delimiter eq '';

    my $include_delimiter = delete $opt{include_delimiter} // 0;
    my $max_frame         = delete $opt{max_frame};
    croak 'max_frame must be >= 0'
        if defined($max_frame) && $max_frame < 0;
    croak 'unknown options: ' . join(', ', sort keys %opt) if %opt;

    return bless {
        delimiter         => $delimiter,
        delimiter_length  => length($delimiter),
        include_delimiter => $include_delimiter ? 1 : 0,
        max_frame         => $max_frame,
    }, $class;
}

# Framer contract:
#   no return values                => need more bytes
#   (offset, length, consume_bytes) => one complete frame
#   die                             => framing error
#
# The Stream consumes exactly consume_bytes from the front of its input
# buffer. Only [offset, offset + length) is copied into the Perl message.
# Private native configuration used by Linux::Event::Stream.  This is not the
# plug-in contract; third-party framers continue to implement next_frame().
sub _native_config ($self) {
    return {
        read_mode         => 2,
        delimiter         => $self->{delimiter},
        include_delimiter => $self->{include_delimiter},
        max_frame         => $self->{max_frame},
    };
}

sub frame ($self, $payload) {
    $payload = '' if !defined $payload;
    return $payload . $self->{delimiter};
}

sub next_frame ($self, $buffer) {
    my $pos = $buffer->index($self->{delimiter});

    if ($pos < 0) {
        my $max = $self->{max_frame};
        if (defined($max) && $buffer->length > $max + $self->{delimiter_length} - 1) {
            die "frame exceeds max_frame=$max without delimiter";
        }
        return;
    }

    my $max = $self->{max_frame};
    die "frame exceeds max_frame=$max"
        if defined($max) && $pos > $max;

    my $consume = $pos + $self->{delimiter_length};
    my $length = $self->{include_delimiter} ? $consume : $pos;
    return (0, $length, $consume);
}

1;

__END__

=head1 NAME

Linux::Event::Stream::Framer::Delimiter - arbitrary byte-sequence framing

=head1 SYNOPSIS

  use Linux::Event::Stream::Framer;

  my $framer = Linux::Event::Stream::Framer->delimiter(
      "\x02END\x03",
  );

=head1 DESCRIPTION

The normal user-facing constructor is provided by L<Linux::Event::Stream::Framer>. This concrete class remains available for subclassing and direct implementation-level use.

Frames a byte stream using an arbitrary non-empty binary delimiter. Delimiters
may span socket reads and multiple frames may arrive in one read.

=head1 OPTIONS

=head2 delimiter

Required byte sequence. It is not treated as text and may contain NUL or other
binary bytes.

=head2 include_delimiter

When true, incoming messages include the delimiter. Default false.

=head2 max_frame

Optional maximum payload bytes before the delimiter. Exceeding the limit is a
framing error.

=head1 OUTBOUND FRAMING

C<frame($payload)> appends the configured delimiter. Therefore a framed Stream
can use C<$stream-E<gt>send($payload)> for the normal outbound case.

=cut
