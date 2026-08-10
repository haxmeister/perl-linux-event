use v5.36;
use strict;
use warnings;
use Test::More;
use Time::HiRes qw(time);
use Linux::Event::XSLoop;

my $loop = Linux::Event::XSLoop->new;
pipe(my $r, my $w) or die "pipe: $!";
my $hit = 0;
my $watcher;
$watcher = $loop->watch_fd(fileno($r), fh => $r, callback_args => 0, lean => 1, read => sub {
    sysread($r, my $buf, 1);
    $hit++;
    $watcher->cancel;
    $loop->stop;
});
syswrite($w, "x");
my $t0 = time;
$loop->run_for(1.0);
my $elapsed = time - $t0;
is($hit, 1, 'run_for dispatches callback and stop exits persistent loop');
ok($elapsed < 0.5, 'stop exits run_for before deadline');
my $st = $loop->stats;
is($st->{run_for_calls}, 1, 'run_for entered persistent native loop once');
is($st->{run_once_calls}, 0, 'run_for did not bounce through run_once');

my $idle = Linux::Event::XSLoop->new;
$t0 = time;
$idle->run_for(0.02);
$elapsed = time - $t0;
ok($elapsed >= 0.005, 'run_for waits for native deadline when idle');
ok($elapsed < 0.5, 'run_for native deadline returns promptly');

done_testing;
