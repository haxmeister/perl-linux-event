#!/usr/bin/env perl
use strict;
use warnings;
use lib 'lib';
use Linux::Event;

print "Linux::Event - Filesystem Monitoring with fanotify Example\n";
print "=" x 50, "\n\n";

# Check if running as root
unless ($> == 0) {
    die "This example requires root privileges (fanotify requires CAP_SYS_ADMIN).\n" .
        "Run with: sudo $0\n";
}

unless ($Linux::Event::FANOTIFY_AVAILABLE) {
    die "This example requires Linux::Fanotify module.\n" .
        "Install it with: cpanm Linux::Fanotify\n";
}

my $loop = Linux::Event->new();

# Example 1: Monitor file opens in /tmp
print "Example 1: Monitoring file opens in /tmp\n";
print "-" x 50, "\n";

my $open_count = 0;
my %pid_opens;

my $tmp_watcher = $loop->fswatch(
    path => '/tmp',
    events => ['open'],
    mark_type => 'mount',
    cb => sub {
        my ($watcher, $event, $path, $pid) = @_;
        $open_count++;
        $pid_opens{$pid}++;
        
        # Only log occasionally to avoid spam
        if ($open_count % 10 == 0) {
            print "[OPEN] $open_count file opens detected\n";
            print "  Most active PIDs: ";
            my @top = sort { $pid_opens{$b} <=> $pid_opens{$a} } keys %pid_opens;
            print join(', ', map { "$_($pid_opens{$_})" } @top[0..2]);
            print "\n";
        }
    }
);

print "Monitoring file opens on /tmp mount point\n";
print "Try: cat /tmp/some_file\n";
print "Try: ls /tmp\n\n";

# Example 2: Monitor modifications in a specific directory
print "Example 2: Monitoring modifications in /var/log\n";
print "-" x 50, "\n";

my $log_watcher = $loop->fswatch(
    path => '/var/log',
    events => ['close_write', 'modify'],
    mark_type => 'inode',
    cb => sub {
        my ($watcher, $event, $path, $pid) = @_;
        print "[LOG] PID $pid: $event on $path\n";
    }
);

print "Monitoring log directory changes\n";
print "Try: echo 'test' | sudo tee /var/log/test.log\n\n";

# Example 3: Monitor file access (requires Linux 5.1+)
if (Linux::Fanotify->can('FAN_CREATE')) {
    print "Example 3: Monitoring create/delete events (Linux 5.1+)\n";
    print "-" x 50, "\n";
    
    my $test_dir = '/tmp/fanotify_test';
    mkdir $test_dir unless -d $test_dir;
    
    my $create_watcher = $loop->fswatch(
        path => $test_dir,
        events => ['create', 'delete'],
        mark_type => 'inode',
        cb => sub {
            my ($watcher, $event, $path, $pid) = @_;
            print "[CREATE/DELETE] PID $pid: $event on $path\n";
        }
    );
    
    print "Monitoring $test_dir for create/delete events\n";
    print "Try: touch $test_dir/testfile\n";
    print "Try: rm $test_dir/testfile\n\n";
} else {
    print "Example 3: Skipped (requires Linux 5.1+)\n";
    print "Your kernel doesn't support create/delete events in fanotify\n\n";
}

# Show stats every 10 seconds
$loop->periodic(
    interval => 10,
    cb => sub {
        print "[STATS] Total file opens: $open_count\n";
        print "[STATS] Unique PIDs: ", scalar(keys %pid_opens), "\n\n";
    }
);

# Stop after 60 seconds
$loop->timer(
    after => 60,
    cb => sub {
        print "\n[TIMEOUT] 60 seconds elapsed, stopping...\n";
        $loop->stop();
    }
);

# Handle Ctrl-C
$loop->signal(
    signal => 'INT',
    cb => sub {
        print "\n[SIGNAL] Caught Ctrl-C, stopping...\n";
        $loop->stop();
    }
);

print "Event loop running...\n";
print "Press Ctrl-C to stop\n\n";

# Run the event loop
$loop->run();

print "\nFinal Statistics:\n";
print "Total file opens: $open_count\n";
print "Unique PIDs: ", scalar(keys %pid_opens), "\n";

# Top 5 most active PIDs
print "\nTop 5 Most Active PIDs:\n";
my @top_pids = sort { $pid_opens{$b} <=> $pid_opens{$a} } keys %pid_opens;
for my $i (0..4) {
    last unless $i < @top_pids;
    my $pid = $top_pids[$i];
    print "  PID $pid: $pid_opens{$pid} opens\n";
}

print "\nDone.\n";
