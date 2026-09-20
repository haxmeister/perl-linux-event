use v5.36;
use strict;
use warnings;

use Test::More;

use Linux::Event::Loop;
use Linux::Event::Kernel::Timer;

sub poll_fh ($loop) {
    my $fd = $loop->poll_fd;
    open my $fh, '<&', $fd
        or die "dup poll_fd $fd failed: $!";
    return $fh;
}

sub le_timer ($loop, $callback) {
    return Linux::Event::Kernel::Timer->new(
        loop => $loop,
        after => 0.01,
        on_timer => $callback,
    );
}

subtest 'EV drives Linux::Event' => sub {
    eval { require EV; 1 }
        or plan skip_all => 'EV is not installed';

    my $loop = Linux::Event::Loop->new;
    my $fh = poll_fh($loop);
    my $seen = 0;
    my $timed_out = 0;

    my $watcher = EV::io($fh, EV::READ(), sub { $loop->poll });
    my $guard = EV::timer(5, 0, sub {
        $timed_out = 1;
        EV::break(EV::BREAK_ALL());
    });
    my $timer = le_timer($loop, sub {
        $seen++;
        EV::break(EV::BREAK_ALL());
    });

    EV::run();

    ok(!$timed_out, 'EV did not need its watchdog');
    is($seen, 1, 'EV readability callback drove Linux::Event Timer');
    close $fh;
};

subtest 'AnyEvent drives Linux::Event' => sub {
    eval { require AnyEvent; 1 }
        or plan skip_all => 'AnyEvent is not installed';

    my $loop = Linux::Event::Loop->new;
    my $fh = poll_fh($loop);
    my $seen = 0;
    my $timed_out = 0;
    my $cv = AnyEvent->condvar;

    my $watcher = AnyEvent->io(
        fh => $fh,
        poll => 'r',
        cb => sub { $loop->poll },
    );
    my $guard = AnyEvent->timer(
        after => 5,
        cb => sub {
            $timed_out = 1;
            $cv->send;
        },
    );
    my $timer = le_timer($loop, sub {
        $seen++;
        $cv->send;
    });

    $cv->recv;

    ok(!$timed_out, 'AnyEvent did not need its watchdog');
    is($seen, 1, 'AnyEvent readability callback drove Linux::Event Timer');
    close $fh;
};

subtest 'IO::Async drives Linux::Event' => sub {
    eval {
        require IO::Async::Loop;
        require IO::Async::Timer::Countdown;
        1;
    } or plan skip_all => 'IO::Async is not installed';

    my $loop = Linux::Event::Loop->new;
    my $fh = poll_fh($loop);
    my $seen = 0;
    my $timed_out = 0;
    my $foreign = IO::Async::Loop->new;

    $foreign->watch_io(
        handle => $fh,
        on_read_ready => sub { $loop->poll },
    );

    my $guard = IO::Async::Timer::Countdown->new(
        delay => 5,
        on_expire => sub {
            $timed_out = 1;
            $foreign->loop_stop;
        },
    );
    $foreign->add($guard);
    $guard->start;

    my $timer = le_timer($loop, sub {
        $seen++;
        $foreign->loop_stop;
    });

    $foreign->loop_forever;

    ok(!$timed_out, 'IO::Async did not need its watchdog');
    is($seen, 1, 'IO::Async readability callback drove Linux::Event Timer');

    $foreign->unwatch_io(handle => $fh, on_read_ready => 1);
    close $fh;
};

subtest 'Mojo drives Linux::Event' => sub {
    eval { require Mojo::Reactor::Poll; 1 }
        or plan skip_all => 'Mojolicious is not installed';

    my $loop = Linux::Event::Loop->new;
    my $fh = poll_fh($loop);
    my $seen = 0;
    my $timed_out = 0;
    my $foreign = Mojo::Reactor::Poll->new;

    $foreign->io($fh => sub ($reactor, $writable) {
        $loop->poll if !$writable;
    })->watch($fh, 1, 0);

    my $guard = $foreign->timer(5 => sub {
        $timed_out = 1;
        $foreign->stop;
    });
    my $timer = le_timer($loop, sub {
        $seen++;
        $foreign->stop;
    });

    $foreign->start;

    ok(!$timed_out, 'Mojo did not need its watchdog');
    is($seen, 1, 'Mojo readability callback drove Linux::Event Timer');

    $foreign->remove($fh);
    close $fh;
};

done_testing;
