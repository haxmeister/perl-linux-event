#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;
use Getopt::Long qw(GetOptions);
use IO::Socket::INET;
use Socket qw(SOL_SOCKET SO_RCVBUF);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC CLOCK_PROCESS_CPUTIME_ID);
use JSON::PP ();
use IO::Handle;
use File::Path qw(make_path);
use File::Basename qw(dirname);
use Linux::Event::_Socket::Dgram;

# UDP queued-burst receive microbenchmark. Compares the *same* compiled
# Linux::Event _recv_batch XS boundary with and without recvmmsg enabled.
# Packet data and source addresses traverse the same XS-to-Perl return format.
# It is deliberately not a claim about whole-server throughput or sendmmsg.
my $rounds=1500;
my $repeats=3;
my $sizes='64,512,1400,8192';
my $bursts='8,32';
my $modes='0,8,32';
my $output='bench/results/udp-recvmmsg-ci.jsonl';
my $help=0;
GetOptions(
    'rounds=i'=>\$rounds, 'repeats=i'=>\$repeats,
    'sizes=s'=>\$sizes, 'bursts=s'=>\$bursts,
    'modes=s'=>\$modes, 'output=s'=>\$output, 'help'=>\$help,
) or die "Bad options. Use --help\n";
if ($help) {
    print <<'HELP';
UDP recvmmsg queued-burst experimental benchmark
  perl -Mblib bench/experiments/udp-recvmmsg-burst.pl
  --rounds 1500 --repeats 3
  --sizes 64,512,1400,8192 --bursts 8,32 --modes 0,8,32
  --output bench/results/udp-recvmmsg-ci.jsonl

Mode 0 calls legacy recvmsg repeatedly. Modes 8 and 32 use recvmmsg.
Both execute through the same private XS API and return one packet record.
For every repetition: send one UDP burst to loopback, immediately drain it
via Linux::Event's compiled XS, and validate sequence and payload length.
Output includes CPU time spent only inside each native receive invocation,
plus elapsed time and total sender+receiver CPU. A burst-size / payload-size
combination exceeding 128 KiB is skipped to minimize kernel queue drops.
HELP
    exit 0;
}
die "Linux required\n" unless $^O eq 'linux';
die "Invalid rounds\n" unless $rounds>=1 && $rounds<=100_000;
die "Invalid repeats\n" unless $repeats>=1 && $repeats<=10;
sub nums ($arg,$min,$max) {
    my @v=split /,/, $arg;
    die "Invalid parameter $arg\n" unless @v &&
        !grep { !/^\d+$/ || $_<$min || $_>$max } @v;
    return @v;
}
my @sizes=nums($sizes,4,8192);
my @bursts=nums($bursts,2,64);
my @modes=nums($modes,0,32);
sub now () { clock_gettime(CLOCK_MONOTONIC) }
sub cpu () { clock_gettime(CLOCK_PROCESS_CPUTIME_ID) }
sub median ($v) {
    my @s=sort {$a <=> $b} @$v;
    return @s%2 ? $s[int(@s/2)] : ($s[@s/2-1]+$s[@s/2])/2;
}
sub exercise ($bytes,$burst,$mode,$rounds) {
    my $rx=IO::Socket::INET->new(
        LocalAddr=>'127.0.0.1',LocalPort=>0,Proto=>'udp'
    ) or die "UDP RX socket: $!";
    # Linux may clamp SO_RCVBUF; our modest bursts avoid flooding it.
    $rx->setsockopt(SOL_SOCKET,SO_RCVBUF,pack('i',1048576))
        or die "UDP SO_RCVBUF: $!";
    my $actual=unpack('i',$rx->getsockopt(SOL_SOCKET,SO_RCVBUF));
    my $tx=IO::Socket::INET->new(
        PeerAddr=>'127.0.0.1',PeerPort=>$rx->sockport,Proto=>'udp'
    ) or die "UDP TX socket: $!";
    local $ENV{LINUX_EVENT_EXPERIMENT_RECVMMSG}="$mode";
    my $head='x' x ($bytes-4);
    my $recv_cpu=0;
    my $recv_wall=0;
    my $native_calls=0;
    my $started=now();
    my $cpu_start=cpu();
    my $received=0;
    my $errors=0;
    for my $round (0..$rounds-1) {
        my @payload=map { pack('N',$_).$head } (0..$burst-1);
        for my $packet (@payload) {
            my $n=$tx->send($packet);
            die "UDP send failed: $!" unless defined $n && $n==$bytes;
        }
        my $batch_start=now();
        my $cpu_at=cpu();
        my $batch=Linux::Event::_Socket::Dgram::_recv_batch(
            fileno($rx),$bytes,$burst
        );
        $recv_cpu+=cpu()-$cpu_at;
        $recv_wall+=now()-$batch_start;
        $native_calls++;
        my $count=(@$batch-1)/4;
        if ($batch->[0] || $count!=$burst) {
            $errors++;
            die "Incomplete UDP burst mode=$mode size=$bytes burst=$burst ".
                "iteration=$round received=$count errno=$batch->[0] ".
                "(SO_RCVBUF=$actual)\n";
        }
        for my $i (0..$burst-1) {
            my ($payload,$addr,$length,$truncated)=
                @$batch[1+$i*4..4+$i*4];
            die "UDP payload / address corruption mode=$mode packet=$i\n"
                if !defined($payload) || $payload ne $payload[$i]
                || $truncated || $length!=$bytes || length($addr)<16;
            $received++;
        }
    }
    my $cpu_total=cpu()-$cpu_start;
    my $wall_total=now()-$started;
    close $tx;
    close $rx;
    return {
        mode=>$mode,bytes=>$bytes,burst=>$burst,rounds=>$rounds,
        sent=>$rounds*$burst,received=>$received,errors=>$errors,
        received_per_second=>$received/$wall_total,
        total_cpu_us_per_packet=>$cpu_total*1e6/$received,
        receive_cpu_us_per_packet=>$recv_cpu*1e6/$received,
        receive_wall_us_per_packet=>$recv_wall*1e6/$received,
        wall_s=>$wall_total,
        receive_calls=>$native_calls,so_rcvbuf=>$actual,
    };
}

make_path(dirname($output));
open my $out,'>',$output or die "open $output: $!";
$out->autoflush(1);
my $json=JSON::PP->new->canonical;
print {$out} $json->encode({
    type=>'metadata',benchmark=>'udp-recvmmsg-burst-v1',
    rounds=>$rounds,repeats=>$repeats,
    sizes=>\@sizes,bursts=>\@bursts,modes=>\@modes,
}),"\n";
my @all;
for my $repeat (1..$repeats) {
    for my $size (@sizes) {
        for my $burst (@bursts) {
            next if $size*$burst>131072;
            my @order=@modes;
            push @order,shift @order for 1..(($repeat-1)%@modes);
            for my $mode (@order) {
                my $row=exercise($size,$burst,$mode,$rounds);
                $row->{repeat}=$repeat;
                $row->{type}='trial';
                print {$out} $json->encode($row),"\n";
                push @all,$row;
                printf "repeat=%d bytes=%d burst=%d recv=%s: ".
                    "%8.1f packets/s total; receive CPU %.3f us/packet\n",
                    $repeat,$size,$burst,$mode,
                    $row->{received_per_second},
                    $row->{receive_cpu_us_per_packet};
            }
        }
    }
}
say "\nMedian native receive CPU time by configuration (us/packet):";
for my $size (@sizes) {
    for my $burst (@bursts) {
        next if $size*$burst>131072;
        for my $mode (@modes) {
            my @rows=grep {
                $_->{bytes}==$size && $_->{burst}==$burst
                    && $_->{mode}==$mode
            } @all;
            next unless @rows;
            printf "bytes=%5d burst=%2d mode=%2d cpu=%.3f us/packet\n",
                $size,$burst,$mode,median([
                    map {$_->{receive_cpu_us_per_packet}} @rows
                ]);
        }
    }
}
close $out or die "close $output: $!";
say "Saved $output";
