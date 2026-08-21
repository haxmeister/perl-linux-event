use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME             => 'Linux::Event::Loop',
    VERSION_FROM     => '../lib/Linux/Event/Loop.pm',
    ABSTRACT         => 'XS-first epoll reactor core for Linux::Event',
    AUTHOR           => 'Joshua S. Day <hax@cpan.org>',
    LICENSE          => 'perl_5',
    MIN_PERL_VERSION => '5.036000',
    PM               => {},
    XS               => { 'XSLoop.xs' => 'XSLoop.c' },
    OBJECT           => 'XSLoop$(OBJ_EXT)',
    TYPEMAPS         => ['typemap'],
    clean            => { FILES => 'XSLoop.c' },
);
