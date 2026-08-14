use v5.36;
use strict;
use warnings;
use Test::More;

use Linux::Event::Stream::Error;

my $error = Linux::Event::Stream::Error->new(
    type => 'framing',
    operation => 'frame',
    message => 'bad frame',
);
is("$error", 'frame: bad frame', 'Stream::Error string overload accepts Perl overload call convention');

done_testing;
