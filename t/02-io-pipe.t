use v5.36;
use strict;
use warnings;

use Test::More;

for my $m (qw(Linux::Epoll Linux::Event::Clock Linux::Event::Timer)) {
  eval "require $m; 1" or plan skip_all => "$m not available: $@";
}

use lib "lib";
use Linux::Event::Loop;

use constant READABLE => 0x01;

pipe(my $r, my $w) or die "pipe: $!";
select((select($w), $|=1)[0]);

my $loop = Linux::Event::Loop->new( backend => 'epoll' );

my $seen;

local $SIG{ALRM} = sub { die "timeout\n" };
alarm 3;

$loop->watch_fh($r, READABLE, sub ($loop, $fh, $fd, $mask, $tag) {
  my $buf = '';
  my $n = sysread($fh, $buf, 4096);
  ok(defined $n && $n > 0, "read from pipe");
  $seen = $buf;
  $loop->unwatch_fh($fh);
  $loop->stop;
}, tag => 'pipe');

$loop->after_ms(20, sub ($loop) {
  syswrite($w, "ok\n") or die "syswrite: $!";
});

$loop->run;

alarm 0;

is($seen, "ok\n", "saw payload");

done_testing;
