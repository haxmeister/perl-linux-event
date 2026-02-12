#!/usr/bin/env perl
use v5.36;

use lib "lib";
use Linux::Event;

my $loop = Linux::Event->new;

say "Scheduling timers...";

$loop->after(0.010, sub ($loop) { say "A (+0.010s)" });
$loop->after(0.050, sub ($loop) { say "B (+0.050s)" });

my $id = $loop->after(0.020, sub ($loop) { say "SHOULD NOT RUN" });
$loop->cancel($id);

$loop->after(0.120, sub ($loop) {
  say "Stopping";
  $loop->stop;
});

$loop->run;

say "Done.";
