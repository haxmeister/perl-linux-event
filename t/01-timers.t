use v5.36;
use strict;
use warnings;

use Test::More;

for my $m (qw(Linux::Epoll Linux::Event::Clock Linux::Event::Timer)) {
  eval "require $m; 1" or plan skip_all => "$m not available: $@";
}

use lib "lib";
use Linux::Event::Loop;

my $loop = Linux::Event::Loop->new( backend => 'epoll' );

my @order;

local $SIG{ALRM} = sub { die "timeout\n" };
alarm 3;

$loop->after_ms(30, sub ($loop) { push @order, 'B' });
$loop->after_ms(10, sub ($loop) { push @order, 'A' });

my $cancel = $loop->after_ms(20, sub ($loop) { push @order, 'X' });
ok($loop->cancel($cancel), "cancel works");

$loop->after_ms(60, sub ($loop) {
  push @order, 'STOP';
  $loop->stop;
});

$loop->run;

alarm 0;

is_deeply(\@order, [qw(A B STOP)], "timers fire in expected order and cancel works");

done_testing;
