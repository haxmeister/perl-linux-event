# Native Stream consumer ABI

The native Stream consumer ABI is an extension boundary for distributions that
need complete framed messages without entering Perl through `on_message` for
every frame. It is deliberately narrower than a Stream transport, framer,
Future, queue, or scheduler.

The first intended user is a separate async/await distribution. The core ABI
contains no Future class, continuation protocol, cancellation policy, or async
subroutine semantics.

## Data path

An ordinary framed Stream uses:

```text
epoll -> native transport read -> native framer -> on_message
```

A Stream class with a native consumer uses:

```text
epoll -> native transport read -> native framer -> provider message function
```

The provider owns one context per Stream. It may retain an outstanding receive,
queue results, or wake another abstraction, but Linux::Event does not know what
that abstraction is.

## Declaring a provider

An extension loads its XS code, obtains the address of a static
`les_consumer_ops_v1_t`, and declares it on a Stream subclass:

```perl
Linux::Event::Stream->_declare_consumer(
    'My::FramedStream',
    {
        provider           => $provider_lifetime_token,
        abi_version        => 1,
        operations_address => $native_table_address,
    },
);
```

The subclass must also declare one built-in native framer. A consumer is
mutually exclusive with `on_message`, `on_messages`, and
`message_batch_size`. Raw `on_data` Streams cannot attach one.

The declaration is inherited through the Stream class MRO and becomes
immutable when the first class descriptor is built. The `provider` value is
retained for the descriptor lifetime so the extension and any provider-owned
state remain loaded.

`_declare_consumer` is an extension-author interface. It is not an application
method and does not imply that the core exposes an async API.

## C contract

The canonical v1 declarations are in `xsstream/stream_consumer_abi.h`.
External XS distributions should vendor that header and retain the ABI version
check rather than including Stream private headers.

The operations table contains:

| Function | Contract |
|---|---|
| `create` | Create one provider context for one Stream. Return `NULL` on failure. |
| `message` | Consume one borrowed framed-message `SV *` and return a consumer status. |
| `event` | Observe the first terminal input/lifecycle event. |
| `destroy` | Release the provider context exactly once. |
| `flush` | Optional end-of-drain notification for bounded provider batching. |

The host table passed to `create` contains:

| Function | Contract |
|---|---|
| `resume` | Clear consumer pause, synchronously dispatch buffered frames when possible, and restore read interest. |
| `pause` | Stop application payload reads immediately, including while no message callback is active. |
| `stream` | Return the borrowed Perl Stream `SV *`. |
| `is_closed` | Report whether the host Stream is closed. |
| `retain` | Retain the host state and provider context across a provider-owned entry frame. |
| `release` | Release a prior retain; this may destroy both contexts and must be the frame's last action. |

Every table begins with `abi_version` and `struct_size`. Linux::Event rejects
version mismatches, tables smaller than the original v1 fields, unsupported
flags, missing names, and
missing required functions before constructing a Stream. The operations table
must remain at a stable address for every descriptor that declares it.

`flush` was appended as an optional v1 field. A provider requests it with
`LES_CONSUMER_F_WANT_FLUSH`; the host then requires a full-size table and a
non-null function. Hosts predating this extension reject that flag, while
providers compiled against the original v1 layout remain valid. The hook runs
after a framed native-input drain that called `message` at least once and
returns the same status values as `message`. This allows a provider to retain a
bounded batch and defer one application wakeup until the current read or
buffered-input drain is complete.

`retain` and `release` were appended to the host table as an optional ABI-v1
lifetime extension. A provider that calls callback-capable host functions from
its own XSUB or another provider-owned entry frame must first verify
`struct_size` reaches `LES_CONSUMER_HOST_V1_RETAIN_REQUIRED_SIZE`, call
`retain`, and guarantee a matching `release` during both normal return and
exception unwinding. The retain covers the entire provider frame, not merely
the duration of `resume` or `pause`. The provider must perform no provider- or
host-context access after `release`, because release may run the provider's
`destroy` function immediately.

If a message-side callback closes the Stream, the final `flush` may run
reentrantly before `message` returns. The Stream first marks the relevant
direction terminal so host `resume` and `pause` calls cannot restart input,
then delivers the pending flush, and only then delivers the terminal event.
At this terminal boundary `CONTINUE`, `PAUSE`, and `CLOSE` do not reopen or
otherwise change the lifecycle; invalid status values and `ERROR` remain
provider failures.

`create` must report failure with `NULL`, and `destroy` must not throw. A
`message` or `event` implementation that invokes Perl may propagate an
exception just like an ordinary Stream callback. It must update ownership and
pending-operation state before that invocation so exception unwinding leaves
the context valid. An invalid message status or explicit consumer error is
treated as a fatal provider bug.

## Message ownership

The `message` argument is borrowed and valid for the duration of the call. A
provider that retains it must increment its reference count and later release
that reference. Retaining the same scalar transfers no payload bytes and is the
expected path for a native receive result.

The provider context and any retained values belong to the provider. Stream
calls `destroy` only after native delivery has stopped and all provider-held
host lifetime retains have been released.

## Pause, resume, and reentrancy

`LES_CONSUMER_F_START_PAUSED` prevents application payload reads until the
provider calls the host `resume` function. This supports pull-style consumers
without eagerly filling a second queue.

The host `pause` function lets a provider withdraw an armed operation before a
message arrives. This is the generic mechanism needed by cancellation or any
other pull-consumer policy; it neither closes the Stream nor discards buffered
or kernel-resident input.

`message` returns one of:

| Status | Effect |
|---|---|
| `LES_CONSUMER_CONTINUE` | Continue parsing complete frames in the current drain. |
| `LES_CONSUMER_PAUSE` | Disable application read interest after this frame. |
| `LES_CONSUMER_CLOSE` | Close the Stream through its ordinary lifecycle. |
| `LES_CONSUMER_ERROR` | Raise a fatal provider error. |

`resume` may synchronously invoke `message` before it returns when a complete
frame is already buffered. Providers must therefore establish all pending
operation state before calling it. If that delivery invokes provider or user
code, the code may close the Stream and release its Perl XSState object before
`resume` returns. A provider-owned caller that will inspect its context, call
another host function, or otherwise continue afterward must hold the appended
host lifetime retain across that complete frame. Retaining only the Stream
Perl scalar or assuming the raw `host_context` outlives `resume` is not valid.

The same rule applies to `pause`: its paused notification may enter Perl even
though that notification is the host's last stateful action. `stream` and
`is_closed` do not themselves enter provider or application code, but their
borrowed results and the host context remain valid across reentrant work only
while the provider holds a lifetime retain.

Delivery is also reentrant. A provider may wake user code from `message`; that
code may arm the next receive immediately. In that case the provider should
return `CONTINUE` when another receive is armed and `PAUSE` when none is armed.
Stream checks pause, close, EOF, and descriptor state between frames.

Transport progress is independent from consumer pause. In particular, TLS may
continue its handshake or shutdown while application delivery is paused. Once
the transport is ready, consumer pause controls payload read interest normally.

## Terminal events

The provider receives at most one terminal event:

| Event | Meaning |
|---|---|
| `LES_CONSUMER_EVENT_EOF` | Clean input EOF. |
| `LES_CONSUMER_EVENT_READ_ERROR` | Native transport read failure. |
| `LES_CONSUMER_EVENT_FRAMING_ERROR` | The active native framer rejected input. |
| `LES_CONSUMER_EVENT_CLOSED` | Explicit or error-driven Stream close. |
| `LES_CONSUMER_EVENT_DETACHED` | Plain transport ownership was detached. |
| `LES_CONSUMER_EVENT_READ_CLOSED` | The application explicitly closed only the read direction. |

The event runs before the corresponding ordinary Stream EOF, error, or close
handling. Existing typed Stream errors and lifecycle callbacks remain active.
An integration may use those semantic callbacks for richer error objects while
using the native event to settle or release pending provider state.
The host rejects `resume` after a terminal event, including during a reentrant
terminal callback.

Additional terminal event codes may be appended while retaining the ABI v1
table layout. A provider must treat an unknown event code as terminal and use
the same conservative settlement and cleanup it uses for
`LES_CONSUMER_EVENT_CLOSED`. It must not reject an unknown terminal code or
attempt to resume the Stream.

## Descriptor transitions

`transition_to` may change framing while retaining one provider context only
when both source and target descriptors use the same operations-table pointer.
Adding, removing, or changing a provider on a live connection is rejected.
Unread bytes remain in native input storage and are interpreted by the target
framer under the existing transition rules.

## Fairness

`read_budget_bytes` is a general Stream class option. Zero, the default, keeps
the existing drain-until-EAGAIN behavior. A positive value limits bytes read
from the transport during one readiness callback; level-triggered readiness
continues the drain on a later Loop turn.

The option is useful when a reentrant pull consumer continuously returns
`CONTINUE`, but it is not specific to async/await and applies equally to raw or
callback-driven Streams.

## Stability boundary

Version 1 exposes only the two public tables and the constants in
`stream_consumer_abi.h`. Provider code must not inspect `les_xsstate_t`, the
Stream descriptor, watcher storage, native input buffers, or transport
contexts. New optional table fields require a larger `struct_size`; an
incompatible contract requires a new ABI version.
