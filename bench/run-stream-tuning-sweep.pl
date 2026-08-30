#!/usr/bin/env perl
use v5.36;
use strict;
use warnings;

use Getopt::Long qw(GetOptions);
use IO::Socket::INET;
use JSON::PP;
use POSIX qw(strftime);
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC CLOCK_PROCESS_CPUTIME_ID);

use Linux::Event;
use Linux::Event::Loop;
use Linux::Event::Stream;

my @modes = qw(framed);
my @transports = qw(unix);
my @message_sizes = (16, 64, 256, 1_024, 4_096, 16_384, 65_536, 200_000);
my @read_sizes = (4_096, 65_536, 262_144);
my @read_budgets = (0, 262_144);
my @message_batch_sizes = (0, 16, 64);
my @read_batch_bytes = (0, 65_536, 262_144);
my @max_buffers = (8_388_608);
my $target_bytes = 32 * 1024 * 1024;
my $min_messages = 128;
my $max_messages = 100_000;
my $warmup = 0;
my $repeats = 3;
my $json_path;
my $help;

GetOptions(
    'modes=s' => sub { @modes = split_list($_[1]) },
    'transports=s' => sub { @transports = split_list($_[1]) },
    'message-sizes=s' => sub { @message_sizes = split_int_list($_[1]) },
    'read-sizes=s' => sub { @read_sizes = split_int_list($_[1]) },
    'read-budgets=s' => sub { @read_budgets = split_int_list($_[1]) },
    'message-batch-sizes=s' => sub { @message_batch_sizes = split_int_list($_[1]) },
    'read-batch-bytes=s' => sub { @read_batch_bytes = split_int_list($_[1]) },
    'max-buffers=s' => sub { @max_buffers = split_int_list($_[1]) },
    'target-bytes=i' => \$target_bytes,
    'min-messages=i' => \$min_messages,
    'max-messages=i' => \$max_messages,
    'warmup=i' => \$warmup,
    'repeats=i' => \$repeats,
    'json=s' => \$json_path,
    'help' => \$help,
) or usage(1);
usage(0) if $help;

die "--json is required\n" if !defined($json_path) || $json_path eq '';
die "target-bytes must be positive\n" if $target_bytes < 1;
die "min-messages must be positive\n" if $min_messages < 1;
die "max-messages must be >= min-messages\n" if $max_messages < $min_messages;
die "warmup must be non-negative\n" if $warmup < 0;
die "repeats must be positive\n" if $repeats < 1;
validate_positive('message size', \@message_sizes);
validate_positive('read size', \@read_sizes);
validate_nonnegative('read budget', \@read_budgets);
validate_nonnegative('message batch size', \@message_batch_sizes);
validate_nonnegative('read batch bytes', \@read_batch_bytes);
validate_positive('max buffer', \@max_buffers);

my %valid_mode = map { $_ => 1 } qw(framed raw);
my %valid_transport = map { $_ => 1 } qw(unix tcp);
die "unknown mode in --modes\n" if grep { !$valid_mode{$_} } @modes;
die "unknown transport in --transports\n" if grep { !$valid_transport{$_} } @transports;

my @series_configs;
for my $mode (@modes) {
    for my $transport (@transports) {
        for my $read_size (@read_sizes) {
            for my $read_budget (@read_budgets) {
                for my $max_buffer (@max_buffers) {
                    my @batches = $mode eq 'framed' ? @message_batch_sizes : @read_batch_bytes;
                    for my $batch (@batches) {
                        push @series_configs, {
                            mode => $mode,
                            transport => $transport,
                            read_size => $read_size,
                            read_budget_bytes => $read_budget,
                            message_batch_size => $mode eq 'framed' ? $batch : 0,
                            read_batch_bytes => $mode eq 'raw' ? $batch : 0,
                            max_buffer => $max_buffer,
                        };
                    }
                }
            }
        }
    }
}

die "no tuning configurations selected\n" if !@series_configs;

my @raw;
my %points;
for my $series_index (0 .. $#series_configs) {
    my $config = $series_configs[$series_index];
    say config_label($series_index + 1, scalar(@series_configs), $config);

    for my $message_size (@message_sizes) {
        if ($config->{mode} eq 'framed'
            && $message_size + 1 > $config->{max_buffer}) {
            $points{series_key($config)}{$message_size} = {
                message_size => $message_size,
                status => 'invalid',
                reason => 'message_exceeds_max_buffer',
            };
            printf "  %8d B skipped: frame exceeds max_buffer=%d\n",
                $message_size, $config->{max_buffer};
            next;
        }
        my $messages = messages_for_size($message_size);
        run_case($config, $message_size, $messages) for 1 .. $warmup;

        my @rows;
        for my $repeat (1 .. $repeats) {
            my $row = run_case($config, $message_size, $messages);
            $row->{repeat} = $repeat;
            push @rows, $row;
            push @raw, $row;
            printf "  %8d B repeat=%d %12.1f msg/s %10.1f MiB/s %8.3f cpu us/msg reads=%d callbacks=%d\n",
                $message_size, $repeat,
                $row->{messages_per_second},
                $row->{payload_mib_per_second},
                $row->{cpu_us_per_message},
                $row->{read_calls},
                $row->{callback_calls};
        }

        $points{series_key($config)}{$message_size} = {
            message_size => $message_size,
            messages => $messages,
            median_messages_per_second => median(map { $_->{messages_per_second} } @rows),
            median_payload_mib_per_second => median(map { $_->{payload_mib_per_second} } @rows),
            median_cpu_us_per_message => median(map { $_->{cpu_us_per_message} } @rows),
            median_read_calls => median(map { $_->{read_calls} } @rows),
            median_callback_calls => median(map { $_->{callback_calls} } @rows),
        };
    }
}

my @series = map {
    my $config = $_;
    my $key = series_key($config);
    +{
        config => { %$config },
        points => [ map { $points{$key}{$_} } sort { $a <=> $b } keys %{ $points{$key} } ],
    }
} @series_configs;

my $report = {
    benchmark => 'linux-event-stream-tuning-sweep',
    benchmark_contract_version => 1,
    generated_at_utc => strftime('%Y-%m-%dT%H:%M:%SZ', gmtime),
    linux_event_version => $Linux::Event::VERSION,
    perl_version => "$^V",
    configuration => {
        modes => \@modes,
        transports => \@transports,
        message_sizes => \@message_sizes,
        read_sizes => \@read_sizes,
        read_budgets => \@read_budgets,
        message_batch_sizes => \@message_batch_sizes,
        read_batch_bytes => \@read_batch_bytes,
        max_buffers => \@max_buffers,
        target_bytes => $target_bytes,
        min_messages => $min_messages,
        max_messages => $max_messages,
        warmup => $warmup,
        repeats => $repeats,
    },
    series => \@series,
    raw => \@raw,
};

open my $json, '>', $json_path or die "open $json_path: $!\n";
print {$json} JSON::PP->new->canonical->pretty->encode($report);
close $json or die "close $json_path: $!\n";

printf "\nWrote %d tuning series and %d measured rows to %s\n",
    scalar(@series), scalar(@raw), $json_path;

my %benchmark_class;
sub benchmark_class ($config) {
    my $key = series_key($config);
    return $benchmark_class{$key} if $benchmark_class{$key};

    my $safe = $key;
    $safe =~ s/\W/_/g;
    my $class = "Linux::Event::Bench::StreamTune::$safe";
    if ($config->{mode} eq 'framed') {
        eval qq{
            package $class;
            use parent 'Linux::Event::Stream';
            use Linux::Event::Framer 'Delimiter', "\\n";
            1;
        } or die "define framed benchmark class: $@";
    } else {
        no strict 'refs';
        @{"${class}::ISA"} = ('Linux::Event::Stream');
    }

    no strict 'refs';
    my %policy = (
        read_size => $config->{read_size},
        read_budget_bytes => $config->{read_budget_bytes},
        read_batch_bytes => $config->{read_batch_bytes},
        message_batch_size => $config->{message_batch_size},
        max_buffer => $config->{max_buffer},
    );
    *{"${class}::stream_options"} = sub ($class_name) { return { %policy } };

    if ($config->{mode} eq 'framed' && $config->{message_batch_size}) {
        *{"${class}::on_messages"} = sub ($stream, $messages) {
            $stream->data->{messages} += scalar @$messages;
        };
    } elsif ($config->{mode} eq 'framed') {
        *{"${class}::on_message"} = sub ($stream, $message) {
            $stream->data->{messages}++;
        };
    } else {
        *{"${class}::on_data"} = sub ($stream, $bytes) {
            $stream->data->{bytes} += length($bytes);
        };
    }
    *{"${class}::on_eof"} = sub ($stream) { $stream->data->{loop}->stop };
    *{"${class}::on_error"} = sub ($stream, $error) {
        die "Stream tuning benchmark error: $error\n";
    };

    $benchmark_class{$key} = $class;
    return $class;
}

sub run_case ($config, $message_size, $messages) {
    my ($receiver, $sender) = connected_pair($config->{transport});
    pipe(my $gate_read, my $gate_write) or die "gate pipe: $!";

    my $payload = 'x' x $message_size;
    my $wire = $config->{mode} eq 'framed' ? $payload . "\n" : $payload;
    my $writer = fork();
    die "writer fork: $!" if !defined $writer;
    if ($writer == 0) {
        close $receiver;
        close $gate_write;
        my $gate = '';
        sysread($gate_read, $gate, 1) == 1 or exit 2;
        close $gate_read;
        eval { write_messages($sender, $wire, $messages); 1 } or exit 3;
        close $sender;
        exit 0;
    }

    close $sender;
    close $gate_read;
    my $loop = Linux::Event::Loop->new;
    my $state = {
        loop => $loop,
        messages => 0,
        bytes => 0,
    };
    my $class = benchmark_class($config);
    my $stream = $class->new(loop => $loop, fh => $receiver, data => $state);

    my $wall_start = clock_gettime(CLOCK_MONOTONIC);
    my $cpu_start = clock_gettime(CLOCK_PROCESS_CPUTIME_ID);
    syswrite($gate_write, 'g') == 1 or die "release writer: $!";
    close $gate_write;

    local $SIG{ALRM} = sub { die "Stream tuning benchmark timed out\n" };
    alarm 120;
    my $ok = eval { $loop->run; 1 };
    my $error = $@;
    alarm 0;
    my $cpu_end = clock_gettime(CLOCK_PROCESS_CPUTIME_ID);
    my $wall_end = clock_gettime(CLOCK_MONOTONIC);

    if (!$ok) {
        kill 'TERM', $writer;
        waitpid($writer, 0);
        die $error;
    }
    waitpid($writer, 0);
    die "writer failed with status $?\n" if $? != 0;

    my $expected_payload_bytes = $messages * $message_size;
    if ($config->{mode} eq 'framed') {
        die "received $state->{messages} messages, expected $messages\n"
            if $state->{messages} != $messages;
    } else {
        die "received $state->{bytes} bytes, expected $expected_payload_bytes\n"
            if $state->{bytes} != $expected_payload_bytes;
    }

    my $stats = $stream->{xs_state}->stats;
    my $elapsed = $wall_end - $wall_start;
    my $cpu = $cpu_end - $cpu_start;
    my $payload_mib = $expected_payload_bytes / 1_048_576;
    my $callback_calls = $config->{mode} eq 'framed'
        ? $stats->{message_callback_calls} + $stats->{message_batch_calls}
        : $stats->{delivery_calls};

    $stream->close if !$stream->is_closed;
    return {
        config => { %$config },
        message_size => $message_size,
        messages => $messages,
        payload_bytes => $expected_payload_bytes,
        elapsed_seconds => 0 + $elapsed,
        receiver_cpu_seconds => 0 + $cpu,
        messages_per_second => $messages / $elapsed,
        payload_mib_per_second => $payload_mib / $elapsed,
        cpu_us_per_message => $cpu * 1_000_000 / $messages,
        read_calls => 0 + ($stats->{read_calls} // 0),
        callback_calls => 0 + ($callback_calls // 0),
        frames_emitted => 0 + ($stats->{frames_emitted} // 0),
        read_batch_flushes => 0 + ($stats->{read_batch_flushes} // 0),
        message_batch_calls => 0 + ($stats->{message_batch_calls} // 0),
    };
}

sub messages_for_size ($size) {
    my $messages = int($target_bytes / $size);
    $messages = $min_messages if $messages < $min_messages;
    $messages = $max_messages if $messages > $max_messages;
    return $messages;
}

sub connected_pair ($transport) {
    if ($transport eq 'unix') {
        socketpair(my $left, my $right, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
            or die "socketpair: $!";
        return ($left, $right);
    }

    my $listener = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1', LocalPort => 0,
        Proto => 'tcp', Listen => 1, ReuseAddr => 1,
    ) or die "TCP listener: $!";
    my $sender = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1', PeerPort => $listener->sockport,
        Proto => 'tcp',
    ) or die "TCP connect: $!";
    my $receiver = $listener->accept or die "TCP accept: $!";
    close $listener;
    return ($receiver, $sender);
}

sub write_messages ($fh, $wire, $count) {
    my $per_chunk = int(1_048_576 / length($wire));
    $per_chunk = 1 if $per_chunk < 1;
    my $full_chunk = $wire x $per_chunk;
    while ($count > 0) {
        my $take = $count < $per_chunk ? $count : $per_chunk;
        my $bytes = $take == $per_chunk ? $full_chunk : $wire x $take;
        write_all($fh, $bytes);
        $count -= $take;
    }
}

sub write_all ($fh, $bytes) {
    my $offset = 0;
    my $length = length($bytes);
    while ($offset < $length) {
        my $written = syswrite($fh, $bytes, $length - $offset, $offset);
        if (defined $written) {
            $offset += $written;
            next;
        }
        next if $!{EINTR};
        die "writer syswrite: $!";
    }
}

sub series_key ($config) {
    return join ':', map { $config->{$_} // 0 }
        qw(mode transport read_size read_budget_bytes message_batch_size read_batch_bytes max_buffer);
}

sub config_label ($index, $total, $config) {
    my $batch = $config->{mode} eq 'framed'
        ? "message_batch=$config->{message_batch_size}"
        : "read_batch=$config->{read_batch_bytes}";
    return sprintf "[%d/%d] %s/%s read=%d budget=%d %s max_buffer=%d",
        $index, $total, $config->{transport}, $config->{mode},
        $config->{read_size}, $config->{read_budget_bytes}, $batch,
        $config->{max_buffer};
}

sub median (@values) {
    @values = sort { $a <=> $b } @values;
    my $middle = int(@values / 2);
    return @values % 2
        ? $values[$middle]
        : ($values[$middle - 1] + $values[$middle]) / 2;
}

sub split_list ($value) {
    return grep { length } split /,/, $value;
}

sub split_int_list ($value) {
    my @values = split_list($value);
    die "list values must be non-negative integers\n"
        if grep { $_ !~ /\A\d+\z/ } @values;
    return map { 0 + $_ } @values;
}

sub validate_positive ($name, $values) {
    die "$name values must be positive\n" if grep { $_ <= 0 } @$values;
}

sub validate_nonnegative ($name, $values) {
    die "$name values must be non-negative\n" if grep { $_ < 0 } @$values;
}

sub usage ($exit) {
    print <<'USAGE';
Usage: run-stream-tuning-sweep.pl --json=PATH [options]
  --modes=LIST                 framed,raw (default: framed)
  --transports=LIST            unix,tcp (default: unix)
  --message-sizes=LIST         logical payload bytes
  --read-sizes=LIST            Stream read_size values
  --read-budgets=LIST          Stream read_budget_bytes values; 0 drains to EAGAIN
  --message-batch-sizes=LIST   framed Stream message_batch_size values
  --read-batch-bytes=LIST      raw Stream read_batch_bytes values
  --max-buffers=LIST           Stream max_buffer values
  --target-bytes=N             approximate payload bytes per case (default: 33554432)
  --min-messages=N             minimum messages per case (default: 128)
  --max-messages=N             maximum messages per case (default: 100000)
  --warmup=N                   untimed runs per point (default: 0)
  --repeats=N                  measured runs per point (default: 3)
  --json=PATH                  required JSON output path
  --help                       show this help

The framed mode uses the native newline delimiter framer. The raw mode treats
message size as a logical payload unit for throughput accounting while Stream
receives raw bytes. The writer closes after each case, so explicit batches are
flushed at end-of-drain/EOF and never wait for a later readiness event.
USAGE
    exit $exit;
}
