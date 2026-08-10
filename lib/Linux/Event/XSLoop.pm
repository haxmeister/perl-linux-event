package Linux::Event::XSLoop;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.001';

require XSLoader;
XSLoader::load(__PACKAGE__, $VERSION);

1;

__END__

=head1 NAME

Linux::Event::XSLoop - internal XS-first Linux::Event loop core

=head1 SYNOPSIS

  my $loop = Linux::Event::XSLoop->new;

  my $watcher = $loop->watch_fd(
      fileno($fh),
      fh    => $fh,
      read  => sub ($w) { ... },
      write => sub ($w) { ... },
      error => sub ($w) { ... },
      data  => $anything,
  );

  $loop->run;

=head1 STATUS

Internal Phase35 XS-first loop core. Normal users should not need to choose
benchmark-era tuning knobs such as event capacity, drain mode, profiling,
lean watcher storage, or watcher reclaim. The public API should prefer safe,
fast defaults.

Experimental tuning methods may remain available for benchmarks and regression
investigation, but they are not intended as normal application options.

=cut
