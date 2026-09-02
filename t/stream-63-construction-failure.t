use v5.36;
use strict;
use warnings;
use Test::More;
use Scalar::Util qw(weaken);

use Linux::Event::Loop;
use Linux::Event::Stream;

{
    package T::FailingRegistrationLoop;
    use parent 'Linux::Event::Loop';
    sub watch_fd ($loop, @args) {
        die "synthetic watcher registration failure\n";
    }
}

{
    package T::RegistrationFailure;
    use parent 'Linux::Event::Stream';
    our $constructed;

    sub on_data ($stream, $bytes) { return }

    sub _prepare_handles ($self) {
        $self->SUPER::_prepare_handles;
        $constructed = $self;
        Scalar::Util::weaken($constructed);
        return;
    }
}

pipe(my $read_fh, my $write_fh) or die "pipe: $!";
my $loop = T::FailingRegistrationLoop->new;
my $ok = eval {
    T::RegistrationFailure->new(loop => $loop, read_fh => $read_fh);
    1;
};

ok(!$ok, 'constructor reports watcher registration failure');
like($@, qr/synthetic watcher registration failure/,
    'registration failure preserves its diagnostic');
ok(!defined($T::RegistrationFailure::constructed),
    'failed constructor breaks the Stream and XSState ownership cycle');
ok(!defined(fileno($read_fh)), 'failed constructor closes its owned handle');
is($loop->resources->{registered_fds}, 0,
    'failed constructor strands no epoll registration');

close $write_fh;
done_testing;
