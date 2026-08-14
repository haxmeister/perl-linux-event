use v5.36;
use strict;
use warnings;
use Test::More;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);

use Linux::Event::XSLoop;
use Linux::Event::Stream;

socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
    or die "socketpair: $!";

my $loop = Linux::Event::XSLoop->new;
my $got = '';
my $stream = Linux::Event::Stream->new(
    loop => $loop,
    fh   => $a,
    _read_backend  => 'perl',
    _write_backend => 'perl',
    on_data => sub ($s, $bytes) {
        $got .= $bytes;
        $loop->stop;
    },
);

is($stream->{read_backend}, 'perl', 'private benchmark reference path selected');
ok(!defined($stream->{xs_state}), 'reference path has no XS native state');

syswrite($b, 'reference');
$loop->run;
is($got, 'reference', 'Perl reference read path remains executable');

$stream->close;
close $b;

done_testing;
