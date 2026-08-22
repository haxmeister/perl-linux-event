use v5.36;
use Test::More;

use_ok('Linux::Event::TLS');
is(Linux::Event::TLS->VERSION, '0.101', 'version');

done_testing;
