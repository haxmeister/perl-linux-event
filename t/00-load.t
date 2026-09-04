use v5.36;
use Test::More;
use FindBin qw($Bin);
use File::Spec;

use_ok('Linux::Event');
use_ok('Linux::Event::Loop');

use_ok('Linux::Event::IO');
use_ok('Linux::Event::IO::Pipe');
use_ok('Linux::Event::IO::TTY');
use_ok('Linux::Event::IO::Sock');
use_ok('Linux::Event::IO::Sock::Stream');
use_ok('Linux::Event::IO::Sock::Listener');
use_ok('Linux::Event::IO::Sock::Dgram');

use_ok('Linux::Event::Kernel');
use_ok('Linux::Event::Kernel::Timer');
use_ok('Linux::Event::Kernel::Signal');
use_ok('Linux::Event::Kernel::Event');
use_ok('Linux::Event::Kernel::Process');

use_ok('Linux::Event::TLS');
use_ok('Linux::Event::Framer');
use_ok('Linux::Event::Error');
use_ok('Linux::Event::Address');

my $loop = Linux::Event::Loop->new;
ok($loop, 'created loop');

my $root = File::Spec->catdir($Bin, '..');
my $makefile_pl = File::Spec->catfile($root, 'Makefile.PL');
open my $makefile_fh, '<', $makefile_pl or die "open $makefile_pl: $!";
local $/;
my $makefile_src = <$makefile_fh>;
close $makefile_fh;

my ($public_module_block) = $makefile_src =~
    /my \@public_modules = qw\(\s*(.*?)\s*\);/s;
ok(defined $public_module_block,
    'Makefile.PL declares the public module source of truth');

my $distribution_version = Linux::Event->VERSION;
my @public_modules = grep { length }
    split /\s+/, ($public_module_block // '');
for my $module (@public_modules) {
    (my $file = "$module.pm") =~ s{::}{/}g;
    require $file;
    is($module->VERSION, $distribution_version,
        "$module version matches Linux::Event $distribution_version");
}

done_testing;
