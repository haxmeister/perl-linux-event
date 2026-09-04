use v5.36;
use strict;
use warnings;

use Test::More;

use Linux::Event::_IO ();
use Linux::Event::_ByteStream ();
use Linux::Event::_Socket ();
use Linux::Event::_Socket::Stream ();
use Linux::Event::_Socket::Listener ();
use Linux::Event::_Socket::Dgram ();

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

ok(
    Linux::Event::_ByteStream->isa('Linux::Event::Stream'),
    '_ByteStream bridges the proven implementation during migration',
);
ok(
    Linux::Event::_Socket::Stream->isa('Linux::Event::_Socket'),
    'private stream-socket boundary is socket-specific',
);
ok(
    Linux::Event::_Socket::Stream->isa('Linux::Event::Socket'),
    'private stream-socket boundary bridges the proven implementation',
);
ok(
    Linux::Event::_Socket::Listener->isa('Linux::Event::_Socket'),
    'private listener boundary is socket-specific',
);
ok(
    Linux::Event::_Socket::Listener->isa('Linux::Event::Listener'),
    'private listener boundary bridges the proven implementation',
);
ok(
    Linux::Event::_Socket::Dgram->isa('Linux::Event::_Socket'),
    'private datagram boundary is socket-specific',
);
ok(
    Linux::Event::_Socket::Dgram->isa('Linux::Event::Datagram'),
    'private datagram boundary bridges the proven implementation',
);

done_testing;
