use v5.36;
use Test::More;
use_ok('Linux::Event::XSLoop');
my $loop = Linux::Event::XSLoop->new;
ok($loop, 'created loop');
done_testing;
