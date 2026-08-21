use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME             => 'Linux::Event',
    VERSION_FROM     => 'lib/Linux/Event.pm',
    ABSTRACT         => 'Linux-native event reactor and stream processing foundation',
    AUTHOR           => 'Joshua S. Day <hax@cpan.org>',
    LICENSE          => 'perl_5',
    MIN_PERL_VERSION => '5.036000',
    DIR              => [qw(xsloop xsstream xstls xsconnection xsresolver xssignal xslistener)],
    META_MERGE       => {
        resources => {
            repository => 'https://github.com/haxmeister/perl-linux-event',
        },
    },
);
