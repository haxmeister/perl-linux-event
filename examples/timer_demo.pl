#!/usr/bin/env perl
use v5.36;

use lib "lib";
use Linux::Event::Loop;

my $loop = Linux::Event::Loop->new( backend => 'epoll' );

say "Scheduling...";

$loop->after(0.050, sub ($loop) {
  say "B (+0.050s)";
});

$loop->after(0.010, sub ($loop) {
  say "A (+0.010s)";
});

my $cancel = $loop->after(0.020, sub ($loop) {
  say "SHOULD NOT RUN";
});
$loop->cancel($cancel);

$loop->after(0.120, sub ($loop) {
  say "Stopping";
  $loop->stop;
});

$loop->run;

say "Done.";
