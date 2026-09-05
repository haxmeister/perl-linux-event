#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;

{
    package EchoClient;
    use parent 'Linux::Event::IO::Sock::Stream';
    use Linux::Event::Framer 'Delimiter', "\n";
}

use Linux::Event::Loop;

my $loop = Linux::Event::Loop->new;
my $message = $ARGV[1] // 'hello';
my $client = $loop->add(EchoClient->connect(
    host => '127.0.0.1',
    port => $ARGV[0] // 9999,
    on_ready => sub ($stream) {
        $stream->send($message);
    },
    on_message => sub ($stream, $line) {
        say $line;
        $stream->close;
        $loop->stop;
    },
    on_error => sub ($stream, $error) {
        warn "$error\n";
        $loop->stop;
    },
));
$loop->run;
