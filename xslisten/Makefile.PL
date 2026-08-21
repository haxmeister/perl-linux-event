use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME             => 'Linux::Event::Listener::_Engine',
    VERSION_FROM     => '../lib/Linux/Event/Listener.pm',
    ABSTRACT         => 'Internal native accepting engine for Linux::Event::Listener',
    AUTHOR           => 'Joshua S. Day <hax@cpan.org>',
    LICENSE          => 'perl_5',
    MIN_PERL_VERSION => '5.036000',
    PM               => {},
    XS               => { 'Listen.xs' => 'Listen.c' },
    OBJECT           => 'Listen$(OBJ_EXT)',
    clean            => { FILES => 'Listen.c' },
);
