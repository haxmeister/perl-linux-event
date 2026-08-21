use v5.36;
use strict;
use warnings;

use Test::More;
use FindBin qw($Bin);
use Socket qw(AF_UNIX SOCK_STREAM);

use Linux::Event::Listener;
use Linux::Event::Stream;
use Linux::Event::TLS;

{
    package T::DeclaredTLSServer;
    use parent 'Linux::Event::Stream';
    use Linux::Event::TLS
        cert_file => "$FindBin::Bin/tls-certs/server-cert.pem",
        key_file  => "$FindBin::Bin/tls-certs/server-key.pem",
        alpn      => ['declaration-test/1'];

    sub on_data ($stream, $bytes) { return }
}

{
    package T::InheritedTLSServer;
    use parent -norequire, 'T::DeclaredTLSServer';
}

{
    package T::DeclaredTLSClient;
    use parent 'Linux::Event::Stream';
    use Linux::Event::TLS
        ca_file => "$FindBin::Bin/tls-certs/server-cert.pem",
        alpn    => ['declaration-test/1'];

    sub on_data ($stream, $bytes) { return }
}

{
    package T::TLSWithoutCertificate;
    use parent 'Linux::Event::Stream';
    use Linux::Event::TLS;

    sub on_data ($stream, $bytes) { return }
}

{
    package T::TLSWithUnreadableCertificate;
    use parent 'Linux::Event::Stream';
    use Linux::Event::TLS
        cert_file => "$FindBin::Bin/tls-certs/missing-cert.pem",
        key_file  => "$FindBin::Bin/tls-certs/missing-key.pem";

    sub on_data ($stream, $bytes) { return }
}

my $listener = Linux::Event::Listener->new(
    stream_class => 'T::InheritedTLSServer',
    host         => '127.0.0.1',
    port         => 0,
);
ok($listener->port > 0,
    'Listener accepts an inherited TLS Stream declaration');
$listener->close;

my $client = T::DeclaredTLSClient->connect(
    host => 'localhost',
    port => 443,
);
isa_ok($client->transport, 'Linux::Event::TLS');
is($client->state, 'unattached',
    'declarative client TLS is prepared before Loop attachment');
$client->close;

my $ok = eval {
    Linux::Event::Listener->new(
        stream_class => 'T::TLSWithoutCertificate',
        host         => '127.0.0.1',
        port         => 0,
    );
    1;
};
ok(!$ok, 'accepted TLS Stream declaration requires a certificate');
like($@, qr/does not declare cert_file and key_file/,
    'missing server credential error identifies the declaration');

$ok = eval {
    Linux::Event::Listener->new(
        stream_class => 'T::TLSWithUnreadableCertificate',
        host         => '127.0.0.1',
        port         => 0,
    );
    1;
};
ok(!$ok, 'Listener preflights declared server identity files');
like($@, qr/(?:No such file or directory|failed to load TLS server identity)/,
    'unreadable server identity fails during Listener construction');

$ok = eval q{
    package T::TLSBeforeParent;
    use Linux::Event::TLS;
    use parent 'Linux::Event::Stream';
    sub on_data ($stream, $bytes) { return }
    1;
};
ok(!$ok, 'TLS declaration requires Stream inheritance first');
like($@, qr/must inherit from Linux::Event::Stream/,
    'declaration-order error is explicit');

$ok = eval q{
    package T::TLSUnknownOption;
    use parent 'Linux::Event::Stream';
    use Linux::Event::TLS imaginary => 1;
    sub on_data ($stream, $bytes) { return }
    1;
};
ok(!$ok, 'TLS declaration rejects unknown options');
like($@, qr/unknown options: imaginary/,
    'unknown TLS declaration option is named');

$ok = eval q{
    package T::TLSPairedCredential;
    use parent 'Linux::Event::Stream';
    use Linux::Event::TLS cert_file => '/tmp/certificate.pem';
    sub on_data ($stream, $bytes) { return }
    1;
};
ok(!$ok, 'TLS declaration requires paired server credentials');
like($@, qr/requires cert_file and key_file together/,
    'paired credential error is explicit');

$ok = eval q{
    package T::TLSDuplicateDeclaration;
    use parent 'Linux::Event::Stream';
    use Linux::Event::TLS;
    use Linux::Event::TLS;
    sub on_data ($stream, $bytes) { return }
    1;
};
ok(!$ok, 'Stream subclass rejects a duplicate TLS declaration');
like($@, qr/already declares TLS/,
    'duplicate TLS declaration error is explicit');

socketpair(my $left, my $right, AF_UNIX, SOCK_STREAM, 0)
    or die "socketpair: $!";
$ok = eval { T::DeclaredTLSServer->new(fh => $left); 1 };
ok(!$ok, 'adopted TLS handle requires an explicit advanced role');
like($@, qr/requires tls_role/,
    'adopted TLS role error is explicit');
close $left;
close $right;

done_testing;
