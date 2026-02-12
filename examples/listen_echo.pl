#!/usr/bin/env perl
use v5.36;

use lib "lib";
use Linux::Event;

# Simple echo server using listen().
# Run: perl examples/listen_echo.pl
# Then: nc 127.0.0.1 5000

my $loop = Linux::Event->new;

my ($sock, $w_listen) = $loop->listen(
  type      => 'tcp4',
  host      => '0.0.0.0',
  port      => 5000,

  # defaults: reuseaddr=1, reuseport=0, max_accept=64
  reuseport => 1,   # allow multi-process scaling (optional)

  # For listening sockets, 'read' means: accept() will succeed.
  read => sub ($loop, $client, $listen_w) {

    # Watch the accepted client socket. Use $w->data to store per-connection state.
    my $w;
    $w = $loop->watch($client,
      read => sub ($loop, $fh, $w) {
        my $buf;
        my $n = sysread($fh, $buf, 4096);

        if (!defined $n) {
          return if $!{EAGAIN} || $!{EWOULDBLOCK};
          $w->cancel;
          close $fh;
          return;
        }

        if ($n == 0) { # EOF (HUP surfaces via readable)
          $w->cancel;
          close $fh;
          return;
        }

        syswrite($fh, $buf);
      },
    );
  },
);

say "Listening on 0.0.0.0:5000";
$loop->run;
