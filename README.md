[![CI](https://github.com/haxmeister/perl-linux-event/actions/workflows/ci.yml/badge.svg)](https://github.com/haxmeister/perl-linux-event/actions/workflows/ci.yml)

# Linux::Event

Linux-native event loop for Perl.

Linux::Event is a Linux-native event loop similar in role to EV or AnyEvent,
but designed specifically around modern Linux kernel facilities such as
epoll, timerfd, signalfd, eventfd, and pidfd. Providing a minimal event loop built on modern Linux kernel
facilities:

- epoll
- timerfd
- signalfd
- eventfd
- pidfd

The goal is a **small, explicit, composable foundation** for building
high-performance event-driven systems on Linux.

---------------------------------------------------------------------

## Linux::Event Ecosystem

The Linux::Event modules form a composable stack of small components
rather than a framework.

Each module has a narrow responsibility and can be combined with the
others to build servers, clients, and asynchronous systems.

Core layers:

Linux::Event
    The event loop. Linux-native readiness engine providing watchers
    and the dispatch loop.

Linux::Event::Listen
    Server-side socket acquisition (bind + listen + accept).
    Produces accepted nonblocking filehandles.

Linux::Event::Connect
    Client-side socket acquisition (nonblocking connect).
    Produces connected nonblocking filehandles.

Linux::Event::Stream
    Buffered I/O and backpressure management for an established
    filehandle.

Linux::Event::Fork
    Asynchronous child process management integrated with the event
    loop.

Linux::Event::Clock
    High-resolution monotonic time utilities.

Canonical network composition:

Listen / Connect
        ↓
      Stream
        ↓
  Application protocol

Example stack:

Linux::Event::Listen → Linux::Event::Stream → your protocol

or

Linux::Event::Connect → Linux::Event::Stream → your protocol

The core loop intentionally remains a primitive layer and does not grow
into a framework. Higher-level behavior is composed from small modules.

---------------------------------------------------------------------

## Design Goals

- Minimal public API
- Explicit semantics
- No hidden ownership
- Composable modules
- Linux-native performance
- Backend abstraction for future evolution

---------------------------------------------------------------------
## Keywords

event loop  
epoll  
async IO  
nonblocking IO  
reactor pattern  
network servers  
high performance networking  
Linux event loop

## Installation

Development install:

    perl Makefile.PL
    make
    make test
    make install

Requires:

    Linux
    Linux::Epoll
    Linux::Event::Clock >= 0.011
    Linux::Event::Timer >= 0.010

---------------------------------------------------------------------

## Basic Usage

    use v5.36;
    use Linux::Event;

    my $loop = Linux::Event->new;

    $loop->after(0.25, sub ($loop) {
        say "250ms elapsed";
        $loop->stop;
    });

    $loop->run;

---------------------------------------------------------------------

## Additional Linux primitives

Linux::Event integrates several Linux kernel facilities.

Signals via signalfd

    $loop->signal('INT', sub ($loop, $sig) {
        $loop->stop;
    });

Wakeups via eventfd

    my $w = $loop->wakeup(sub ($loop) {
        say "woken";
    });

Process exit notifications via pidfd

    $loop->pid($pid, sub ($loop, $pid, $status) {
        say "child exited";
    });

See the examples/ directory for complete scripts.

---------------------------------------------------------------------

## Example: TCP server

    use v5.36;
    use Linux::Event;
    use Linux::Event::Listen;
    use Linux::Event::Stream;

    my $loop = Linux::Event->new;

    Linux::Event::Listen->new(
        loop => $loop,
        host => '127.0.0.1',
        port => 3000,

        on_accept => sub ($loop, $fh, $peer, $listen) {

            Linux::Event::Stream->new(
                loop => $loop,
                fh   => $fh,

                codec => 'line',

                on_message => sub ($stream, $line) {
                    $stream->write_message("echo: $line");
                },
            );
        },
    );

$loop->run;

## License

Same terms as Perl itself.
