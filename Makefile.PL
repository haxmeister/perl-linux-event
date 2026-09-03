use strict;
use warnings;
use ExtUtils::MakeMaker;

if ($^O ne 'linux') {
    print "OS unsupported: Linux::Event supports Linux only\n";
    exit 0;
}

my @public_modules = qw(
    Linux::Event
    Linux::Event::Address
    Linux::Event::Datagram
    Linux::Event::Error
    Linux::Event::Framer
    Linux::Event::Framer::DecimalLength
    Linux::Event::Framer::Delimiter
    Linux::Event::Framer::Fixed
    Linux::Event::Framer::LengthPrefix
    Linux::Event::Framer::Netstring
    Linux::Event::Framer::U32BE
    Linux::Event::Framer::Varint
    Linux::Event::IO
    Linux::Event::IO::Pipe
    Linux::Event::IO::TTY
    Linux::Event::IO::Sock
    Linux::Event::IO::Sock::Stream
    Linux::Event::IO::Sock::Listener
    Linux::Event::IO::Sock::Dgram
    Linux::Event::Kernel
    Linux::Event::Kernel::Timer
    Linux::Event::Kernel::Signal
    Linux::Event::Kernel::Event
    Linux::Event::Kernel::Process
    Linux::Event::Listener
    Linux::Event::Loop
    Linux::Event::Process
    Linux::Event::Signal
    Linux::Event::Socket
    Linux::Event::Stream
    Linux::Event::TLS
    Linux::Event::Timer
    Linux::Event::Wakeup
);

my $distribution_version = MM->parse_version('lib/Linux/Event.pm');
my %provides = map {
    my $file = "lib/$_.pm";
    $file =~ s{::}{/}g;
    $_ => {
        file    => $file,
        version => $distribution_version,
    };
} @public_modules;

WriteMakefile(
    NAME             => 'Linux::Event',
    VERSION_FROM     => 'lib/Linux/Event.pm',
    ABSTRACT         => 'Linux-native reactor, I/O, kernel events, and processes',
    AUTHOR           => 'Joshua S. Day <hax@cpan.org>',
    LICENSE          => 'perl_5',
    MIN_PERL_VERSION => '5.036000',
    DIR              => [qw(xsloop xsstream xstls xsconnection xsresolver xssignal xslistener xswakeup xsdatagram xsprocess)],
    CONFIGURE_REQUIRES => {
        'ExtUtils::CBuilder'  => 0,
        'ExtUtils::MakeMaker' => 0,
    },
    TEST_REQUIRES => {
        'Test::More' => 0,
    },
    PREREQ_PM => {
        'Socket' => '2.033',
    },
    META_MERGE       => {
        'meta-spec' => {
            version => 2,
        },
        no_index => {
            package => [qw(
                Linux::Event::_Registration
                Linux::Event::_IO
                Linux::Event::_ByteStream
                Linux::Event::_ByteStream::Descriptor
                Linux::Event::_Socket
                Linux::Event::_Socket::Descriptor
                Linux::Event::_Socket::Stream
                Linux::Event::_Socket::Listener
                Linux::Event::_Socket::Dgram
                Linux::Event::Loop::Introspection
                Linux::Event::_Resolver
                Linux::Event::_Resolver::_Native
                Linux::Event::_SocketConfig
                Linux::Event::Datagram::_ReadyTimer
                Linux::Event::Signal::_Descriptor
                Linux::Event::Signal::_Engine
                Linux::Event::Signal::_Service
                Linux::Event::Socket::_Descriptor
                Linux::Event::Socket::_Connection
                Linux::Event::Stream::_Deadline
                Linux::Event::Stream::_Descriptor
                Linux::Event::Stream::XSDescriptor
                Linux::Event::Stream::XSState
                Linux::Event::Timer::_Descriptor
                Linux::Event::Wakeup::_OwnerState
            )],
        },
        provides => \%provides,
        resources => {
            homepage   => 'https://github.com/haxmeister/perl-linux-event',
            bugtracker => {
                web => 'https://github.com/haxmeister/perl-linux-event/issues',
            },
            repository => {
                type => 'git',
                url  => 'https://github.com/haxmeister/perl-linux-event.git',
                web  => 'https://github.com/haxmeister/perl-linux-event',
            },
        },
    },
);