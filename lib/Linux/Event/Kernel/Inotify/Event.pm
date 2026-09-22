package Linux::Event::Kernel::Inotify::Event;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.116';

use File::Spec ();

use constant IN_ISDIR => 0x40000000;

sub _new ($class, $watch, $name, $mask, $cookie) {
    my $path = defined($name) && length($name)
        ? File::Spec->catfile($watch->path, $name)
        : $watch->path;
    return bless {
        watch  => $watch,
        name   => $name,
        path   => $path,
        mask   => $mask,
        cookie => $cookie,
    }, $class;
}

sub watch ($self) { $self->{watch} }
sub name ($self) { $self->{name} }
sub path ($self) { $self->{path} }
sub mask ($self) { $self->{mask} }
sub cookie ($self) { $self->{cookie} }
sub is_directory ($self) { !!($self->{mask} & IN_ISDIR) }

1;

__END__

=head1 NAME

Linux::Event::Kernel::Inotify::Event - immutable inotify event value

=head1 DESCRIPTION

The same Event object is supplied to every matching specific callback and the
final C<on_event> callback for one logical Watch and one kernel record.

=head1 METHODS

C<watch> returns the logical Watch. C<name> is the optional child name supplied
by Linux for a watched directory. C<path> is the useful composed path, or the
original watched path when no child name is present. C<mask> is the raw kernel
mask. C<cookie> preserves the Linux rename cookie. C<is_directory> reports the
C<IN_ISDIR> modifier.

=cut
