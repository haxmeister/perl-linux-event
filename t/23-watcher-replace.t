use v5.36;
use strict;
use warnings;
use Test::More;

use Linux::Event::XSLoop;

pipe(my $read_fh, my $write_fh) or die "pipe: $!";
my $loop = Linux::Event::XSLoop->new;
my $old_calls = 0;
my $new_calls = 0;

my $old = $loop->watch(
    fh   => $read_fh,
    read => sub ($watcher) { $old_calls++ },
);

$loop->reset_stats;
my $new = $loop->watch(
    fh   => $read_fh,
    read => sub ($watcher) {
        sysread($watcher->fh, my $bytes, 16);
        $new_calls++;
        $loop->stop;
    },
);

my $replace_stats = $loop->stats;
is($replace_stats->{epoll_ctl_mod_calls}, 1,
    'same-fd watcher replacement uses one epoll MOD');
is($replace_stats->{epoll_ctl_del_calls}, 0,
    'same-fd watcher replacement does not delete registration');
is($replace_stats->{epoll_ctl_add_calls}, 0,
    'same-fd watcher replacement does not add registration again');

$old->cancel;
syswrite($write_fh, 'x');
$loop->run;
is($old_calls, 0, 'replaced watcher is inert');
is($new_calls, 1, 'cancelling replaced handle does not remove new watcher');

$new->cancel;
close $read_fh;
close $write_fh;

done_testing;
