#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# Broad public test rewrites must not rewrite references that intentionally
# probe private implementation helpers.
private_replacements = {
    'Linux::Event::IO::Sock::Dgram::_ReadyTimer':
        'Linux::Event::_Socket::Dgram::_ReadyTimer',
    'Linux::Event::IO::Sock::Stream::_Connection':
        'Linux::Event::_Socket::Connection',
    'Linux::Event::IO::Sock::Stream::_deadline_now':
        'Linux::Event::_ByteStream::_deadline_now',
    'Linux::Event::IO::Sock::Stream::_rearm_stream_deadline':
        'Linux::Event::_ByteStream::_rearm_stream_deadline',
}

api_contract_replacements = {
    "package T::API::GenericSocketOptions;\n    use parent 'Linux::Event::IO::Sock::Stream';":
        "package T::API::GenericSocketOptions;\n    use parent 'Linux::Event::IO::Pipe';",
    "package T::API::GenericSocketHook;\n    use parent 'Linux::Event::IO::Sock::Stream';":
        "package T::API::GenericSocketHook;\n    use parent 'Linux::Event::IO::Pipe';",
    "construction_error('Linux::Event::IO::Sock::Stream');\n"
    "ok(!$made, 'historical Stream implementation base cannot be constructed');":
        "construction_error('Linux::Event::_ByteStream');\n"
        "ok(!$made, 'private ordered-byte implementation base cannot be constructed');",
    "construction_error('Linux::Event::IO::Sock::Stream');\n"
    "ok(!$made, 'historical Socket implementation base cannot be constructed');":
        "construction_error('Linux::Event::_Socket::Stream');\n"
        "ok(!$made, 'private stream-socket implementation base cannot be constructed');",
}

framer_send_replacements = {
    "use Linux::Event::Framer 'LengthPrefix', bytes => 4, endian => 'big';\n"
    '    sub on_error ($stream, $error) { die "Stream error: $error\\n" }':
        "use Linux::Event::Framer 'LengthPrefix', bytes => 4, endian => 'big';\n"
        '    sub on_message ($stream, $message) { }\n'
        '    sub on_error ($stream, $error) { die "Stream error: $error\\n" }',
    "use Linux::Event::Framer 'Varint';\n"
    '    sub on_error ($stream, $error) { die "Stream error: $error\\n" }':
        "use Linux::Event::Framer 'Varint';\n"
        '    sub on_message ($stream, $message) { }\n'
        '    sub on_error ($stream, $error) { die "Stream error: $error\\n" }',
    '$class->new(loop => $loop, write_fh => $producer)':
        '$class->new(loop => $loop, fh => $producer)',
    '$stream->{descriptor}{native}':
        '$stream->{descriptor}{framer}{native}',
}

native_consumer_generic_bases = (
    'GenericConsumerBase',
    'FlushContinueBase',
    'CroakingConsumerBase',
    'MessageContinueBase',
    'MessageInvalidBase',
    'FlushCloseBase',
)

for base in (ROOT / 't', ROOT / 'bench'):
    for p in base.rglob('*'):
        if not p.is_file() or p.suffix not in {'.t', '.pl', '.pm'}:
            continue
        text = p.read_text()
        for old, new in private_replacements.items():
            text = text.replace(old, new)
        text = text.replace(
            'failed to create per-Stream context',
            'failed to create context',
        )
        text = text.replace('must define on_wakeup', 'must define on_event')
        if p == ROOT / 't/stream-09-api-contract.t':
            for old, new in api_contract_replacements.items():
                text = text.replace(old, new)
        if p == ROOT / 'bench/run-framer-send-bench.pl':
            for old, new in framer_send_replacements.items():
                text = text.replace(old, new)
        if p == ROOT / 't/stream-59-native-consumer-abi.t':
            text = text.replace(
                'use Linux::Event::IO::Sock::Stream;\n'
                'use Linux::Event::IO::Sock::Stream;',
                'use Linux::Event::_ByteStream ();\n'
                'use Linux::Event::IO::Sock::Stream;',
            )
            text = text.replace(
                'Linux::Event::IO::Sock::Stream->_native_consumer_abi_version',
                'Linux::Event::_ByteStream->_native_consumer_abi_version',
            )
            text = text.replace(
                'Linux::Event::IO::Sock::Stream->_declare_consumer',
                'Linux::Event::_ByteStream->_declare_consumer',
            )
            for package in native_consumer_generic_bases:
                text = text.replace(
                    f"package T::{package};\n"
                    "    use parent 'Linux::Event::IO::Sock::Stream';",
                    f"package T::{package};\n"
                    "    use parent 'Linux::Event::_ByteStream';",
                )
        if p == ROOT / 't/stream-60-generic-handles.t':
            text = text.replace(
                'use Linux::Event::_ByteStream;\n'
                'use Linux::Event::_ByteStream;',
                'use Linux::Event::_ByteStream;\n'
                'use Linux::Event::IO::Sock::Stream;',
            )
            text = text.replace(
                "package T::SocketProbe;\n"
                "    use parent 'Linux::Event::_ByteStream';",
                "package T::SocketProbe;\n"
                "    use parent 'Linux::Event::IO::Sock::Stream';",
            )
            text = text.replace(
                'only on Linux::Event::_ByteStream subclasses',
                'only on Linux::Event::IO::Sock::Stream subclasses',
            )
        if p == ROOT / 't/stream-62-consumer-host-lifetime.t':
            text = text.replace(
                'my $continued = $stream->_test_consumer_external_arm(\n',
                'my $continued = Linux::Event::_ByteStream::TestSupport::'
                '_test_consumer_external_arm(\n    $stream,\n',
            )
        p.write_text(text)

print('coherent core test fixups applied')
