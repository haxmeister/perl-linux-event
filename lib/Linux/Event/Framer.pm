package Linux::Event::Framer;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.105';

use Carp qw(croak);
use Linux::Event::_ByteStream::Descriptor ();

sub _byte_stream_base ($target) {
    return 'Linux::Event::_ByteStream'
        if $target->isa('Linux::Event::_ByteStream');
    return 'Linux::Event::Stream'
        if $target->isa('Linux::Event::Stream');
    return undef;
}

sub import ($class, $keyword = undef, @args) {
    my $target = caller;
    croak "use $class requires a built-in framer name"
        if !defined($keyword) || $keyword eq '';
    croak "invalid framer name '$keyword'"
        if $keyword !~ /\A[A-Za-z_][A-Za-z0-9_]*\z/;

    my $base = _byte_stream_base($target);
    croak "$target must be a Linux::Event byte-stream subclass before declaring a framer"
        if !defined $base;

    my $package = "${class}::${keyword}";
    (my $file = "$package.pm") =~ s{::}{/}g;
    eval { require $file; 1 } or do {
        my $error = $@ || "unable to load $package";
        $error =~ s/\s+\z//;
        croak "cannot declare framer '$keyword': $error";
    };

    my $builder = $package->can('_build_definition')
        or croak "$package is not a Linux::Event built-in framer";
    my $definition = $builder->($package, @args);
    croak "$package returned an invalid framer definition"
        if ref($definition) ne 'HASH'
        || ref($definition->{native}) ne 'HASH'
        || ref($definition->{frame}) ne 'CODE';

    $definition->{package} = $package;
    Linux::Event::_ByteStream::Descriptor::declare_framer(
        $base, $target, $definition,
    );
    return;
}

sub declare_native_consumer ($class, $target, $definition) {
    croak 'declare_native_consumer(): must be called as a class method'
        if ref $class;
    croak 'declare_native_consumer(): target class is required'
        if !defined($target) || ref($target) || $target eq '';

    my $base = _byte_stream_base($target);
    croak "$target must be a Linux::Event byte-stream subclass before declaring a native consumer"
        if !defined $base;

    Linux::Event::_ByteStream::Descriptor::declare_consumer(
        $base, $target, $definition,
    );
    return;
}

1;

__END__

=head1 NAME

Linux::Event::Framer - native framing and framed-consumer declarations

=head1 SYNOPSIS

  package LineSocket;
  use parent 'Linux::Event::IO::Sock::Stream';
  use Linux::Event::Framer 'Delimiter', "\n";

  sub on_message ($stream, $message) {
      $stream->send($message);
  }

=head1 DESCRIPTION

The import declares one built-in native framing rule for a Linux::Event class
with ordered byte-stream behavior. This includes pipe-like I/O, TTY I/O, and
C<SOCK_STREAM> sockets. The first argument is the exact final component of a
package below C<Linux::Event::Framer>. Linux::Event constructs that package
name, loads it, validates its definition, and incorporates it into the
subclass's cached native descriptor.

There is deliberately no central keyword table and no per-connection framer
object. A byte-stream subclass describes one protocol type; every instance
keeps only its changing parser state.

=head1 DECLARATIONS

  use Linux::Event::Framer 'Delimiter', "\r\n",
      max_frame => 1_048_576;

  use Linux::Event::Framer 'Fixed',
      size => 32;

  use Linux::Event::Framer 'LengthPrefix',
      bytes     => 2,
      endian    => 'big',
      max_frame => 1_048_576;

  use Linux::Event::Framer 'U32BE',
      max_frame => 16 * 1024 * 1024;

  use Linux::Event::Framer 'Netstring',
      max_frame => 1_048_576;

  use Linux::Event::Framer 'Varint',
      max_frame => 1_048_576;

  use Linux::Event::Framer 'DecimalLength',
      separator => ' ',
      max_frame => 1_048_576;

=head1 RAW BYTE STREAMS

A readable subclass that does not import a framer uses raw byte delivery and
must define C<on_data>. A framed subclass normally defines C<on_message>; a
subclass that explicitly enables C<message_batch_size> defines C<on_messages>
instead.

See L<Linux::Event::IO::Pipe>, L<Linux::Event::IO::TTY>,
L<Linux::Event::IO::Sock::Stream>, and F<docs/FRAMING.md>.

=head1 NATIVE CONSUMER EXTENSIONS

External XS integrations that consume complete native-framed messages without
an ordinary Perl C<on_message> callback declare their provider through:

  Linux::Event::Framer->declare_native_consumer(
      'My::FramedConnection',
      {
          provider           => $provider_lifetime_token,
          abi_version        => 1,
          operations_address => $native_table_address,
      },
  );

This is an extension-author interface, not an application callback API. The
target must already inherit an ordered-byte Linux::Event leaf and must use a
built-in native framer. The consumer contract is intentionally independent of
Future, coroutine, or async-subroutine policy.

The native ABI, ownership, pause/resume, reentrancy, transition, and terminal
event rules are documented in F<docs/ORDERED-BYTE-CONSUMER-ABI.md>.

=head1 EXTENDING THE BUILT-IN FAMILY

The declaration loader derives the implementation package from the final name
instead of maintaining a duplicate keyword registry. New native framing
semantics still require corresponding XS parser support; arbitrary Perl
C<next_frame> objects are not accepted. Applications with unusual protocols
should use raw C<on_data> byte processing, while generally useful framing
families can be added to Linux::Event as native built-ins.

=cut
