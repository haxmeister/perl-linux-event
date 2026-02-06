#!/usr/bin/env perl
use strict;
use warnings;
use lib 'lib';
use Linux::Event;

print "Linux::Event - File Watching with inotify Example\n";
print "=" x 50, "\n\n";

unless ($Linux::Event::INOTIFY_AVAILABLE) {
    die "This example requires Linux::Inotify2 module.\n" .
        "Install it with: cpanm Linux::Inotify2\n";
}

my $loop = Linux::Event->new();

# Watch a specific file
print "Example 1: Watching a single file\n";
print "-" x 50, "\n";

my $watch_file = '/tmp/test_watch.txt';

# Create the test file
open my $fh, '>', $watch_file or die "Cannot create $watch_file: $!";
print $fh "Initial content\n";
close $fh;

my $file_watcher = $loop->watch(
    path => $watch_file,
    events => ['modify', 'attrib', 'delete_self'],
    cb => sub {
        my ($watcher, $event, $name) = @_;
        print "[FILE] Event: $event on $name\n";
        
        if ($event =~ /delete_self/) {
            print "[FILE] File was deleted, stopping watcher\n";
            $watcher->stop();
        }
    }
);

print "Watching file: $watch_file\n";
print "Try: echo 'test' >> $watch_file\n";
print "Try: touch $watch_file\n";
print "Try: rm $watch_file\n\n";

# Watch a directory
print "Example 2: Watching a directory\n";
print "-" x 50, "\n";

my $watch_dir = '/tmp/test_watch_dir';
mkdir $watch_dir unless -d $watch_dir;

my $dir_watcher = $loop->watch(
    path => $watch_dir,
    events => ['create', 'delete', 'modify', 'moved_from', 'moved_to'],
    cb => sub {
        my ($watcher, $event, $name) = @_;
        print "[DIR] Event: $event on $name\n";
    }
);

print "Watching directory: $watch_dir\n";
print "Try: touch $watch_dir/newfile.txt\n";
print "Try: echo 'data' > $watch_dir/newfile.txt\n";
print "Try: rm $watch_dir/newfile.txt\n\n";

# Recursive watching
print "Example 3: Recursive directory watching\n";
print "-" x 50, "\n";

my $recursive_dir = '/tmp/test_recursive';
mkdir $recursive_dir unless -d $recursive_dir;
mkdir "$recursive_dir/subdir1" unless -d "$recursive_dir/subdir1";
mkdir "$recursive_dir/subdir2" unless -d "$recursive_dir/subdir2";

my $recursive_watcher = $loop->watch(
    path => $recursive_dir,
    events => ['create', 'modify', 'delete'],
    recursive => 1,
    cb => sub {
        my ($watcher, $event, $name) = @_;
        print "[RECURSIVE] Event: $event on $name\n";
    }
);

print "Watching recursively: $recursive_dir\n";
print "Try: echo 'test' > $recursive_dir/subdir1/file.txt\n";
print "Try: echo 'test' > $recursive_dir/subdir2/file.txt\n\n";

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

# Cleanup
print "\nCleaning up...\n";
unlink $watch_file if -e $watch_file;
system("rm -rf $watch_dir") if -d $watch_dir;
system("rm -rf $recursive_dir") if -d $recursive_dir;

print "Done.\n";
