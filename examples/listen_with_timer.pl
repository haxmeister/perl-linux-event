#!/usr/bin/env perl
use v5.36;

use lib "lib";
use Linux::Event;

# Echo server + periodic timer.
# Run: perl examples/listen_with_timer.pl

my $loop = Linux::Event->new;

# Periodic tick using after() re-scheduling itself.
my $tick; $tick = sub ($loop) {
  state $n = 0;
  $n++;
  say "tick $n";
  $loop->after(1.0, $tick);
};
$loop->after(1.0, $tick);

$loop->listen(
  type => 'tcp4',
  port => 5001,

  read => sub ($loop, $client, $listen_w) {
    $loop->watch($client,
      read => sub ($loop, $fh, $w) {
        my $buf;
        my $n = sysread($fh, $buf, 4096);

        if (!defined $n) {
          return if $!{EAGAIN} || $!{EWOULDBLOCK};
          $w->cancel;
          close $fh;
          return;
        }

        if ($n == 0) {
          $w->cancel;
          close $fh;
          return;
        }

        syswrite($fh, $buf);
      },
    );
  },
);

say "Listening on 0.0.0.0:5001 (echo) and ticking every 1s";
$loop->run;
