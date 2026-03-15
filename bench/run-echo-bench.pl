use v5.36;
use strict;
use warnings;

use Getopt::Long qw(GetOptions);
use Time::HiRes qw(time sleep);
use File::Path qw(make_path);
use File::Spec;
use POSIX qw(strftime WNOHANG);

my %opt = (
    host           => '127.0.0.1',
    proactor_port  => 8082,
    reactor_port   => 8083,
    clients        => '1,10,50,100',
    messages       => 1000,
    message_len    => 64,
    outdir         => 'bench/out',
    server_warmup  => 1.0,
    perl           => $^X,
);

GetOptions(
    'host=s'          => \$opt{host},
    'proactor-port=i' => \$opt{proactor_port},
    'reactor-port=i'  => \$opt{reactor_port},
    'clients=s'       => \$opt{clients},
    'messages=i'      => \$opt{messages},
    'message-len=i'   => \$opt{message_len},
    'outdir=s'        => \$opt{outdir},
    'server-warmup=f' => \$opt{server_warmup},
    'perl=s'          => \$opt{perl},
) or die _usage();

my @client_counts = map { 0 + $_ } grep { length $_ } split /,/, $opt{clients};

die "need at least one client count\n" if !@client_counts;

make_path($opt{outdir}) unless -d $opt{outdir};

my $stamp = strftime('%Y%m%d-%H%M%S', localtime);

my $csv   = File::Spec->catfile($opt{outdir}, "echo-bench-$stamp.csv");
my $p_log = File::Spec->catfile($opt{outdir}, "proactor-$stamp.log");
my $r_log = File::Spec->catfile($opt{outdir}, "reactor-$stamp.log");

print "output dir: $opt{outdir}\n";
print "csv: $csv\n";

my $proactor_pid = _start_server(
    perl    => $opt{perl},
    model   => 'proactor',
    backend => 'uring',
    host    => $opt{host},
    port    => $opt{proactor_port},
    logfile => $p_log,
);

my $reactor_pid = _start_server(
    perl    => $opt{perl},
    model   => 'reactor',
    backend => 'epoll',
    host    => $opt{host},
    port    => $opt{reactor_port},
    logfile => $r_log,
);

my @rows;

eval {

    sleep($opt{server_warmup});

    _wait_for_port($opt{host}, $opt{proactor_port}, 5);
    _wait_for_port($opt{host}, $opt{reactor_port}, 5);

    for my $clients (@client_counts) {

        print "\n=== clients=$clients ===\n";

        push @rows, _run_client(
            perl        => $opt{perl},
            host        => $opt{host},
            port        => $opt{proactor_port},
            clients     => $clients,
            messages    => $opt{messages},
            message_len => $opt{message_len},
            label       => 'proactor',
        );

        push @rows, _run_client(
            perl        => $opt{perl},
            host        => $opt{host},
            port        => $opt{reactor_port},
            clients     => $clients,
            messages    => $opt{messages},
            message_len => $opt{message_len},
            label       => 'reactor',
        );
    }

    _write_csv($csv, \@rows);

    _print_summary(\@rows);

    1;

} or do {
    my $err = $@ || 'unknown error';
    warn "benchmark run failed: $err\n";
};

_stop_server($proactor_pid);
_stop_server($reactor_pid);

print "\nserver logs:\n";
print "  proactor: $p_log\n";
print "  reactor:  $r_log\n";
print "results:\n";
print "  csv: $csv\n";

sub _start_server (%arg)
{
    open my $logfh, '>', $arg{logfile} or die "open($arg{logfile}) failed: $!";

    my $pid = fork();
    die "fork failed: $!" unless defined $pid;

    if ($pid == 0)
    {
        open STDOUT, '>&', $logfh or die;
        open STDERR, '>&', $logfh or die;

        exec(
            $arg{perl},
            '-Ilib',
            'bench/echo-server.pl',
            '--model',   $arg{model},
            '--backend', $arg{backend},
            '--host',    $arg{host},
            '--port',    $arg{port},
        ) or die "exec failed: $!";
    }

    close $logfh;

    print "started $arg{model}/$arg{backend} server pid=$pid port=$arg{port}\n";

    return $pid;
}

sub _stop_server ($pid)
{
    return if !$pid;

    kill 'TERM', $pid;

    for (1 .. 20)
    {
        my $done = waitpid($pid, WNOHANG);
        return if $done == $pid;
        sleep 0.1;
    }

    kill 'KILL', $pid;
    waitpid($pid, 0);
}

sub _wait_for_port ($host, $port, $timeout)
{
    my $deadline = time + $timeout;

    while (time < $deadline)
    {
        my $ok = eval {
            require IO::Socket::INET;
            my $s = IO::Socket::INET->new(
                PeerAddr => $host,
                PeerPort => $port,
                Proto    => 'tcp',
                Timeout  => 1,
            );
            if ($s) { close $s; return 1 }
            return 0;
        };

        return if $ok;

        sleep 0.1;
    }

    die "port $host:$port did not become ready\n";
}

sub _run_client (%arg)
{
    my @cmd = (
        $arg{perl},
        'bench/echo-client.pl',
        '--host',        $arg{host},
        '--port',        $arg{port},
        '--clients',     $arg{clients},
        '--messages',    $arg{messages},
        '--message-len', $arg{message_len},
    );

    print "running [$arg{label}]: @cmd\n";

    my $output = qx(@cmd 2>&1);

    my $status = $? >> 8;

    die "client run failed for $arg{label}:\n$output"
        if $status != 0;

    my %parsed = _parse_client_output($output);

    $parsed{label}               = $arg{label};
    $parsed{host}                = $arg{host};
    $parsed{port}                = $arg{port};
    $parsed{clients}             = $arg{clients};
    $parsed{messages_per_client} = $arg{messages};
    $parsed{message_len}         = $arg{message_len};
    $parsed{timestamp}           = strftime('%Y-%m-%d %H:%M:%S', localtime);

    return \%parsed;
}

sub _parse_client_output ($text)
{
    my %out;

    for my $field (qw(
        total_messages
        total_bytes
        elapsed
        msg_per_sec
        MiB_per_sec
        failures
    ))
    {
        if ($text =~ /\b$field=([^\s]+)/)
        {
            $out{$field} = $1;
        }
    }

    if ($text =~ /failure_reasons="([^"]*)"/)
    {
        $out{failure_reasons} = $1;
    }
    else
    {
        $out{failure_reasons} = '';
    }

    die "could not parse client output:\n$text"
        unless exists $out{msg_per_sec};

    return %out;
}

sub _write_csv ($path, $rows)
{
    open my $fh, '>', $path or die "open($path) failed: $!";

    my @cols = qw(
        timestamp
        label
        host
        port
        clients
        messages_per_client
        message_len
        total_messages
        total_bytes
        elapsed
        msg_per_sec
        MiB_per_sec
        failures
        failure_reasons
    );

    print $fh join(',', @cols), "\n";

    for my $row (@$rows)
    {
        print $fh join(',', map { _csv_escape($row->{$_}) } @cols), "\n";
    }

    close $fh;
}

sub _csv_escape ($v)
{
    $v = '' if !defined $v;
    $v =~ s/"/""/g;
    return qq("$v");
}

sub _print_summary ($rows)
{
    print "\nLinux::Event echo benchmark\n\n";

    printf "%-10s %-10s %-15s %-10s %-10s\n",
        'clients','model','msg/sec','MiB/sec','fail';

    print "-" x 60, "\n";

    for my $row (sort {
        $a->{clients} <=> $b->{clients}
        || $a->{label} cmp $b->{label}
    } @$rows)
    {
        printf "%-10d %-10s %-15.1f %-10.2f %-10d\n",
            $row->{clients},
            $row->{label},
            $row->{msg_per_sec},
            $row->{MiB_per_sec},
            $row->{failures};
    }

    print "\n";
}

sub _usage
{
    return <<"USAGE";
usage: $0 [options]

  --host HOST
  --proactor-port PORT
  --reactor-port PORT
  --clients LIST
  --messages N
  --message-len BYTES
  --outdir DIR
  --server-warmup SEC

example:

  perl -Ilib bench/run-echo-bench.pl
USAGE
}
