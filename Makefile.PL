use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME             => 'Linux::Event',
    AUTHOR           => 'Your Name <your@email.com>',
    VERSION_FROM     => 'lib/Linux/Event.pm',
    ABSTRACT         => 'High-performance Linux event framework using io_uring',
    LICENSE          => 'perl_5',
    MIN_PERL_VERSION => '5.010',
    CONFIGURE_REQUIRES => {
        'ExtUtils::MakeMaker' => '0',
    },
    PREREQ_PM => {
        'IO::Uring::Easy'   => '0.001',
        'IO::Uring'         => '0.001',
        'Time::HiRes'       => '0',
        'Scalar::Util'      => '0',
        'Carp'              => '0',
        'Config'            => '0',
        'Fcntl'             => '0',
        'Socket'            => '0',
        'File::Find'        => '0',
    },
    PREREQ_PM_OPTIONAL => {
        'Linux::Inotify2'   => '0',  # For watch() - file/directory monitoring
        'Linux::Fanotify'   => '0',  # For fswatch() - filesystem monitoring
    },
    TEST_REQUIRES => {
        'Test::More' => '0.96',
    },
    META_MERGE => {
        'meta-spec' => { version => 2 },
        resources => {
            repository => {
                type => 'git',
                url  => 'https://github.com/yourusername/Linux-Event.git',
                web  => 'https://github.com/yourusername/Linux-Event',
            },
            bugtracker => {
                web => 'https://github.com/yourusername/Linux-Event/issues',
            },
        },
    },
    dist  => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean => { FILES => 'Linux-Event-*' },
);
