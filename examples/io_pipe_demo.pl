#!/usr/bin/env perl
use v5.36;

use lib "lib";
use Linux::Event::Loop;

pipe(my $r, my $w) or die "pipe: $!";

# Make the write end autoflush-ish
select((select($w), $|=1)[0]);

my $loop = Linux::Event::Loop->new( backend => 'epoll' );

my %state = (
  got    => 0,
  writer => $w,
);

sub on_pipe_read ($loop, $fh, $watcher) {
  my $st = $watcher->data;

  my $buf = '';
  my $n = sysread($fh, $buf, 4096);

  if (!defined $n) {
    die "sysread: $!";
  }
  elsif ($n == 0) {
    die "EOF unexpectedly";
  }

  chomp $buf;
  say "IO read: $buf";
  $st->{got}++;

  $watcher->cancel;
  $loop->stop;

  return;
}

my $watcher = $loop->watch(
  $r,
  read => \&on_pipe_read,
  data => \%state,
);

$loop->after(0.030, sub ($loop) {
  syswrite($state{writer}, "hello-from-timer\n") or die "syswrite: $!";
});

$loop->run;

die "did not get IO callback" if !$state{got};
say "Done.";
