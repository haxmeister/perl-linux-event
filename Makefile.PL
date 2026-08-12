use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME          => 'Linux::Event::XSLoop',
    VERSION_FROM  => 'lib/Linux/Event/XSLoop.pm',
    ABSTRACT      => 'XS-first epoll reactor core for Linux::Event',
    AUTHOR        => 'Joshua S. Day <hax@cpan.org>',
    LICENSE       => 'perl_5',
    MIN_PERL_VERSION => '5.036000',
    XS            => { 'XSLoop.xs' => 'XSLoop.c' },
    PM            => {
        'lib/Linux/Event/XSLoop.pm'    => '$(INST_LIB)/Linux/Event/XSLoop.pm',
        'lib/Linux/Event/XSWatcher.pm' => '$(INST_LIB)/Linux/Event/XSWatcher.pm',
    },
    clean         => { FILES => 'XSLoop.c' },
);
