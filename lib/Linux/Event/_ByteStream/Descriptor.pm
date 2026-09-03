package Linux::Event::_ByteStream::Descriptor;
use v5.36;
use strict;
use warnings;

our $VERSION = '0.105';

use Carp qw(croak);
use mro ();

# Private descriptor storage belongs to byte-stream behavior rather than to a
# public Stream class name. The old Stream::_Descriptor package forwards here
# during the namespace migration.
my %FRAMER_DEFINITION;
my %CONSUMER_DEFINITION;
my %CLASS_DESCRIPTOR;

my @XS_SPEC_FIELD = qw(
    read_size read_budget_bytes read_batch_bytes message_batch_size
    high_watermark low_watermark max_pending_bytes max_buffer read_mode
    deliver_cb message_cb message_batch_cb drain_cb eof_cb read_error_cb
    write_error_cb output_limit_cb write_empty_cb framing_error_cb delimiter
    include_delimiter max_frame fixed_size prefix_bytes prefix_little
    include_prefix consumer_provider consumer_abi_version
    consumer_ops_address
);
my %XS_SPEC_FIELD = map { $_ => 1 } @XS_SPEC_FIELD;

# The public class declaration path already validates Stream/framer/consumer
# policy. This last cold step owns only the private XS specification contract:
# reject misspelled or incomplete fields and normalize scalar representation.
# The native constructor retains parser-memory and consumer-table checks as
# defensive backstops before storing pointers or parser configuration.
sub _validate_xs_spec ($spec) {
    croak 'XSDescriptor::new requires a hash reference'
        if ref($spec) ne 'HASH';
    my @unknown = grep { !$XS_SPEC_FIELD{$_} } keys %$spec;
    croak "unknown Stream descriptor field '$unknown[0]'"
        if @unknown == 1;
    croak 'unknown Stream descriptor fields: ' . join(', ', sort @unknown)
        if @unknown;
    for my $field (@XS_SPEC_FIELD) {
        croak "missing Stream descriptor field '$field'"
            if !exists $spec->{$field};
    }

    my %normalized = %$spec;
    $normalized{$_} = $normalized{$_} ? 1 : 0
        for qw(include_delimiter prefix_little include_prefix);
    $normalized{$_} = defined($normalized{$_}) ? 0 + $normalized{$_} : 0
        for qw(
            read_size read_budget_bytes read_batch_bytes message_batch_size
            high_watermark low_watermark max_pending_bytes max_buffer
            read_mode fixed_size prefix_bytes consumer_abi_version
            consumer_ops_address
        );

    return \%normalized;
}

sub declare_framer ($base, $target, $definition) {
    croak 'a framer may be declared only for a Linux::Event::Stream subclass'
        if $target eq $base || !$target->isa($base);
    croak "$target already has a Stream descriptor"
        if exists $CLASS_DESCRIPTOR{$target};
    croak "$target already declares a framer"
        if exists $FRAMER_DEFINITION{$target};
    $FRAMER_DEFINITION{$target} = $definition;
    return;
}

sub _framer_for ($class) {
    for my $package (@{ mro::get_linear_isa($class) }) {
        return $FRAMER_DEFINITION{$package}
            if exists $FRAMER_DEFINITION{$package};
    }
    return undef;
}

sub declare_consumer ($base, $target, $definition) {
    croak 'a consumer may be declared only for a Linux::Event::Stream subclass'
        if $target eq $base || !$target->isa($base);
    croak "$target already has a Stream descriptor"
        if exists $CLASS_DESCRIPTOR{$target};
    croak "$target already declares a consumer"
        if exists $CONSUMER_DEFINITION{$target};
    croak 'consumer declaration must be a hash reference'
        if ref($definition) ne 'HASH';
    my @unknown = grep {
        $_ ne 'provider' && $_ ne 'abi_version'
            && $_ ne 'operations_address'
    } keys %$definition;
    croak 'consumer declaration has unknown fields: '
        . join(', ', sort @unknown) if @unknown;
    croak 'consumer declaration requires provider'
        if !exists($definition->{provider}) || !defined($definition->{provider});
    croak 'consumer declaration requires a positive integer abi_version'
        if !defined($definition->{abi_version})
        || $definition->{abi_version} !~ /\A[1-9]\d*\z/;
    croak 'consumer declaration requires a positive operations_address'
        if !defined($definition->{operations_address})
        || $definition->{operations_address} !~ /\A[1-9]\d*\z/;
    $CONSUMER_DEFINITION{$target} = { %$definition };
    return;
}

sub _consumer_for ($class) {
    for my $package (@{ mro::get_linear_isa($class) }) {
        return $CONSUMER_DEFINITION{$package}
            if exists $CONSUMER_DEFINITION{$package};
    }
    return undef;
}

sub _stream_options_for ($class) {
    my %option = (
        high_watermark   => 1_048_576,
        low_watermark    =>   262_144,
        max_pending_bytes =>         0,
        read_size        =>    65_536,
        read_budget_bytes =>         0,
        read_batch_bytes =>         0,
        message_batch_size =>       0,
        max_buffer       => 8_388_608,
        idle_timeout     =>         0,
        read_timeout     =>         0,
        write_timeout    =>         0,
    );

    if (my $configure = $class->can('stream_options')) {
        my @configured = $configure->($class);
        my %configured;
        if (@configured == 1 && ref($configured[0]) eq 'HASH') {
            %configured = %{ $configured[0] };
        } else {
            croak "$class stream_options() returned an odd option list"
                if @configured % 2;
            %configured = @configured;
        }
        my @unknown = grep { !exists $option{$_} } keys %configured;
        croak "$class stream_options() returned unknown options: "
            . join(', ', sort @unknown) if @unknown;
        @option{keys %configured} = values %configured;
    }

    croak "$class high_watermark must be a non-negative integer"
        if $option{high_watermark} !~ /\A\d+\z/;
    croak "$class low_watermark must be a non-negative integer"
        if $option{low_watermark} !~ /\A\d+\z/;
    croak "$class low_watermark must be <= high_watermark"
        if $option{low_watermark} > $option{high_watermark};
    croak "$class max_pending_bytes must be a non-negative integer"
        if $option{max_pending_bytes} !~ /\A\d+\z/;
    croak "$class read_size must be a positive integer"
        if $option{read_size} !~ /\A\d+\z/ || $option{read_size} <= 0;
    croak "$class read_budget_bytes must be a non-negative integer"
        if $option{read_budget_bytes} !~ /\A\d+\z/;
    croak "$class read_batch_bytes must be a non-negative integer"
        if $option{read_batch_bytes} !~ /\A\d+\z/;
    croak "$class message_batch_size must be a non-negative integer"
        if $option{message_batch_size} !~ /\A\d+\z/;
    croak "$class max_buffer must be a positive integer"
        if $option{max_buffer} !~ /\A\d+\z/ || $option{max_buffer} <= 0;
    for my $name (qw(idle_timeout read_timeout write_timeout)) {
        $option{$name} = Linux::Event::Stream::_timeout_value(
            $class, $name, $option{$name},
        );
    }
    return \%option;
}

sub for_class ($class) {
    return $CLASS_DESCRIPTOR{$class} if exists $CLASS_DESCRIPTOR{$class};
    croak 'Linux::Event::Stream is a base class; construct a Stream subclass'
        if $class eq 'Linux::Event::Stream';
    croak "$class is not a Linux::Event::Stream subclass"
        if !$class->isa('Linux::Event::Stream');
    if (!$class->isa('Linux::Event::Socket')) {
        croak "$class defines socket_options() but does not inherit from Linux::Event::Socket"
            if $class->can('socket_options');
        croak "$class defines configure_socket() but does not inherit from Linux::Event::Socket"
            if $class->can('configure_socket');
    }

    my $framer = _framer_for($class);
    my $consumer = _consumer_for($class);
    my $option = _stream_options_for($class);
    my %callback = map { $_ => scalar $class->can($_) }
        qw(on_data on_message on_messages on_drain on_eof on_error on_close
           on_ready on_transport_ready);

    if ($framer) {
        croak "$class read_batch_bytes is available only to raw Streams"
            if $option->{read_batch_bytes};
        croak "$class cannot define on_data() when it declares a framer"
            if $callback{on_data};
        if ($consumer) {
            croak "$class native consumer cannot be combined with message_batch_size"
                if $option->{message_batch_size};
            croak "$class native consumer cannot be combined with on_message()"
                if $callback{on_message};
            croak "$class native consumer cannot be combined with on_messages()"
                if $callback{on_messages};
        } elsif ($option->{message_batch_size}) {
            croak "$class enables message_batch_size but does not define on_messages()"
                if !$callback{on_messages};
            croak "$class cannot define both on_message() and on_messages()"
                if $callback{on_message};
        } else {
            croak "$class defines on_messages() without enabling message_batch_size"
                if $callback{on_messages};
        }
    } else {
        croak "$class native consumer requires a framed Stream"
            if $consumer;
        croak "$class defines on_message() but does not declare a framer"
            if $callback{on_message};
        croak "$class defines on_messages() but does not declare a framer"
            if $callback{on_messages};
        croak "$class message_batch_size is available only to framed Streams"
            if $option->{message_batch_size};
    }

    my $native = $framer ? { %{ $framer->{native} } } : { read_mode => 0 };

    my $xs = Linux::Event::Stream::XSDescriptor->new({
        read_size          => $option->{read_size},
        read_budget_bytes  => $option->{read_budget_bytes},
        read_batch_bytes   => $option->{read_batch_bytes},
        message_batch_size => $option->{message_batch_size},
        high_watermark     => $option->{high_watermark},
        low_watermark      => $option->{low_watermark},
        max_pending_bytes  => $option->{max_pending_bytes},
        max_buffer         => $option->{max_buffer},
        read_mode          => $native->{read_mode},

        deliver_cb       => $callback{on_data},
        message_cb       => $callback{on_message},
        message_batch_cb => $callback{on_messages},
        drain_cb         => $callback{on_drain}
            ? \&Linux::Event::Stream::_xs_drain : undef,
        eof_cb           => \&Linux::Event::Stream::_xs_read_eof,
        read_error_cb    => \&Linux::Event::Stream::_xs_read_error,
        write_error_cb   => \&Linux::Event::Stream::_xs_write_error,
        output_limit_cb  => \&Linux::Event::Stream::_xs_output_limit,
        write_empty_cb   => \&Linux::Event::Stream::_xs_write_empty,
        framing_error_cb => \&Linux::Event::Stream::_xs_framing_error,

        delimiter         => $native->{delimiter},
        include_delimiter => $native->{include_delimiter} // 0,
        max_frame         => $native->{max_frame},
        fixed_size        => $native->{fixed_size} // 0,
        prefix_bytes      => $native->{prefix_bytes} // 0,
        prefix_little     => $native->{prefix_little} // 0,
        include_prefix    => $native->{include_prefix} // 0,

        consumer_provider    => $consumer ? $consumer->{provider} : undef,
        consumer_abi_version => $consumer ? $consumer->{abi_version} : 0,
        consumer_ops_address => $consumer
            ? $consumer->{operations_address} : 0,
    });

    my $descriptor = {
        class     => $class,
        xs        => $xs,
        options   => $option,
        native    => $native,
        framer    => $framer,
        consumer  => $consumer,
        callbacks => \%callback,
    };
    $CLASS_DESCRIPTOR{$class} = $descriptor;
    return $descriptor;
}

sub clear_cache () {
    %CLASS_DESCRIPTOR = ();
    return;
}

1;
