package Linux::Event::Loop;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.100_024';

use parent 'Linux::Event::XSLoop';

1;

__END__

=head1 NAME

Linux::Event::Loop - Linux-native epoll event loop

=head1 SYNOPSIS

  use Linux::Event::Loop;

  my $loop = Linux::Event::Loop->new;
  $loop->add($watcher);
  $loop->run;

=head1 DESCRIPTION

This is the canonical public loop class. The implementation remains the
XS-first reactor previously exposed as L<Linux::Event::XSLoop>.

=cut
