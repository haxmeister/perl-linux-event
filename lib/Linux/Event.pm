package Linux::Event;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.001_001';

use Linux::Event::Loop;

sub new ($class, %args) {
  return Linux::Event::Loop->new(%args);
}

1;

__END__

=head1 NAME

Linux::Event - Front door for the Linux::Event ecosystem

=head1 SYNOPSIS

  use v5.36;
  use Linux::Event;

  my $loop = Linux::Event->new( backend => 'epoll' );

  $loop->after_ms(100, sub ($loop) {
    say "tick";
    $loop->stop;
  });

  $loop->run;

=head1 DESCRIPTION

C<Linux::Event> is a Linux-focused event loop ecosystem. This distribution
currently provides the loop and backend boundary, plus a scheduler.

This is an early development release.

=head1 STATUS

B<EXPERIMENTAL / WORK IN PROGRESS>

The API is not yet considered stable and may change without notice. This release
is intended for early testing and feedback and is not recommended for production
use.

=head1 REPOSITORY

The project repository is hosted on GitHub:

L<https://github.com/haxmeister/perl-linux-event>


=head1 SEE ALSO

L<Linux::Event::Loop>, L<Linux::Event::Backend>, L<Linux::Event::Scheduler>

=cut
