use v5.36;
use strict;
use warnings;

use Test::More;

my @mods = qw(
  Linux::Event
  Linux::Event::Loop
  Linux::Event::Scheduler
  Linux::Event::Backend
  Linux::Event::Backend::Epoll
);

for my $m (@mods) {
  ok(eval "require $m; 1", "load $m") or diag $@;
}

done_testing;
