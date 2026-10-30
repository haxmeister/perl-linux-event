#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;
use Getopt::Long qw(GetOptions);
use IO::Socket::INET;
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC CLOCK_PROCESS_CPUTIME_ID);
use JSON::PP ();
use IO::Handle;
use File::Path qw(make_path);
use File::Basename qw(dirname);
use Linux::Event::Loop;
use Linux::Event::IO::Sock::Dgram;

# Public Loop+Datagram on_datagram() burst test, with genuine localhost UDP.
# All native recvmsg/recvmmsg results pass the ordinary application callbacks.
# Receive-only CPU includes epoll, native batch creation, Perl callback and
# the public run_once() wrapper, but excludes client-side send syscalls.
my $rounds=800;
my $repeats=3;
my $sizes='64,512,1400,8192';
my $bursts='8,32';
my $modes='0,8,32';
my $max_sizes='payload,default';
my $output='bench/results/udp-recvmmsg-loop-ci.jsonl';
my $help=0;
GetOptions(
    'rounds=i'=>\$rounds, 'repeats=i'=>\$repeats,
    'sizes=s'=>\$sizes, 'bursts=s'=>\$bursts,
    'modes=s'=>\$modes, 'max-sizes=s'=>\$max_sizes,
    'output=s'=>\$output, 'help'=>\$help,
) or die "Invalid options\n";
if ($help) {
    print <<'HELP';
Linux::Event Loop UDP recvmmsg application-level queued-burst comparison
  perl -Mblib bench/experiments/udp-recvmmsg-loop.pl

Options: --rounds 800 --repeats 3 --sizes 64,512,1400,8192
         --bursts 8,32 --modes 0,8,32 --max-sizes payload,default
         --output bench/results/udp-recvmmsg-loop-ci.jsonl

For every burst: send all packets first, then run the public Loop to deliver
individual on_datagram callbacks. Mode 0 is recvmsg, modes 8 and 32 are
experimental recvmmsg. Payload size and default max_datagram_size are compared
because default 65535-byte buffers limit batch slots under the memory cap.
Every packet must arrive in order with the expected payload and peer.
HELP
    exit 0;
}
die "Linux required\n" unless $^O eq 'linux';
die "Invalid rounds\n" unless $rounds>=1 && $rounds<=50_000;
die "Invalid repeats\n" unless $repeats>=1 && $repeats<=10;
sub nums ($arg,$min,$max) {
    my @v=split /,/, $arg;
    die "Invalid parameter '$arg'\n" unless @v &&
        !grep { !/^\d+$/ || $_<$min || $_>$max } @v;
    return @v;
}
my @sizes=nums($sizes,4,8192);
my @bursts=nums($bursts,2,64);
my @modes=nums($modes,0,32);
my @max_sizes=split /,/,$max_sizes;
die "Invalid --max-sizes\n" unless @max_sizes &&
    !grep {$_ ne 'payload' && $_ ne 'default'} @max_sizes;
sub now () { clock_gettime(CLOCK_MONOTONIC) }
sub cpu () { clock_gettime(CLOCK_PROCESS_CPUTIME_ID) }
sub median ($v) {
    my @s=sort {$a <=> $b} @$v;
    return @s%2 ? $s[int(@s/2)] : ($s[@s/2-1]+$s[@s/2])/2;
}
sub exercise ($bytes,$burst,$mode,$rounds,$max_setting) {
    local $ENV{LINUX_EVENT_EXPERIMENT_RECVMMSG}="$mode";
    my $loop=Linux::Event::Loop->new;
    my $received=0;
    my $expected=0;
    my $bad=0;
    my $send_port;
    my $server=Linux::Event::IO::Sock::Dgram->new(
        loop=>$loop,
        host=>'127.0.0.1',port=>0,
        # Both settings are important: application payload-sized buffers
        # and Linux::Event's ordinary default 65535 maximum.
        ($max_setting eq 'payload'
            ? (max_datagram_size=>$bytes) : ()),
        max_datagrams_per_tick=>256,
        receive_buffer=>1_048_576,
        on_datagram=>sub ($sock,$data,$peer) {
            my $seq=unpack('N',substr($data,0,4));
            $bad++ if length($data)!=$bytes
                || $seq!=$expected
                || $peer->family ne 'inet'
                || $peer->port<=0;
            $expected++;
            $received++;
        },
        on_error=>sub ($sock,$error) {die "UDP datagram callback: $error\n"},
    );
    $send_port=$server->local->port;
    my $tx=IO::Socket::INET->new(
        PeerAddr=>'127.0.0.1',PeerPort=>$send_port,Proto=>'udp'
    ) or die "UDP TX: $!";
    my $head='x' x ($bytes-4);
    my $receive_cpu=0;
    my $receive_wall=0;
    my $poll_count=0;
    my $begin=now();
    my $whole_cpu_start=cpu();
    for my $round (0..$rounds-1) {
        my $before=$received;
        my $data_base=$round*$burst;
        for my $index (0..$burst-1) {
            my $payload=pack('N',$data_base+$index).$head;
            my $sent=$tx->send($payload);
            die "UDP send error $!\n" if !defined($sent)||$sent!=$bytes;
        }
        my $poll_start=now();
        my $cpu_at=cpu();
        for (1..10) {
            last if $received==$before+$burst;
            $loop->run_once(0);
            $poll_count++;
        }
        $receive_cpu+=cpu()-$cpu_at;
        $receive_wall+=now()-$poll_start;
        die "UDP loop failed mode=$mode bytes=$bytes burst=$burst ".
            "round=$round wanted=".($before+$burst)." got=$received\n"
            if $received!=$before+$burst;
    }
    my $whole_cpu=cpu()-$whole_cpu_start;
    my $elapsed=now()-$begin;
    $server->close;
    close $tx;
    die "Callback corruption mode=$mode bytes=$bytes count=$bad\n"
        if $bad;
    return {
        mode=>$mode,bytes=>$bytes,burst=>$burst,rounds=>$rounds,
        max_datagram_size=>$max_setting,
        sent=>$rounds*$burst,received=>$received,
        bad=>$bad,
        packets_per_second=>$received/$elapsed,
        total_cpu_us_per_packet=>$whole_cpu*1e6/$received,
        receive_cpu_us_per_packet=>$receive_cpu*1e6/$received,
        receive_wall_us_per_packet=>$receive_wall*1e6/$received,
        loop_polls=>$poll_count,
    };
}
make_path(dirname($output));
open my $out,'>',$output or die "open $output: $!";
$out->autoflush(1);
my $json=JSON::PP->new->canonical;
print {$out} $json->encode({
    type=>'metadata',benchmark=>'udp-recvmmsg-loop-v1',
    rounds=>$rounds,repeats=>$repeats,
    sizes=>\@sizes,bursts=>\@bursts,modes=>\@modes,
    max_sizes=>\@max_sizes,
}),"\n";
my @all;
for my $repeat (1..$repeats) {
    for my $size (@sizes) {
        for my $burst (@bursts) {
            next if $size*$burst>131072;
            for my $max_setting (@max_sizes) {
                my @order=@modes;
                push @order,shift @order for 1..(($repeat-1)%@modes);
                for my $mode (@order) {
                    my $row=exercise(
                        $size,$burst,$mode,$rounds,$max_setting
                    );
                    $row->{repeat}=$repeat;
                    $row->{type}='trial';
                    print {$out} $json->encode($row),"\n";
                    push @all,$row;
                    printf "repeat=%d bytes=%d burst=%d max=%s mode=%d: ".
                        "%8.0f packets/s receive-CPU %.3f us/packet\n",
                        $repeat,$size,$burst,$max_setting,$mode,
                        $row->{packets_per_second},
                        $row->{receive_cpu_us_per_packet};
                }
            }
        }
    }
}
say "\nMedian Loop + application callback receive CPU (us/packet):";
for my $size (@sizes) {
    for my $burst (@bursts) {
        next if $size*$burst>131072;
        for my $max_setting (@max_sizes) {
            my %val;
            for my $mode (@modes) {
                my @r=grep {$_->{bytes}==$size && $_->{burst}==$burst
                    && $_->{max_datagram_size} eq $max_setting
                    && $_->{mode}==$mode} @all;
                $val{$mode}=median([
                    map {$_->{receive_cpu_us_per_packet}} @r
                ]);
            }
            printf "bytes=%5d burst=%2d max=%-7s recvmsg=%.3f ".
                "recvmmsg8=%.3f recvmmsg32=%.3f\n",
                $size,$burst,$max_setting,
                $val{0},$val{8},$val{32};
        }
    }
}
close $out or die "close results: $!";
say "Saved $output";
