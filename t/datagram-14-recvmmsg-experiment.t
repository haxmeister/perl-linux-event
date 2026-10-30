use v5.36;
use strict;
use warnings;
use Test::More;
use IO::Socket::INET;
use Linux::Event::_Socket::Dgram;

# This exercises the exact private native return contract shared by recvmsg
# and recvmmsg. Integration tests run with the switch too, in CI.
sub sockets () {
    my $server = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'udp',
    ) or die "UDP receive socket: $!";
    my $client = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1', PeerPort => $server->sockport,
        Proto => 'udp',
    ) or die "UDP send socket: $!";
    return ($server, $client);
}
sub put ($socket, @payloads) {
    for my $packet (@payloads) {
        my $n = $socket->send($packet);
        die "UDP send failed: $!" unless defined($n) && $n == length($packet);
    }
}
sub check ($mode, $server, $expected, $limit, $size, $name) {
    local $ENV{LINUX_EVENT_EXPERIMENT_RECVMMSG} = $mode;
    my $got = Linux::Event::_Socket::Dgram::_recv_batch(
        fileno($server), $size, $limit
    );
    is($got->[0], 0, "$name: no native error");
    is((@$got - 1) / 4, scalar(@$expected), "$name: count");
    for my $i (0 .. $#$expected) {
        my ($payload, $packed_peer, $actual_len, $trunc)
            = @$got[1 + $i * 4 .. 4 + $i * 4];
        is($trunc, 0, "$name: packet $i not truncated");
        is($actual_len, length($expected->[$i]), "$name: packet $i length");
        is($payload, $expected->[$i], "$name: packet $i bytes and order");
        ok(length($packed_peer) >= 16, "$name: packet $i sockaddr");
    }
}
for my $mode (0, 8, 32) {
    subtest "native UDP receive mode $mode" => sub {
        my ($server, $client) = sockets();
        my @payloads = ('', 'a', ('x' x 64), ('y' x 120),
                        ('z' x 300), 'finish', 'seven');
        put($client, @payloads);
        check($mode, $server, [@payloads[0..2]], 3, 1024, 'fairness 3');
        check($mode, $server, [@payloads[3..6]], 0, 1024, 'unbounded drain');
        check($mode, $server, [], 32, 1024, 'nonblocking empty');
        close $client;
        close $server;

        ($server, $client) = sockets();
        put($client, 'A' x 60, 'ok');
        local $ENV{LINUX_EVENT_EXPERIMENT_RECVMMSG} = $mode;
        my $batch = Linux::Event::_Socket::Dgram::_recv_batch(
            fileno($server), 8, 2
        );
        is($batch->[0], 0, 'oversize: no syscall error');
        is((@$batch-1)/4, 2, 'oversize: both datagrams consumed');
        ok(!defined($batch->[1]), 'oversize: first data unavailable');
        is($batch->[3], 60, 'oversize: original length retained');
        ok($batch->[4], 'oversize: truncation marked');
        is($batch->[5], 'ok', 'oversize: following packet intact');
        is($batch->[7], 2, 'oversize: following length intact');
        ok(!$batch->[8], 'oversize: following packet untruncated');
        close $client;
        close $server;
    };
}
done_testing;
