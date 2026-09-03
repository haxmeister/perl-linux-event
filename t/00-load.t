use v5.36;
use Test::More;

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

done_testing;
