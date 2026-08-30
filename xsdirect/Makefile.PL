use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'Linux::Event::DirectAwaitable',
    VERSION_FROM => '../lib/Linux/Event.pm',
    XS           => { 'DirectAwaitable.xs' => 'DirectAwaitable.c' },
    clean        => { FILES => 'DirectAwaitable.c' },
);
