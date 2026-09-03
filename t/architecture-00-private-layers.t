use v5.36;
use strict;
use warnings;

use Test::More;

use Linux::Event::_IO ();
use Linux::Event::_ByteStream ();
use Linux::Event::_Socket ();

ok(
    Linux::Event::_ByteStream->isa('Linux::Event::_IO'),
    '_ByteStream is an internal IO specialization',
);
ok(
    Linux::Event::_Socket->isa('Linux::Event::_IO'),
    '_Socket is an internal IO specialization',
);
ok(
    !Linux::Event::_ByteStream->isa('Linux::Event::_Socket'),
    '_ByteStream does not pretend to be socket-specific',
);
ok(
    !Linux::Event::_Socket->isa('Linux::Event::_ByteStream'),
    '_Socket does not pretend every socket is a byte stream',
);

done_testing;
