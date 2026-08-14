use v5.36;
use strict;
use warnings;
use Test::More;

use_ok('Linux::Event::Stream');
use_ok('Linux::Event::Stream::Error');
use_ok('Linux::Event::Stream::Framer');
use_ok('Linux::Event::Stream::Framer::Buffer');
use_ok('Linux::Event::Stream::Framer::Delimiter');
use_ok('Linux::Event::Stream::Framer::Fixed');
use_ok('Linux::Event::Stream::Framer::LengthPrefix');
use_ok('Linux::Event::Stream::Framer::U32BE');
use_ok('Linux::Event::Stream::Framer::Netstring');
use_ok('Linux::Event::Stream::Framer::Varint');
use_ok('Linux::Event::Stream::Framer::DecimalLength');

done_testing;
