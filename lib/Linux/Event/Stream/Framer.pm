package Linux::Event::Stream::Framer;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.100_008';

sub delimiter ($class, $delimiter, %opt) {
    require Linux::Event::Stream::Framer::Delimiter;
    return Linux::Event::Stream::Framer::Delimiter->new(
        delimiter => $delimiter,
        %opt,
    );
}

sub line ($class, %opt) {
    return $class->delimiter("\n", %opt);
}

sub fixed ($class, %opt) {
    require Linux::Event::Stream::Framer::Fixed;
    return Linux::Event::Stream::Framer::Fixed->new(%opt);
}

sub length_prefix ($class, %opt) {
    require Linux::Event::Stream::Framer::LengthPrefix;
    return Linux::Event::Stream::Framer::LengthPrefix->new(%opt);
}

sub u32be ($class, %opt) {
    require Linux::Event::Stream::Framer::U32BE;
    return Linux::Event::Stream::Framer::U32BE->new(%opt);
}

sub netstring ($class, %opt) {
    require Linux::Event::Stream::Framer::Netstring;
    return Linux::Event::Stream::Framer::Netstring->new(%opt);
}

sub varint ($class, %opt) {
    require Linux::Event::Stream::Framer::Varint;
    return Linux::Event::Stream::Framer::Varint->new(%opt);
}

1;

__END__

=head1 NAME

Linux::Event::Stream::Framer - factory and guide for Stream message framers

=head1 SYNOPSIS

  use Linux::Event::Stream::Framer;

  my $lines = Linux::Event::Stream::Framer->line;

  my $records = Linux::Event::Stream::Framer->fixed(
      size => 32,
  );

  my $messages = Linux::Event::Stream::Framer->length_prefix(
      bytes  => 4,
      endian => 'big',
  );

=head1 DESCRIPTION

TCP is a byte stream. A read does not necessarily correspond to one application
message. A framer tells Linux::Event::Stream where each message begins and ends.

C<Linux::Event::Stream::Framer> is the normal user-facing factory. The concrete
C<Framer::*> classes remain the implementation types and may still be used
directly when subclassing or inspecting a specific implementation.

Built-in framer objects are configuration objects. They do not hold a
connection's partial-frame or scan state and are safe to reuse across multiple
Streams. Each Stream owns its own native input buffer and parser state.

=head1 FACTORY METHODS

=head2 line

  my $framer = Linux::Event::Stream::Framer->line;

Creates newline-delimited framing using C<"\n">. The newline is stripped from
incoming messages by default and appended by C<send()>.

=head2 delimiter

  my $framer = Linux::Event::Stream::Framer->delimiter("\r\n");

Creates arbitrary binary delimiter framing. Additional options such as
C<include_delimiter> and C<max_frame> are passed to the delimiter implementation.

=head2 fixed

  my $framer = Linux::Event::Stream::Framer->fixed(size => 32);

Creates fixed-size record framing.

=head2 length_prefix

  my $framer = Linux::Event::Stream::Framer->length_prefix(
      bytes  => 2,
      endian => 'big',
  );

Creates unsigned binary length-prefix framing.

=head2 u32be

  my $framer = Linux::Event::Stream::Framer->u32be;

Creates the common four-byte unsigned big-endian length-prefix framing.

=head2 netstring

  my $framer = Linux::Event::Stream::Framer->netstring;

Creates C<length:payload,> netstring framing.

=head2 varint

  my $framer = Linux::Event::Stream::Framer->varint;

Creates unsigned canonical LEB128 variable-length prefix framing.

=head1 REUSING BUILT-IN FRAMERS

A server normally uses one wire format for every connection, so a built-in
framer can be constructed once and shared:

  my $lines = Linux::Event::Stream::Framer->line;

  my $stream_a = Linux::Event::Stream->new(
      loop => $loop,
      fh => $socket_a,
      framer => $lines,
      on_message => sub ($stream, $message) { ... },
  );

  my $stream_b = Linux::Event::Stream->new(
      loop => $loop,
      fh => $socket_b,
      framer => $lines,
      on_message => sub ($stream, $message) { ... },
  );

The shared object contains only framing configuration. Partial bytes, scan
positions, C<need()> thresholds, and other changing parser state remain owned
by each Stream. Stream copies the native configuration into its XS state during
construction, so sharing adds no per-message method call or Perl dispatch.

Custom framers may keep arbitrary Perl state. A custom framer instance is safe
to share only if its own implementation is designed to be share-safe.

=head1 QUICK DECISION GUIDE

=over 4

=item * Every message ends with newline

Use C<< Linux::Event::Stream::Framer->line >>.

=item * Every message ends with another marker such as CRLF, NUL, or a byte string

Use C<< Linux::Event::Stream::Framer->delimiter($bytes) >>.

=item * Every message is exactly the same number of bytes

Use C<< Linux::Event::Stream::Framer->fixed(size =E<gt> $n) >>.

=item * The first 1, 2, or 4 bytes contain the payload length

Use C<< Linux::Event::Stream::Framer->length_prefix(...) >>.

=item * The protocol specifically uses a four-byte unsigned big-endian length

Use C<< Linux::Event::Stream::Framer->u32be >>.

=item * Messages are written as decimal-length, colon, payload, comma

Use C<< Linux::Event::Stream::Framer->netstring >>.

=item * The payload length is an unsigned base-128 varint

Use C<< Linux::Event::Stream::Framer->varint >>.

=item * None of those rules describe the protocol

Implement C<next_frame()> against L<Linux::Event::Stream::Framer::Buffer>. A
custom framer does not need XS knowledge.

=back

=head1 WHY BUILT-INS MATTER

Exact built-in framer classes are recognized by Linux::Event::Stream and their
boundary detection runs in XS against native input storage. Factory-created
built-ins are those same exact classes, so the factory adds no framing hot-path
overhead. Custom framers remain fully supported, but boundary decisions run in
Perl.

=head1 SEE ALSO

See L<Linux::Event::Stream::Framer::Delimiter>,
L<Linux::Event::Stream::Framer::Fixed>,
L<Linux::Event::Stream::Framer::LengthPrefix>,
L<Linux::Event::Stream::Framer::U32BE>,
L<Linux::Event::Stream::Framer::Netstring>,
L<Linux::Event::Stream::Framer::Varint>, and
F<docs/CHOOSING-A-FRAMER.md>.

=cut
