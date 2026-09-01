use v5.36;
use strict;
use warnings;
use Test::More;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

use Linux::Event::Loop;
use Linux::Event::Stream;
use Linux::Event::Socket;

{
    package T::API::Raw;
    use parent 'Linux::Event::Socket';
    sub on_data ($stream, $bytes) { }
}

{
    package T::API::Missing;
    use parent 'Linux::Event::Socket';
}

{
    package T::API::FramedMissing;
    use parent 'Linux::Event::Socket';
    use Linux::Event::Framer 'Delimiter', "\n";
}

{
    package T::API::FramedMixed;
    use parent 'Linux::Event::Socket';
    use Linux::Event::Framer 'Delimiter', "\n";
    sub on_data ($stream, $bytes) { }
    sub on_message ($stream, $message) { }
}

{
    package T::API::GenericSocketOptions;
    use parent 'Linux::Event::Stream';
    sub socket_options ($class) { return keepalive => 1 }
    sub on_data ($stream, $bytes) { }
}

{
    package T::API::GenericSocketHook;
    use parent 'Linux::Event::Stream';
    sub configure_socket ($stream, $fh, $role, $peer) { }
    sub on_data ($stream, $bytes) { }
}

my $loop = Linux::Event::Loop->new;
socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
    or die "socketpair: $!";
my $stream = T::API::Raw->new(
    loop => $loop, fh => $a, data => { name => 'x' },
);

is($stream->data->{name}, 'x', 'optional user data retrieved explicitly');
$stream->data({ name => 'y' });
is($stream->data->{name}, 'y', 'user data can be replaced');
my $wide_error = eval { $stream->write("\x{100}"); '' } // $@;
like($wide_error, qr/scalar byte string/,
    'write rejects character data that was not encoded to bytes');
$stream->end;
ok($stream->is_write_ended, 'end with empty queue half-closes immediately');

my $ok = eval { $stream->write('late'); 1 };
ok(!$ok, 'write after end is rejected');
like($@, qr/writable side has ended/, 'write-after-end error is clear');
$stream->close;
close $b;

sub construction_error ($class, @extra) {
    socketpair(my $left, my $right, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
        or die "socketpair: $!";
    my $made = eval { $class->new(loop => $loop, fh => $left, @extra); 1 };
    my $error = $@;
    close $left if defined fileno($left);
    close $right;
    return ($made, $error);
}

my ($made, $error) = construction_error('Linux::Event::Stream');
ok(!$made, 'base Stream class cannot be constructed');
like($error, qr/base class/, 'base-class error is clear');

($made, $error) = construction_error('Linux::Event::Socket');
ok(!$made, 'base Socket class cannot be constructed');
like($error, qr/base class/, 'Socket base-class error is clear');

($made, $error) = construction_error('T::API::Missing');
ok(!$made, 'raw subclass requires on_data');
like($error, qr/requires on_data/, 'missing raw callback error is clear');

($made, $error) = construction_error('T::API::FramedMissing');
ok(!$made, 'framed subclass must define on_message');
like($error, qr/requires on_message/, 'missing framed callback error is clear');

($made, $error) = construction_error('T::API::FramedMixed');
ok(!$made, 'framed subclass cannot also define on_data');
like($error, qr/cannot define on_data/, 'mixed-mode error is clear');

($made, $error) = construction_error(
    'T::API::Raw', on_data => sub { }, read_size => 1,
);
ok(!$made, 'old per-object callback and transport options are rejected');
like($error, qr/unknown options: on_data, read_size/,
    'constructor identifies removed object-configured options');

for my $case (
    ['T::API::GenericSocketOptions', qr/defines socket_options.*Linux::Event::Socket/],
    ['T::API::GenericSocketHook', qr/defines configure_socket.*Linux::Event::Socket/],
) {
    pipe(my $read, my $write) or die "pipe: $!";
    my $made = eval { $case->[0]->new(read_fh => $read); 1 };
    ok(!$made, "$case->[0] rejects misplaced socket policy");
    like($@, $case->[1], 'generic Stream migration mistake fails loudly');
    close $read;
    close $write;
}

done_testing;
