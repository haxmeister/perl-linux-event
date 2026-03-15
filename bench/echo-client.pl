use v5.36;
use strict;
use warnings;

use IO::Socket::INET;
use Getopt::Long qw(GetOptions);
use Time::HiRes qw(time);

my %opt = (
    host        => '127.0.0.1',
    port        => 8082,
    clients     => 1,
    messages    => 10000,
    message_len => 64,
    quiet       => 0,
    csv         => undef,
    label       => '',
);

GetOptions(
    'host=s'        => \$opt{host},
    'port=i'        => \$opt{port},
    'clients=i'     => \$opt{clients},
    'messages=i'    => \$opt{messages},
    'message-len=i' => \$opt{message_len},
    'quiet!'        => \$opt{quiet},
    'csv=s'         => \$opt{csv},
    'label=s'       => \$opt{label},
) or die _usage();

die "clients must be >= 1\n"     if $opt{clients} < 1;
die "messages must be >= 1\n"    if $opt{messages} < 1;
die "message-len must be >= 1\n" if $opt{message_len} < 1;

my $payload = ('x' x ($opt{message_len} - 1)) . "\n";
my $want    = length($payload);

my @children;
my @pipes;

my $start = time;

for my $worker_id (1 .. $opt{clients}) {
    pipe(my $r, my $w) or die "pipe failed: $!";

    my $pid = fork();
    die "fork failed: $!" unless defined $pid;

    if ($pid == 0) {
        close $r;
        _run_worker($w, \%opt, $payload, $want);
        exit 0;
    }

    close $w;
    push @children, $pid;
    push @pipes, $r;
}

my $total_msgs  = 0;
my $total_bytes = 0;
my $failures    = 0;
my %failure_reasons;

for my $r (@pipes) {
    my $line = <$r>;
    close $r;

    if (!defined $line) {
        $failures++;
        $failure_reasons{'no worker result'}++;
        next;
    }

    chomp $line;
    my ($msgs, $bytes, $ok, $err) = split /\t/, $line, 4;

    if (!$ok) {
        $failures++;
        $failure_reasons{$err || 'unknown worker failure'}++;
        next;
    }

    $total_msgs  += $msgs;
    $total_bytes += $bytes;
}

for my $pid (@children) {
    waitpid($pid, 0);
    if ($? != 0) {
        $failures++;
        $failure_reasons{"worker exit status " . ($? >> 8)}++;
    }
}

my $elapsed = time - $start;
$elapsed = 0.000001 if $elapsed <= 0;

my $msg_rate  = $total_msgs / $elapsed;
my $byte_rate = $total_bytes / $elapsed;
my $mib_rate  = $byte_rate / (1024 * 1024);

my $failure_text = _failure_text(\%failure_reasons);

if (!$opt{quiet}) {
    print join(
        ' ',
        "clients=$opt{clients}",
        "messages_per_client=$opt{messages}",
        "total_messages=$total_msgs",
        "total_bytes=$total_bytes",
        "elapsed=${elapsed}s",
        "msg_per_sec=$msg_rate",
        "MiB_per_sec=$mib_rate",
        "failures=$failures",
        qq(failure_reasons="$failure_text"),
    ), "\n";
}

if (defined $opt{csv}) {
    _append_csv(
        $opt{csv},
        {
            label               => $opt{label},
            host                => $opt{host},
            port                => $opt{port},
            clients             => $opt{clients},
            messages_per_client => $opt{messages},
            message_len         => $opt{message_len},
            total_messages      => $total_msgs,
            total_bytes         => $total_bytes,
            elapsed_s           => $elapsed,
            msg_per_sec         => $msg_rate,
            mib_per_sec         => $mib_rate,
            failures            => $failures,
            failure_reasons     => $failure_text,
        },
    );
}

sub _run_worker ($fh, $opt, $payload, $want) {
    my $sock = IO::Socket::INET->new(
        PeerAddr => $opt->{host},
        PeerPort => $opt->{port},
        Proto    => 'tcp',
    );

    if (!$sock) {
        print {$fh} join("\t", 0, 0, 0, "connect failed: $!") . "\n";
        close $fh;
        return;
    }

    my $msgs  = 0;
    my $bytes = 0;

    for (1 .. $opt->{messages}) {
        my $off = 0;
        while ($off < $want) {
            my $n = syswrite($sock, $payload, $want - $off, $off);
            if (!defined $n) {
                print {$fh} join("\t", $msgs, $bytes, 0, "write failed: $!") . "\n";
                close $sock;
                close $fh;
                return;
            }
            $off += $n;
        }

        my $buf = '';
        while (length($buf) < $want) {
            my $n = sysread($sock, my $chunk, $want - length($buf));
            if (!defined $n) {
                print {$fh} join("\t", $msgs, $bytes, 0, "read failed: $!") . "\n";
                close $sock;
                close $fh;
                return;
            }
            if ($n == 0) {
                print {$fh} join("\t", $msgs, $bytes, 0, "unexpected eof") . "\n";
                close $sock;
                close $fh;
                return;
            }
            $buf .= $chunk;
        }

        if ($buf ne $payload) {
            print {$fh} join("\t", $msgs, $bytes, 0, "mismatch in echoed payload") . "\n";
            close $sock;
            close $fh;
            return;
        }

        $msgs++;
        $bytes += $want;
    }

    close $sock;
    print {$fh} join("\t", $msgs, $bytes, 1, '') . "\n";
    close $fh;
    return;
}

sub _failure_text ($href) {
    return 'none' if !%$href;

    return join '; ',
        map { "$_ x$href->{$_}" }
        sort keys %$href;
}

sub _append_csv ($path, $row) {
    my $exists = -e $path ? 1 : 0;
    open my $fh, '>>', $path or die "open($path) failed: $!";

    my @cols = qw(
        label
        host
        port
        clients
        messages_per_client
        message_len
        total_messages
        total_bytes
        elapsed_s
        msg_per_sec
        mib_per_sec
        failures
        failure_reasons
    );

    if (!$exists) {
        print {$fh} join(',', @cols) . "\n";
    }

    print {$fh} join(',', map { _csv_escape($row->{$_}) } @cols) . "\n";
    close $fh;
    return;
}

sub _csv_escape ($v) {
    $v = '' if !defined $v;
    $v =~ s/"/""/g;
    return qq("$v");
}

sub _usage {
    return <<"USAGE";
usage: $0 [options]

  --host HOST            default: 127.0.0.1
  --port PORT            default: 8082
  --clients N            default: 1
  --messages N           default: 10000
  --message-len BYTES    default: 64
  --csv FILE             append results to CSV
  --label TEXT           optional label for CSV rows
  --quiet / --no-quiet   default: no-quiet

examples:

  perl $0 --port 8082 --clients 1   --messages 10000 --message-len 64
  perl $0 --port 8082 --clients 100 --messages 1000  --message-len 64
  perl $0 --port 8082 --clients 100 --messages 1000  --message-len 64 --csv bench.csv --label proactor

notes:

  - this client uses forked workers for simple real concurrency
  - each worker keeps one connection open and does request/response echo traffic
  - echoed payload correctness is validated
USAGE
}
