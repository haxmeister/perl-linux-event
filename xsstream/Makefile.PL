use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME             => 'Linux::Event::Stream',
    VERSION_FROM     => '../lib/Linux/Event/Stream.pm',
    ABSTRACT         => 'Buffered byte streams for Linux::Event',
    AUTHOR           => 'Joshua S. Day <hax@cpan.org>',
    LICENSE          => 'perl_5',
    MIN_PERL_VERSION => '5.036000',
    PM               => {},
    XS               => { 'XSStream.xs' => 'XSStream.c' },
    OBJECT           => 'XSStream$(OBJ_EXT)',
    clean            => { FILES => 'XSStream.c' },
);
