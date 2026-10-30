use v5.36;
use strict;
use warnings;

use Test::More;
use POSIX ();
use IO::Socket::INET;
use Linux::Event::Loop;
use Linux::Event::IO::Sock::Listener;

sub listener_for ($loop, $accepted_ref) {
    return Linux::Event::IO::Sock::Listener->new(
        loop => $loop,
        host => '127.0.0.1',
        port => 0,
        stream => { on_data => sub { } },
        on_accept => sub ($listener, $stream) {
            $$accepted_ref++;
            $stream->close;
        },
    );
}

sub client_for ($listener) {
    return IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $listener->port,
        Proto => 'tcp',
        Timeout => 3,
    ) or die "connect failed: $!";
}

{
    local $ENV{LINUX_EVENT_EXPERIMENT_EPOLLEXCLUSIVE};
    my $loop = Linux::Event::Loop->new;
    my $accepted = 0;
    my $listener = listener_for($loop, \$accepted);
    is($listener->{experimental_exclusive}, 0, 'ordinary Listener remains default');
    $listener->pause;
    $listener->resume;
    my $client = client_for($listener);
    $loop->run_for(0.15);
    is($accepted, 1, 'ordinary Listener still accepts after pause/resume');
    close $client;
    $listener->close;
}

{
    local $ENV{LINUX_EVENT_EXPERIMENT_EPOLLEXCLUSIVE} = 1;
    my $loop = Linux::Event::Loop->new;
    my $accepted = 0;
    my $listener = listener_for($loop, \$accepted);
    is($listener->{experimental_exclusive}, 1, 'opted-in Listener uses experiment');
    $listener->pause;
    is($listener->state, 'paused', 'exclusive Listener pauses without illegal MOD');
    my $queued = client_for($listener);
    $loop->run_for(0.04);
    is($accepted, 0, 'paused exclusive Listener does not accept');
    $listener->resume;
    is($listener->state, 'listening', 'exclusive Listener resumes via ADD');
    $loop->run_for(0.15);
    is($accepted, 1, 'exclusive Listener accepts pending connection on resume');
    $listener->pause;
    $listener->resume;
    $listener->pause;
    $listener->resume;
    my $second = client_for($listener);
    $loop->run_for(0.15);
    is($accepted, 2, 'repeated exclusive pause/resume continues accepting');
    close $queued;
    close $second;
    $listener->close;
    ok($listener->is_terminal, 'exclusive Listener closes from active registration');
}

{
    local $ENV{LINUX_EVENT_EXPERIMENT_EPOLLEXCLUSIVE} = 1;
    my $loop = Linux::Event::Loop->new;
    my $accepted = 0;
    my $listener = listener_for($loop, \$accepted);
    $listener->pause;
    $listener->close;
    ok($listener->is_terminal, 'exclusive Listener closes from suspended registration');
}

{
    local $ENV{LINUX_EVENT_EXPERIMENT_EPOLLEXCLUSIVE} = 1;
    my $loop = Linux::Event::Loop->new;
    my $accepted = 0;
    my $listener = listener_for($loop, \$accepted);
    $listener->pause;

    pipe(my $report_read, my $report_write) or die "report pipe: $!";
    my $pid = $loop->fork(share => [$listener]);
    if (!defined $pid) {
        die "managed fork failed: $!";
    }
    if ($pid == 0) {
        close $report_read;
        my $ready = $listener->is_paused && $loop->has($listener);
        $listener->resume;
        my $active = $listener->state eq 'listening';
        $loop->run_for(0.35);
        syswrite($report_write, join(':', $ready ? 1 : 0,
                                          $active ? 1 : 0, $accepted));
        close $report_write;
        $listener->close;
        POSIX::_exit($ready && $active ? 0 : 1);
    }

    close $report_write;
    ok($listener->is_paused, 'parent preserved paused Listener after fork');
    $listener->resume;
    my $client = client_for($listener);
    $loop->run_for(0.4);
    my $written = sysread($report_read, my $report, 100);
    ok(defined($written) && $written > 0, 'child reported shared-listener state');
    my ($ready, $active, $child_accepted) = split /:/, ($report // '');
    is($ready, 1, 'child inherited suspended Listener state');
    is($active, 1, 'child re-registered exclusive Listener on resume');
    is($accepted + ($child_accepted // 0), 1,
       'one connection accepted by one of the shared workers');
    is(waitpid($pid, 0), $pid, 'child reaped');
    is($? >> 8, 0, 'shared Listener child exited successfully');
    close $client;
    close $report_read;
    $listener->close;
}


{
    local $ENV{LINUX_EVENT_EXPERIMENT_EPOLLEXCLUSIVE} = 1;
    my $loop = Linux::Event::Loop->new;
    my $accepted = 0;
    my $listener = listener_for($loop, \$accepted);
    pipe(my $report_read, my $report_write) or die "defer_fork pipe: $!";

    my ($pid, $requested_inside_dispatch, $parent_quiescent, $request);
    $loop->defer(sub {
        $requested_inside_dispatch = $loop->running;
        $request = $loop->defer_fork(
            share => [$listener],
            on_child => sub {
                close $report_read;
                my $ok = !$loop->running && $listener->is_running
                    && $loop->has($listener)
                    && $listener->{experimental_exclusive};
                $listener->pause;
                $listener->resume;
                $ok &&= $listener->state eq 'listening';
                syswrite($report_write, $ok ? 'Y' : 'N');
                close $report_write;
                POSIX::_exit($ok ? 0 : 1);
            },
            on_parent => sub ($child_pid) {
                $pid = $child_pid;
                $parent_quiescent = !$loop->running;
                $loop->stop;
            },
        );
    });
    $loop->run;
    ok($requested_inside_dispatch, 'deferred exclusive fork requested during dispatch');
    ok($parent_quiescent, 'exclusive fork parent callback runs outside dispatch');
    ok($pid > 0, 'deferred exclusive fork created child');
    ok(!$request->is_active, 'deferred exclusive fork handle consumed');
    close $report_write;
    is(sysread($report_read, my $result, 1), 1, 'deferred child status received');
    is($result, 'Y', 'deferred child can pause/resume exclusive shared Listener');
    is(waitpid($pid, 0), $pid, 'deferred child reaped');
    is($? >> 8, 0, 'deferred child passed');
    close $report_read;
    $listener->close;
}


subtest 'reject replacing exclusive registration without disturbing it' => sub {
    local $ENV{LINUX_EVENT_EXPERIMENT_EPOLLEXCLUSIVE} = 1;
    my $loop = Linux::Event::Loop->new;
    my $accepted = 0;
    my $listener = listener_for($loop, \$accepted);

    for my $paused (0, 1) {
        $listener->pause if $paused;
        my $old_state = $listener->state;
        my $replaced = eval {
            $loop->watch(fd => $listener->fd, read => sub { });
            1;
        };
        ok(!$replaced, "replacement rejected while $old_state");
        like($@, qr/experimental exclusive watchers cannot replace/,
            'replacement rejection has specific error');
        is($listener->state, $old_state, 'failed replacement retains Listener state');
        ok($loop->has($listener), 'failed replacement keeps original Listener attached');
    }

    $listener->resume;
    my $client = client_for($listener);
    $loop->run_for(0.12);
    is($accepted, 1, 'exclusive Listener still accepts after rejected replacements');
    close $client;
    $listener->close;
};

subtest 'detach suspended Listener and adopt its filehandle' => sub {
    local $ENV{LINUX_EVENT_EXPERIMENT_EPOLLEXCLUSIVE} = 1;
    my $loop = Linux::Event::Loop->new;
    my $accepted = 0;
    my $listener = listener_for($loop, \$accepted);
    my $port = $listener->port;
    $listener->pause;
    my $fh = $listener->detach;
    ok($listener->is_terminal, 'suspended original Listener becomes detached');
    ok(defined($fh) && defined(fileno($fh)), 'detached socket remains open');

    my $new_accepted = 0;
    my $adopted = Linux::Event::IO::Sock::Listener->new(
        loop => $loop,
        fh => $fh,
        owns_socket => 1,
        stream => { on_data => sub { } },
        on_accept => sub ($server, $stream) {
            $new_accepted++;
            $stream->close;
        },
    );
    is($adopted->port, $port, 'new Listener retains existing port');
    my $client = client_for($adopted);
    $loop->run_for(0.12);
    is($new_accepted, 1, 're-adopted socket accepts under exclusive registration');
    is($accepted, 0, 'detached Listener receives no callbacks');
    close $client;
    $adopted->close;
    ok($adopted->is_terminal, 'adopted Listener closes');
};

subtest 'preflight refusal leaves exclusive Listener live' => sub {
    local $ENV{LINUX_EVENT_EXPERIMENT_EPOLLEXCLUSIVE} = 1;
    my $loop = Linux::Event::Loop->new;
    my $accepted = 0;
    my $listener = listener_for($loop, \$accepted);
    my $ok = eval { $loop->fork(clone => [$listener]); 1 };
    ok(!$ok, 'unsupported Listener clone refused before fork');
    like($@, qr/Listener does not support 'clone'/, 'fork preflight explains invalid disposition');
    ok($listener->is_running && $loop->has($listener), 'exclusive Listener remains registered');
    my $client = client_for($listener);
    $loop->run_for(0.12);
    is($accepted, 1, 'exclusive Listener continues accepting after preflight error');
    close $client;
    $listener->close;
};

subtest 'failed child reconstruction does not change parent watcher' => sub {
    local $ENV{LINUX_EVENT_EXPERIMENT_EPOLLEXCLUSIVE} = 1;
    my $loop = Linux::Event::Loop->new;
    my $accepted = 0;
    my $listener = listener_for($loop, \$accepted);
    my ($ok, $error);
    {
        no warnings 'redefine';
        local *Linux::Event::_Socket::Listener::_fork_child_share = sub {
            die "injected exclusive child failure\n";
        };
        $ok = eval { $loop->fork(share => [$listener]); 1 };
        $error = $@;
    }
    ok(!$ok, 'failed child reconstruction aborts managed fork');
    like($error, qr/injected exclusive child failure/,
        'child reconstruction error propagated to parent');
    ok($listener->is_running && $loop->has($listener),
        'failed fork leaves parent exclusive Listener active');
    my $client = client_for($listener);
    $loop->run_for(0.12);
    is($accepted, 1, 'parent still accepts after child reconstruction failure');
    close $client;
    $listener->close;
};

subtest 'closing Listener inside on_accept does not use stale watcher' => sub {
    local $ENV{LINUX_EVENT_EXPERIMENT_EPOLLEXCLUSIVE} = 1;
    my $loop = Linux::Event::Loop->new;
    my $accepted = 0;
    my $listener = Linux::Event::IO::Sock::Listener->new(
        loop => $loop,
        host => '127.0.0.1',
        port => 0,
        stream => { on_data => sub { } },
        on_accept => sub ($server, $stream) {
            $accepted++;
            $stream->close;
            $server->close;
        },
    );
    my $first = client_for($listener);
    my $second = client_for($listener);
    $loop->run_for(0.12);
    is($accepted, 1, 'only first batch callback is delivered after shutdown');
    ok($listener->is_terminal, 'Listener closed during callback');
    $loop->poll;
    pass('Loop is still safely driveable after callback-triggered shutdown');
    close $first;
    close $second;
};

done_testing;
