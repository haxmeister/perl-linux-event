#!/usr/bin/env perl
use strict;
use warnings;
use lib 'lib';
use Linux::Event;
use Time::HiRes qw(time);
use Fcntl;

print "=== Linux::Event Performance Benchmarks ===\n\n";

# Benchmark 1: Timer creation and firing
print "Benchmark 1: Timer Performance\n";
print "-" x 50, "\n";
{
    my $loop = Linux::Event->new(queue_size => 1024);
    my $count = 1000;
    my $fired = 0;
    
    my $start = time;
    
    for (1..$count) {
        $loop->timer(
            after => 0.001,
            cb => sub {
                $fired++;
                $loop->stop() if $fired >= $count;
            }
        );
    }
    
    $loop->run();
    
    my $elapsed = time - $start;
    my $rate = $count / $elapsed;
    
    printf "Created and fired %d timers in %.3fs\n", $count, $elapsed;
    printf "Rate: %.0f timers/second\n", $rate;
    print "\n";
}

# Benchmark 2: File I/O
print "Benchmark 2: File Read Performance\n";
print "-" x 50, "\n";
{
    # Create test file
    my $test_file = "/tmp/linux_event_bench_$$.txt";
    my $file_size = 1024 * 100; # 100KB
    my $data = "x" x $file_size;
    
    open my $fh, '>', $test_file or die $!;
    print $fh $data;
    close $fh;
    
    my $loop = Linux::Event->new();
    my $iterations = 100;
    my $completed = 0;
    
    my $start = time;
    
    for (1..$iterations) {
        $loop->read_file(
            path => $test_file,
            cb => sub {
                my ($read_data, $error) = @_;
                $completed++;
                $loop->stop() if $completed >= $iterations;
            }
        );
    }
    
    $loop->run();
    
    my $elapsed = time - $start;
    my $throughput = ($file_size * $iterations) / $elapsed / 1024 / 1024;
    
    printf "Read %d files (%d KB each) in %.3fs\n", 
        $iterations, $file_size / 1024, $elapsed;
    printf "Throughput: %.2f MB/s\n", $throughput;
    printf "Operations: %.0f reads/second\n", $iterations / $elapsed;
    
    unlink $test_file;
    print "\n";
}

# Benchmark 3: File Write Performance
print "Benchmark 3: File Write Performance\n";
print "-" x 50, "\n";
{
    my $loop = Linux::Event->new();
    my $iterations = 100;
    my $file_size = 1024 * 100; # 100KB
    my $data = "x" x $file_size;
    my $completed = 0;
    
    my $start = time;
    
    for my $i (1..$iterations) {
        $loop->write_file(
            path => "/tmp/linux_event_write_${i}_$$.txt",
            data => $data,
            cb => sub {
                $completed++;
                $loop->stop() if $completed >= $iterations;
            }
        );
    }
    
    $loop->run();
    
    my $elapsed = time - $start;
    my $throughput = ($file_size * $iterations) / $elapsed / 1024 / 1024;
    
    printf "Wrote %d files (%d KB each) in %.3fs\n",
        $iterations, $file_size / 1024, $elapsed;
    printf "Throughput: %.2f MB/s\n", $throughput;
    printf "Operations: %.0f writes/second\n", $iterations / $elapsed;
    
    # Cleanup
    unlink "/tmp/linux_event_write_${_}_$$.txt" for 1..$iterations;
    print "\n";
}

# Benchmark 4: Event loop overhead
print "Benchmark 4: Event Loop Overhead\n";
print "-" x 50, "\n";
{
    my $loop = Linux::Event->new();
    my $iterations = 10000;
    my $count = 0;
    
    my $start = time;
    
    for (1..$iterations) {
        $loop->defer(sub {
            $count++;
            $loop->stop() if $count >= $iterations;
        });
    }
    
    $loop->run();
    
    my $elapsed = time - $start;
    my $rate = $iterations / $elapsed;
    
    printf "Processed %d deferred callbacks in %.3fs\n", $iterations, $elapsed;
    printf "Rate: %.0f callbacks/second\n", $rate;
    printf "Overhead: %.6f ms per callback\n", ($elapsed / $iterations) * 1000;
    print "\n";
}

# Benchmark 5: Watcher creation/destruction
print "Benchmark 5: Watcher Creation/Destruction\n";
print "-" x 50, "\n";
{
    my $loop = Linux::Event->new();
    my $iterations = 1000;
    
    my $start = time;
    
    for (1..$iterations) {
        my $w = $loop->timer(
            after => 100,  # Won't fire
            cb => sub {}
        );
        $w->destroy();
    }
    
    my $elapsed = time - $start;
    my $rate = $iterations / $elapsed;
    
    printf "Created and destroyed %d watchers in %.3fs\n", $iterations, $elapsed;
    printf "Rate: %.0f operations/second\n", $rate;
    print "\n";
}

# Benchmark 6: Signal handling
print "Benchmark 6: Signal Handling\n";
print "-" x 50, "\n";
{
    my $loop = Linux::Event->new();
    my $iterations = 100;
    my $count = 0;
    
    $loop->signal(
        signal => 'USR1',
        cb => sub {
            $count++;
            $loop->stop() if $count >= $iterations;
        }
    );
    
    my $start = time;
    
    for (1..$iterations) {
        kill 'USR1', $$;
    }
    
    $loop->timer(after => 2, cb => sub { $loop->stop() });
    $loop->run();
    
    my $elapsed = time - $start;
    my $rate = $count / $elapsed;
    
    printf "Handled %d signals in %.3fs\n", $count, $elapsed;
    printf "Rate: %.0f signals/second\n", $rate;
    print "\n";
}

print "=== Benchmark Complete ===\n";
print "\nNotes:\n";
print "- Results vary based on system load and kernel version\n";
print "- io_uring performance improves with newer kernels\n";
print "- File I/O benchmarks include filesystem overhead\n";
