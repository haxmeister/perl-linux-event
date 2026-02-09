#!/usr/bin/env perl
use v5.36;

use lib "lib";
use Linux::Event::Loop;

my $loop = Linux::Event::Loop->new( backend => 'epoll' );

say "Scheduling...";

$loop->after_ms(50, sub ($loop, $id, $deadline_ns) {
  say "B (+50ms)";
});

$loop->after_ms(10, sub ($loop, $id, $deadline_ns) {
  say "A (+10ms)";
});

my $cancel = $loop->after_ms(20, sub ($loop, $id, $deadline_ns) {
  say "SHOULD NOT RUN";
});
$loop->cancel($cancel);

$loop->after_ms(120, sub ($loop, $id, $deadline_ns) {
  say "Stopping";
  $loop->stop;
});

$loop->run;

say "Done.";
