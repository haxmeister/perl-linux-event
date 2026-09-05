use v5.36;
use strict;
use warnings;

use POSIX qw(SIGUSR1);
use Scalar::Util qw(weaken);
use Test::More;

use Linux::Event::IO::Sock::Dgram;
use Linux::Event::Kernel::Event;
use Linux::Event::Kernel::Process;
use Linux::Event::Kernel::Signal;
use Linux::Event::Kernel::Timer;
use Linux::Event::Loop;

{
    package T::FirstClass::EventOverride;
    use parent 'Linux::Event::Kernel::Event';
    sub on_event ($self, $count) { die 'class Event callback should be overridden' }
}

{
    package T::FirstClass::TimerOverride;
    use parent 'Linux::Event::Kernel::Timer';
    sub on_timer ($self) { die 'class Timer callback should be overridden' }
}

subtest 'Event accepts and releases a constructor callback' => sub {
    my $loop = Linux::Event::Loop->new;
    my $total = 0;
    my $label = 'event';
    my $callback = sub ($event, $count) {
        $total += $count;
        is($label, 'event', 'Event callback retains lexical scope');
        $event->loop->stop;
    };
    my $weak = $callback;
    weaken($weak);
    my $event = T::FirstClass::EventOverride->new(
        loop => $loop, on_event => $callback,
    );
    undef $callback;
    ok(defined($weak), 'Event retains constructor callback while active');
    $event->signal(3);
    $loop->run;
    is($total, 3, 'constructor callback overrides Event class method');
    $event->cancel;
    ok(!defined($weak), 'Event cancellation releases constructor callback');
};

subtest 'Timer public leaf accepts and releases a constructor callback' => sub {
    my $loop = Linux::Event::Loop->new;
    my $fired = 0;
    my $callback = sub ($timer) {
        $fired++;
        $timer->loop->stop;
    };
    my $weak = $callback;
    weaken($weak);
    my $timer = Linux::Event::Kernel::Timer->new(
        loop => $loop, after => 0, on_timer => $callback,
    );
    undef $callback;
    ok(defined($weak), 'Timer retains constructor callback while active');
    $loop->run;
    is($fired, 1, 'public Timer leaf invokes constructor callback');
    ok($timer->is_terminal, 'one-shot Timer completes after callback');
    ok(!defined($weak), 'completed Timer releases constructor callback');

    my $override_loop = Linux::Event::Loop->new;
    my $override = T::FirstClass::TimerOverride->new(
        loop => $override_loop,
        after => 0,
        on_timer => sub ($object) { $object->loop->stop },
    );
    $override_loop->run;
    ok($override->is_terminal, 'constructor callback overrides Timer method');
};

subtest 'Signal public leaf accepts and releases a constructor callback' => sub {
    my $loop = Linux::Event::Loop->new;
    my @seen;
    my $callback = sub ($signal, $number, $count) {
        push @seen, [$number, $count];
        $signal->loop->stop;
    };
    my $weak = $callback;
    weaken($weak);
    my $signal = Linux::Event::Kernel::Signal->new(
        loop => $loop, signals => SIGUSR1, on_signal => $callback,
    );
    undef $callback;
    ok(defined($weak), 'Signal retains constructor callback while active');
    kill SIGUSR1, $$ or die "kill SIGUSR1: $!";
    $loop->run;
    is_deeply(\@seen, [[SIGUSR1, 1]],
        'public Signal leaf invokes constructor callback');
    $signal->cancel;
    ok(!defined($weak), 'Signal cancellation releases constructor callback');
};

subtest 'Process constructor callbacks cover output and exit' => sub {
    my $loop = Linux::Event::Loop->new;
    my $output = '';
    my $exit_code;
    my $stdout = sub ($process, $bytes) { $output .= $bytes };
    my $exit = sub ($process) {
        $exit_code = $process->exit_code;
        $process->loop->stop;
    };
    my ($weak_stdout, $weak_exit) = ($stdout, $exit);
    weaken($weak_stdout);
    weaken($weak_exit);
    my $process = Linux::Event::Kernel::Process->spawn(
        loop => $loop,
        command => [$^X, '-e', 'print "callback output\\n"; exit 4'],
        stdout => 'pipe',
        on_stdout => $stdout,
        on_exit => $exit,
    );
    undef $stdout;
    undef $exit;
    ok(defined($weak_stdout) && defined($weak_exit),
        'Process retains constructor callbacks while running');
    $loop->run;
    is($exit_code, 4, 'constructor on_exit sees decoded status');
    is($output, "callback output\n",
        'public Process leaf invokes constructor output callback');
    ok(!defined($weak_stdout) && !defined($weak_exit),
        'completed Process releases constructor callbacks');
};

subtest 'Datagram public leaf accepts constructor callbacks' => sub {
    my $loop = Linux::Event::Loop->new;
    my $received;
    my $server_callback = sub ($socket, $payload, $peer) {
        $received = $payload;
        $socket->loop->stop;
    };
    my $weak = $server_callback;
    weaken($weak);
    my $server = Linux::Event::IO::Sock::Dgram->new(
        loop => $loop,
        host => '127.0.0.1',
        port => 0,
        on_datagram => $server_callback,
    );
    my $client = Linux::Event::IO::Sock::Dgram->connect(
        loop => $loop,
        host => '127.0.0.1',
        port => $server->local->port,
        on_datagram => sub { },
        on_ready => sub ($socket) { $socket->send('packet') },
    );
    undef $server_callback;
    ok(defined($weak), 'Datagram retains constructor callback while active');
    $loop->run;
    is($received, 'packet', 'public Datagram leaf receives one complete packet');
    $client->close;
    $server->close;
    ok(!defined($weak), 'Datagram close releases constructor callback');
};

done_testing;
