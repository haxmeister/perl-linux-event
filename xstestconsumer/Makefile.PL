use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME             => 'Linux::Event::_ByteStream::ExternalTestConsumer',
    VERSION_FROM     => '../lib/Linux/Event.pm',
    ABSTRACT         => 'Private external native-consumer ABI conformance fixture',
    AUTHOR           => 'Joshua S. Day <hax@cpan.org>',
    LICENSE          => 'perl_5',
    MIN_PERL_VERSION => '5.036000',
    PM               => {},
    XS               => { 'ExternalTestConsumer.xs' => 'ExternalTestConsumer.c' },
    OBJECT           => 'ExternalTestConsumer$(OBJ_EXT)',
    INC              => '-I../xsbytestream',
    depend           => {
        '$(OBJECT)' => '../xsbytestream/stream_consumer_abi.h',
    },
    clean            => { FILES => 'ExternalTestConsumer.c' },
);
