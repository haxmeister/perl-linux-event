use v5.36;
use strict;
use warnings;
use Test::More;
use File::Temp ();
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC SOL_SOCKET SO_SNDBUF);

use Linux::Event::Loop;
use Linux::Event::IO::Sock::Stream;

{
    package T::SendfileTimeout;
    use parent 'Linux::Event::IO::Sock::Stream';
    sub on_data ($self, $bytes) { }
    sub on_error ($self, $err) {
        push @{ $self->data->{errors} }, $err;
        $self->data->{loop}->stop;
    }
    sub on_close ($self) { $self->data->{closes}++ }
}

sub fd_count () {
    opendir(my $dir, '/proc/self/fd') or die "opendir /proc/self/fd: $!";
    my $count = scalar grep { /^\d+$/ } readdir($dir);
    closedir($dir);
    return $count;
}

{
    socketpair(my $out, my $peer, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
        or die "socketpair: $!";
    setsockopt($out, SOL_SOCKET, SO_SNDBUF, pack('i', 4096))
        or die "setsockopt: $!";
    my $loop = Linux::Event::Loop->new;
    my $state = { loop => $loop, errors => [], closes => 0 };
    my $writer = T::SendfileTimeout->new(
        loop => $loop, fh => $out, data => $state,
        write_timeout => 0.2,
    );
    my $fh = File::Temp->new(UNLINK => 1);
    binmode($fh);
    for (1 .. 64) {
        my $written = syswrite($fh, 'x' x 65536);
        die "syswrite: $!" if !defined($written) || $written != 65536;
    }
    seek($fh, 0, 0) or die "seek: $!";

    my $baseline_fds = fd_count();
    $writer->sendfile($fh);
    ok($writer->pending_bytes > 0,
        'stalled file transfer participates in native queued output');
    is(fd_count(), $baseline_fds + 1, 'queued transfer owns source fd');
    $loop->run_for(1);
    ok($writer->is_closed, 'write inactivity timeout terminates stalled sendfile');
    is(scalar @{ $state->{errors} }, 1, 'one write timeout error emitted');
    is($state->{errors}[0]->type, 'timeout', 'normal timeout error type');
    is($state->{errors}[0]->operation, 'write',
        'sendfile stall uses existing write timeout operation');
    is($state->{closes}, 1, 'stalled transfer closes exactly once');
    is(fd_count(), $baseline_fds - 1,
        'timeout closes duplicated source fd and underlying socket');
    close $peer;
    close $fh;
}

done_testing;
