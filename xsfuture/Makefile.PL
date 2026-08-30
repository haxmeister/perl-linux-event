use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME             => 'Linux::Event::Future',
    VERSION_FROM     => '../lib/Linux/Event/Future.pm',
    ABSTRACT         => 'Native awaitable state for Linux::Event',
    AUTHOR           => 'Joshua S. Day <hax@cpan.org>',
    LICENSE          => 'perl_5',
    MIN_PERL_VERSION => '5.036000',
    PM               => {},
    XS               => { 'Future.xs' => 'Future.c' },
    OBJECT           => 'Future$(OBJ_EXT)',
    depend           => { '$(OBJECT)' => 'future_native.h' },
    clean            => { FILES => 'Future.c' },
);
