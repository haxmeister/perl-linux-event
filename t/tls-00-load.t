use v5.36;
use Test::More;

use_ok('Linux::Event::TLS');
is(Linux::Event::TLS->VERSION, '0.100_029', 'version');

done_testing;
