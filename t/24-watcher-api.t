use v5.36;
use strict;
use warnings;
use Test::More;

use Linux::Event::Loop;
use Linux::Event::Watcher;
use Linux::Event::IO;

{
    package T::DetachedWatcher;
    use parent 'Linux::Event::Watcher';

    sub new ($class) { bless { loop => undef, terminal => 0 }, $class }
    sub loop ($self) { $self->{loop} }
    sub is_terminal ($self) { $self->{terminal} }
    sub _attach_to_loop ($self, $loop) {
        die 'watcher is already attached' if $self->{loop};
        die 'terminal watcher cannot be attached' if $self->{terminal};
        $self->{loop} = $loop;
        return $self;
    }
}

my $loop = Linux::Event::Loop->new;
isa_ok($loop, 'Linux::Event::XSLoop');

my $source = T::DetachedWatcher->new;
is($loop->add($source), $source, 'add returns the same Watcher');
is($source->loop, $loop, 'add establishes loop ownership');
like(exception(sub { $loop->add($source) }), qr/already attached/,
    'adding one Watcher twice is rejected');

pipe(my $reader, my $writer) or die "pipe: $!";
my $io = $loop->watch(fh => $reader, read => sub ($watcher) { });
isa_ok($io, 'Linux::Event::IO');
isa_ok($io, 'Linux::Event::Watcher');
isa_ok($io, 'Linux::Event::XSWatcher');
is($io->loop, $loop, 'watch immediately attaches the raw IO Watcher');
$io->cancel;
close $reader;
close $writer;

like(exception(sub { $loop->add(bless {}, 'T::NotAWatcher') }),
    qr/Linux::Event::Watcher/, 'add rejects unrelated objects');

my $terminal = T::DetachedWatcher->new;
$terminal->{terminal} = 1;
like(exception(sub { $loop->add($terminal) }), qr/terminal watcher/,
    'add rejects terminal Watchers');

done_testing;

sub exception ($code) {
    my $error = '';
    eval { $code->(); 1 } or $error = $@;
    return $error;
}
