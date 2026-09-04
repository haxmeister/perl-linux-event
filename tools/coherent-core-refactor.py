#!/usr/bin/env python3
from pathlib import Path
import re
import shutil

ROOT = Path(__file__).resolve().parents[1]
LIB = ROOT / 'lib' / 'Linux' / 'Event'


def read(path):
    return (ROOT / path).read_text()


def write(path, text):
    p = ROOT / path
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text)


def code(text):
    return text.split('\n__END__\n', 1)[0].rstrip() + '\n'


def pod(text):
    parts = text.split('\n__END__\n', 1)
    return ('\n__END__\n' + parts[1]) if len(parts) == 2 else ''


def no_private_version(text):
    text = re.sub(r"\nour \$VERSION = '[^']+';\n", '\n', text, count=1)
    text = text.replace('XSLoader::load(__PACKAGE__, $VERSION);', 'XSLoader::load(__PACKAGE__);')
    return text


def public_version(text):
    return re.sub(r"our \$VERSION = '[^']+';", "our $VERSION = '0.111';", text, count=1)


def strip_pod(text):
    return code(text)


def transform_impl(src, replacements, private=True):
    text = code(read(src))
    for old, new in replacements:
        text = text.replace(old, new)
    return no_private_version(text) if private else public_version(text)


# Preserve the authoritative public POD before replacing wrapper bodies.
public_pod = {
    name: pod(read(f'lib/Linux/Event/Kernel/{name}.pm'))
    for name in ('Timer', 'Signal', 'Event', 'Process')
}

# Ordered-byte implementation: the real implementation now lives in _ByteStream.
text = transform_impl(
    'lib/Linux/Event/Stream.pm',
    [
        ('Linux::Event::Stream::_Descriptor', 'Linux::Event::_ByteStream::Descriptor'),
        ('Linux::Event::Stream', 'Linux::Event::_ByteStream'),
        ('Linux::Event::Timer', 'Linux::Event::Kernel::Timer'),
    ],
)
text = text.replace(
    'use strict;\nuse warnings;\n\n',
    "use strict;\nuse warnings;\n\nuse parent 'Linux::Event::_IO';\n",
    1,
)
write('lib/Linux/Event/_ByteStream.pm', text)
(ROOT / 'lib/Linux/Event/Stream.pm').unlink()
shutil.rmtree(ROOT / 'lib/Linux/Event/Stream', ignore_errors=True)

# Connected SOCK_STREAM implementation.
text = transform_impl(
    'lib/Linux/Event/Socket.pm',
    [
        ('Linux::Event::Socket::_Connection', 'Linux::Event::_Socket::Connection'),
        ('Linux::Event::Socket::_Descriptor', 'Linux::Event::_Socket::Descriptor'),
        ('Linux::Event::Socket', 'Linux::Event::_Socket::Stream'),
        ('Linux::Event::Stream', 'Linux::Event::_ByteStream'),
    ],
)
text = text.replace(
    "use parent 'Linux::Event::_ByteStream';",
    "use parent qw(Linux::Event::_Socket Linux::Event::_ByteStream);",
    1,
)
write('lib/Linux/Event/_Socket/Stream.pm', text)
(ROOT / 'lib/Linux/Event/Socket.pm').unlink()

# Socket connection helper.
text = transform_impl(
    'lib/Linux/Event/Socket/_Connection.pm',
    [
        ('Linux::Event::Socket::_Connection', 'Linux::Event::_Socket::Connection'),
        ('Linux::Event::Socket', 'Linux::Event::_Socket::Stream'),
        ('Linux::Event::Stream', 'Linux::Event::_ByteStream'),
    ],
)
write('lib/Linux/Event/_Socket/Connection.pm', text)
shutil.rmtree(ROOT / 'lib/Linux/Event/Socket', ignore_errors=True)

# Listener implementation.
text = transform_impl(
    'lib/Linux/Event/Listener.pm',
    [
        ('Linux::Event::Listener', 'Linux::Event::_Socket::Listener'),
        ('Linux::Event::Socket', 'Linux::Event::_Socket::Stream'),
        ('Linux::Event::Stream', 'Linux::Event::_ByteStream'),
    ],
)
text = text.replace(
    'use strict;\nuse warnings;\n\n',
    "use strict;\nuse warnings;\n\nuse parent 'Linux::Event::_Socket';\n",
    1,
)
write('lib/Linux/Event/_Socket/Listener.pm', text)
(ROOT / 'lib/Linux/Event/Listener.pm').unlink()

# Datagram implementation.
text = transform_impl(
    'lib/Linux/Event/Datagram.pm',
    [
        ('Linux::Event::Datagram', 'Linux::Event::_Socket::Dgram'),
        ('Linux::Event::Timer', 'Linux::Event::Kernel::Timer'),
    ],
)
text = text.replace(
    'use strict;\nuse warnings;\n\n',
    "use strict;\nuse warnings;\n\nuse parent 'Linux::Event::_Socket';\n",
    1,
)
write('lib/Linux/Event/_Socket/Dgram.pm', text)
(ROOT / 'lib/Linux/Event/Datagram.pm').unlink()

# Kernel facilities own their implementations directly. No retired bridge class.
def install_kernel(old_name, new_name, extra=()):
    reps = [(f'Linux::Event::{old_name}', f'Linux::Event::Kernel::{new_name}')]
    reps.extend(extra)
    impl = transform_impl(f'lib/Linux/Event/{old_name}.pm', reps, private=False)
    write(f'lib/Linux/Event/Kernel/{new_name}.pm', impl.rstrip() + public_pod[new_name])
    (ROOT / f'lib/Linux/Event/{old_name}.pm').unlink()

install_kernel('Timer', 'Timer')
install_kernel('Signal', 'Signal')
install_kernel('Process', 'Process', [
    ('Linux::Event::Stream', 'Linux::Event::_ByteStream'),
])

# Event is the eventfd facility; expose on_event directly instead of on_wakeup glue.
impl = transform_impl(
    'lib/Linux/Event/Wakeup.pm',
    [('Linux::Event::Wakeup', 'Linux::Event::Kernel::Event')],
    private=False,
)
impl = impl.replace("on_wakeup", "on_event")
impl = impl.replace("Wakeup", "Event")
write('lib/Linux/Event/Kernel/Event.pm', impl.rstrip() + public_pod['Event'])
(ROOT / 'lib/Linux/Event/Wakeup.pm').unlink()

# Private helpers are code-only implementation files, not duplicate manuals.
for rel in (
    'lib/Linux/Event/_IO.pm',
    'lib/Linux/Event/_Socket.pm',
    'lib/Linux/Event/_ByteStream/Descriptor.pm',
    'lib/Linux/Event/_Socket/Descriptor.pm',
):
    text = strip_pod(read(rel))
    text = no_private_version(text)
    text = text.replace('Linux::Event::Stream', 'Linux::Event::_ByteStream')
    text = text.replace('Linux::Event::Socket', 'Linux::Event::_Socket::Stream')
    # Remove now-redundant compatibility clauses introduced by exact replacement.
    text = text.replace(
        "    my $is_ordered_byte = $class->isa('Linux::Event::_ByteStream')\n        || $class->isa('Linux::Event::_ByteStream');",
        "    my $is_ordered_byte = $class->isa('Linux::Event::_ByteStream');",
    )
    text = text.replace(
        "    my $is_stream_socket = $class->isa('Linux::Event::_Socket::Stream')\n        || $class->isa('Linux::Event::_Socket::Stream');",
        "    my $is_stream_socket = $class->isa('Linux::Event::_Socket::Stream');",
    )
    write(rel, text)

# Framer/TLS/loop support should recognize only the current implementation model.
for rel in (
    'lib/Linux/Event/Framer.pm',
    'lib/Linux/Event/TLS.pm',
    'lib/Linux/Event/Loop/Introspection.pm',
):
    text = read(rel)
    replacements = [
        ('Linux::Event::Stream::_Deadline', 'Linux::Event::_ByteStream::_Deadline'),
        ('Linux::Event::Stream::XSState', 'Linux::Event::_ByteStream::XSState'),
        ('Linux::Event::Datagram::_ReadyTimer', 'Linux::Event::_Socket::Dgram::_ReadyTimer'),
        ('Linux::Event::Signal', 'Linux::Event::Kernel::Signal'),
        ('Linux::Event::Wakeup', 'Linux::Event::Kernel::Event'),
        ('Linux::Event::Socket', 'Linux::Event::_Socket::Stream'),
        ('Linux::Event::Stream', 'Linux::Event::_ByteStream'),
    ]
    for old, new in replacements:
        text = text.replace(old, new)
    # Framer no longer needs any compatibility fallback.
    text = text.replace(
        "    return 'Linux::Event::_ByteStream'\n        if $target->isa('Linux::Event::_ByteStream');\n    return 'Linux::Event::_ByteStream'\n        if $target->isa('Linux::Event::_ByteStream');\n",
        "    return 'Linux::Event::_ByteStream'\n        if $target->isa('Linux::Event::_ByteStream');\n",
    )
    # TLS should use the supported public leaf as its declaration base.
    text = re.sub(
        r"    my \$base = \$target->isa\('Linux::Event::IO::Sock::Stream'\).*?\n\s*: undef;",
        "    my $base = $target->isa('Linux::Event::IO::Sock::Stream')\n        ? 'Linux::Event::IO::Sock::Stream' : undef;",
        text,
        flags=re.S,
    )
    write(rel, text)

# Rename native extension identities to match the active architecture.
if (ROOT / 'xsstream').exists():
    shutil.move(ROOT / 'xsstream', ROOT / 'xsbytestream')
if (ROOT / 'xsbytestream/Stream.xs').exists():
    shutil.move(ROOT / 'xsbytestream/Stream.xs', ROOT / 'xsbytestream/ByteStream.xs')
if (ROOT / 'xswakeup').exists():
    shutil.move(ROOT / 'xswakeup', ROOT / 'xsevent')
if (ROOT / 'xsevent/Wakeup.xs').exists():
    shutil.move(ROOT / 'xsevent/Wakeup.xs', ROOT / 'xsevent/Event.xs')

native_replacements = {
    'xsbytestream': [
        ('Linux::Event::Stream::XSDescriptor', 'Linux::Event::_ByteStream::XSDescriptor'),
        ('Linux::Event::Stream::XSState', 'Linux::Event::_ByteStream::XSState'),
        ('Linux::Event::Stream', 'Linux::Event::_ByteStream'),
    ],
    'xslistener': [('Linux::Event::Listener', 'Linux::Event::_Socket::Listener')],
    'xsdatagram': [('Linux::Event::Datagram', 'Linux::Event::_Socket::Dgram')],
    'xsconnection': [('Linux::Event::Socket::_Connection', 'Linux::Event::_Socket::Connection')],
    'xsevent': [
        ('Linux::Event::Wakeup::_OwnerState', 'Linux::Event::Kernel::Event::_OwnerState'),
        ('Linux::Event::Wakeup', 'Linux::Event::Kernel::Event'),
    ],
    'xssignal': [('Linux::Event::Signal', 'Linux::Event::Kernel::Signal')],
    'xsprocess': [('Linux::Event::Process', 'Linux::Event::Kernel::Process')],
    'xsloop': [('Linux::Event::Timer::_Descriptor', 'Linux::Event::Kernel::Timer::_Descriptor')],
}
for dirname, reps in native_replacements.items():
    d = ROOT / dirname
    if not d.exists():
        continue
    for p in d.rglob('*'):
        if not p.is_file() or p.suffix not in {'.xs', '.c', '.h', '.PL'}:
            continue
        text = p.read_text()
        for old, new in reps:
            text = text.replace(old, new)
        p.write_text(text)

# Sub-build metadata. Private XS engines use the distribution version rather
# than maintaining a second set of package versions.
def replace_makefile(rel, name, version_from, xs_old=None, xs_new=None, object_old=None, object_new=None):
    p = ROOT / rel
    text = p.read_text()
    text = re.sub(r"NAME\s*=>\s*'[^']+'", f"NAME             => '{name}'", text, count=1)
    text = re.sub(r"VERSION_FROM\s*=>\s*'[^']+'", f"VERSION_FROM     => '{version_from}'", text, count=1)
    if xs_old and xs_new:
        text = text.replace(xs_old, xs_new)
    if object_old and object_new:
        text = text.replace(object_old, object_new)
    p.write_text(text)

replace_makefile('xsbytestream/Makefile.PL', 'Linux::Event::_ByteStream', '../lib/Linux/Event.pm',
                 "'Stream.xs' => 'Stream.c'", "'ByteStream.xs' => 'ByteStream.c'",
                 '        Stream\n', '        ByteStream\n')
# Clean target follows the generated primary C file.
p = ROOT / 'xsbytestream/Makefile.PL'
p.write_text(p.read_text().replace("FILES => 'Stream.c'", "FILES => 'ByteStream.c'"))
replace_makefile('xslistener/Makefile.PL', 'Linux::Event::_Socket::Listener', '../lib/Linux/Event.pm')
replace_makefile('xsdatagram/Makefile.PL', 'Linux::Event::_Socket::Dgram', '../lib/Linux/Event.pm')
replace_makefile('xsconnection/Makefile.PL', 'Linux::Event::_Socket::Connection', '../lib/Linux/Event.pm')
replace_makefile('xsevent/Makefile.PL', 'Linux::Event::Kernel::Event', '../lib/Linux/Event/Kernel/Event.pm',
                 "'Wakeup.xs' => 'Wakeup.c'", "'Event.xs' => 'Event.c'",
                 'Wakeup$(OBJ_EXT)', 'Event$(OBJ_EXT)')
p = ROOT / 'xsevent/Makefile.PL'
p.write_text(p.read_text().replace("FILES => 'Wakeup.c'", "FILES => 'Event.c'"))
replace_makefile('xssignal/Makefile.PL', 'Linux::Event::Kernel::Signal', '../lib/Linux/Event/Kernel/Signal.pm')
replace_makefile('xsprocess/Makefile.PL', 'Linux::Event::Kernel::Process', '../lib/Linux/Event/Kernel/Process.pm')

# Tests and active benchmarks use the supported public surface. Generic engine
# contract tests are handled explicitly below.
test_map = [
    ('Linux::Event::Socket', 'Linux::Event::IO::Sock::Stream'),
    ('Linux::Event::Listener', 'Linux::Event::IO::Sock::Listener'),
    ('Linux::Event::Datagram', 'Linux::Event::IO::Sock::Dgram'),
    ('Linux::Event::Timer', 'Linux::Event::Kernel::Timer'),
    ('Linux::Event::Signal', 'Linux::Event::Kernel::Signal'),
    ('Linux::Event::Wakeup', 'Linux::Event::Kernel::Event'),
    ('Linux::Event::Process', 'Linux::Event::Kernel::Process'),
    ('Linux::Event::Stream', 'Linux::Event::IO::Sock::Stream'),
]
for base in (ROOT / 't', ROOT / 'bench'):
    for p in base.rglob('*'):
        if not p.is_file() or p.suffix not in {'.t', '.pl', '.pm'}:
            continue
        if 'archive' in p.parts or 'decisions' in p.parts:
            continue
        text = p.read_text()
        for old, new in test_map:
            text = text.replace(old, new)
        text = text.replace('sub on_wakeup', 'sub on_event')
        p.write_text(text)

# Pure ordered-byte/private descriptor tests are not socket tests.
for rel in (
    't/stream-19-class-descriptor-sharing.t',
    't/stream-60-generic-handles.t',
    't/stream-61-teardown-exceptions.t',
    't/stream-62-consumer-host-lifetime.t',
    't/stream-63-construction-failure.t',
    't/stream-64-transition-consumer-flush.t',
):
    p = ROOT / rel
    if p.exists():
        text = p.read_text().replace('Linux::Event::IO::Sock::Stream', 'Linux::Event::_ByteStream')
        text = text.replace('Linux::Event::_ByteStream::_Descriptor', 'Linux::Event::_ByteStream::Descriptor')
        p.write_text(text)

# The old-vs-new benchmark has served its purpose; normal baseline regression
# now protects performance without retaining the old architecture as a fixture.
old_overhead = ROOT / 'bench/run-public-api-overhead.pl'
if old_overhead.exists():
    old_overhead.unlink()

# Root build list and private metadata follow the coherent implementation tree.
p = ROOT / 'Makefile.PL'
text = p.read_text()
text = text.replace('xsloop xsstream xstls xsconnection xsresolver xssignal xslistener xswakeup xsdatagram xsprocess',
                    'xsloop xsbytestream xstls xsconnection xsresolver xssignal xslistener xsevent xsdatagram xsprocess')
for retired in (
    '                Linux::Event::Datagram\n',
    '                Linux::Event::Listener\n',
    '                Linux::Event::Process\n',
    '                Linux::Event::Signal\n',
    '                Linux::Event::Socket\n',
    '                Linux::Event::Stream\n',
    '                Linux::Event::Timer\n',
    '                Linux::Event::Wakeup\n',
    '                Linux::Event::Datagram::_ReadyTimer\n',
    '                Linux::Event::Signal::_Descriptor\n',
    '                Linux::Event::Signal::_Engine\n',
    '                Linux::Event::Signal::_Service\n',
    '                Linux::Event::Socket::_Descriptor\n',
    '                Linux::Event::Socket::_Connection\n',
    '                Linux::Event::Stream::_Deadline\n',
    '                Linux::Event::Stream::_Descriptor\n',
    '                Linux::Event::Stream::XSDescriptor\n',
    '                Linux::Event::Stream::XSState\n',
    '                Linux::Event::Timer::_Descriptor\n',
    '                Linux::Event::Wakeup::_OwnerState\n',
):
    text = text.replace(retired, '')
# Add current private implementation packages once.
anchor = '                Linux::Event::_Socket::Dgram\n'
addition = (
    '                Linux::Event::_Socket::Connection\n'
    '                Linux::Event::_ByteStream::_Deadline\n'
    '                Linux::Event::_ByteStream::XSDescriptor\n'
    '                Linux::Event::_ByteStream::XSState\n'
    '                Linux::Event::_Socket::Dgram::_ReadyTimer\n'
    '                Linux::Event::Kernel::Signal::_Descriptor\n'
    '                Linux::Event::Kernel::Signal::_Engine\n'
    '                Linux::Event::Kernel::Signal::_Service\n'
    '                Linux::Event::Kernel::Event::_OwnerState\n'
    '                Linux::Event::Kernel::Timer::_Descriptor\n'
)
if addition.splitlines()[0].strip() not in text:
    text = text.replace(anchor, anchor + addition)
p.write_text(text)

# CI no longer carries an old-design comparison gate.
p = ROOT / '.github/workflows/ci.yml'
text = p.read_text()
text = re.sub(
    r"\n      - name: Compare old implementation classes with new public leaves\n.*?\n      - name: Compare 200 KB public stream surface\n.*?--json bench/results/public-api-overhead-200k.json\n",
    '\n', text, flags=re.S,
)
text = text.replace('            candidate/bench/results/public-api-overhead.json\n', '')
text = text.replace('            candidate/bench/results/public-api-overhead-200k.json\n', '')
p.write_text(text)

# Current doc-taxonomy guard should reject the retired names outright from
# active code rather than merely keeping them out of public_modules.
p = ROOT / 't/37-current-doc-taxonomy.t'
if p.exists():
    text = p.read_text()
    for old, new in test_map:
        text = text.replace(old, new)
    p.write_text(text)

# Refresh MANIFEST after the move. ExtUtils will sort it later during the
# workflow build; remove obvious dead paths now so dist checks are meaningful.
man = ROOT / 'MANIFEST'
if man.exists():
    lines = [line for line in man.read_text().splitlines()
             if not re.match(r'^(lib/Linux/Event/(?:Stream|Socket|Listener\.pm|Datagram\.pm|Timer\.pm|Signal\.pm|Wakeup\.pm|Process\.pm)|xsstream/|xswakeup/|bench/run-public-api-overhead\.pl)', line)]
    man.write_text('\n'.join(lines) + '\n')

print('coherent core mechanical refactor applied')
