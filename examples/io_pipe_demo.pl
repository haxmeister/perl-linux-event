#!/usr/bin/env perl
use v5.36;

use lib "lib";
use Linux::Event::Loop;

# Loop mask bits: READABLE is 0x01 in Loop.pm
use constant READABLE => 0x01;

pipe(my $r, my $w) or die "pipe: $!";

# Make pipe ends autoflush-ish
select((select($w), $|=1)[0]);

my $loop = Linux::Event::Loop->new( backend => 'epoll' );

my $got = 0;

$loop->watch_fh($r, READABLE, sub ($loop, $fh, $fd, $mask, $tag) {
  my $buf = '';
  my $n = sysread($fh, $buf, 4096);

  if (!defined $n) {
    die "sysread: $!";
  }
  elsif ($n == 0) {
    die "EOF unexpectedly";
  }

  chomp $buf;
  say "IO callback read: $buf";
  $got++;

  $loop->unwatch_fh($fh);
  $loop->stop;
}, tag => 'pipe-read');

$loop->after_ms(30, sub ($loop, $id, $deadline_ns) {
  syswrite($w, "hello-from-timer\n") or die "syswrite: $!";
});

$loop->run;

die "did not get IO callback" if !$got;
say "Done.";
