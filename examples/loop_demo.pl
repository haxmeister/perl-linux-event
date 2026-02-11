#!/usr/bin/env perl
use v5.36;

use lib "lib";
use Linux::Event::Loop;

my $loop = Linux::Event::Loop->new;

$loop->after(0.200, sub ($loop) {
  say "A (+0.200s)";
});

$loop->after(0.050, sub ($loop) {
  say "B (+0.050s)";
});

my $cancel = $loop->after(0.090, sub ($loop) {
  say "SHOULD NOT RUN";
});
$loop->cancel($cancel);

$loop->after(0.250, sub ($loop) {
  say "Stopping";
  $loop->stop;
});

$loop->run;
