use v5.36;
use Test::More;

use_ok('Linux::Event::TLS');
is(Linux::Event::TLS->VERSION, '0.100_026', 'version');

done_testing;
