#!/usr/bin/env perl
use v5.36;

use lib "lib";
use Linux::Event::Loop;

my $loop = Linux::Event::Loop->new;

$loop->after_ms(200, sub ($loop, $id, $deadline_ns) {
  say "A (+200ms)";
});

$loop->after_ms(50, sub ($loop, $id, $deadline_ns) {
  say "B (+50ms)";
});

my $cancel = $loop->after_ms(90, sub ($loop, $id, $deadline_ns) {
  say "SHOULD NOT RUN";
});
$loop->cancel($cancel);

$loop->after_ms(250, sub ($loop, $id, $deadline_ns) {
  say "Stopping";
  $loop->stop;
});

$loop->run;
