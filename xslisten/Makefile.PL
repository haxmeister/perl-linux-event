use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME             => 'Linux::Event::Listen',
    VERSION_FROM     => '../lib/Linux/Event/Listen.pm',
    ABSTRACT         => 'Native accepting listeners for Linux::Event',
    AUTHOR           => 'Joshua S. Day <hax@cpan.org>',
    LICENSE          => 'perl_5',
    MIN_PERL_VERSION => '5.036000',
    PM               => {},
    XS               => { 'Listen.xs' => 'Listen.c' },
    OBJECT           => 'Listen$(OBJ_EXT)',
    clean            => { FILES => 'Listen.c' },
);
