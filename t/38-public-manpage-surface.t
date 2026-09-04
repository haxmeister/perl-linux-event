use v5.36;
use strict;
use warnings;

use Test::More;
use FindBin qw($Bin);
use File::Spec;

my $root = File::Spec->catdir($Bin, '..');
my $makefile_pl = File::Spec->catfile($root, 'Makefile.PL');
open my $fh, '<', $makefile_pl or die "open $makefile_pl: $!";
local $/;
my $src = <$fh>;
close $fh;

like($src, qr/my \%man3pods = map \{.*?\} \@public_modules;/s,
    'manpage mapping is derived from the public module source of truth');
like($src, qr/MAN3PODS\s*=>\s*\\%man3pods/,
    'MakeMaker receives the public-only MAN3PODS mapping');

for my $private (qw(
    Linux::Event::Stream
    Linux::Event::Socket
    Linux::Event::Listener
    Linux::Event::Datagram
    Linux::Event::Timer
    Linux::Event::Signal
    Linux::Event::Wakeup
    Linux::Event::Process
)) {
    unlike($src, qr/^\s*\Q$private\E\s*$/m,
        "$private is not listed as a public module/manpage");
}

done_testing;
