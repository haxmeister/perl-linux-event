#!/usr/bin/env perl
use strict;
use warnings;
use lib 'lib';
use Linux::Event;

print "Linux::Event - Timers and Periodic Events Example\n";
print "=" x 50, "\n\n";

my $loop = Linux::Event->new();

# One-shot timer
print "Setting up a 3-second timer...\n";
$loop->timer(
    after => 3,
    cb => sub {
        print "[TIMER] 3 seconds elapsed!\n";
    }
);

# Another one-shot timer
$loop->timer(
    after => 5,
    cb => sub {
        print "[TIMER] 5 seconds elapsed!\n";
    }
);

# Periodic timer - ticks every second
print "Setting up a 1-second periodic ticker...\n";
my $tick_count = 0;
my $ticker = $loop->periodic(
    interval => 1,
    cb => sub {
        $tick_count++;
        print "[TICK] $tick_count\n";
    }
);

# Periodic timer with different interval
my $fast_count = 0;
my $fast_ticker = $loop->periodic(
    interval => 0.5,
    cb => sub {
        $fast_count++;
        print "  [FAST-TICK] $fast_count\n";
    }
);

# Stop the fast ticker after 3 seconds
$loop->timer(
    after => 3,
    cb => sub {
        print "[ACTION] Stopping fast ticker\n";
        $fast_ticker->stop();
    }
);

# Demonstrate timer with custom data
$loop->timer(
    after => 2,
    data => { message => "Custom message from timer!" },
    cb => sub {
        my ($watcher) = @_;
        my $data = $watcher->data();
        print "[TIMER] ", $data->{message}, "\n";
    }
);

# Stop everything after 10 seconds
$loop->timer(
    after => 10,
    cb => sub {
        print "\n[ACTION] Stopping all timers and exiting...\n";
        $ticker->stop();
        $fast_ticker->stop();
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

print "Event loop starting...\n";
print "Press Ctrl-C to stop early\n\n";

# Run the event loop
$loop->run();

print "\nEvent loop stopped.\n";
print "Total ticks: $tick_count\n";
print "Total fast ticks: $fast_count\n";
