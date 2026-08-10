use v5.36;
use Test::More;
use IO::Handle;
use Linux::Event::XSLoop;

pipe(my $r, my $w) or die $!;
$r->blocking(0);
$w->blocking(0);

my $loop = Linux::Event::XSLoop->new;
my $argc = -1;
my $watcher = $loop->watch_fd(
    fileno($r),
    fh => $r,
    callback_args => 0,
    read => sub {
        $argc = scalar @_;
        sysread($r, my $buf, 1);
        $loop->stop;
    },
);

syswrite($w, 'x');
$loop->run;

is($argc, 0, 'callback_args => 0 invokes callback with no args');
my $st = $loop->stats;
is($st->{callback_noarg_calls}, 1, 'no-arg callback counted');
is($st->{callback_onearg_calls}, 0, 'one-arg callback not counted');

done_testing;
