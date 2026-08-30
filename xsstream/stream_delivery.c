#include "stream_internal.h"
#include "../xsfuture/future_native.h"

static const lef_native_api_t *
les_future_api(pTHX)
{
    SV **slot;
    const lef_native_api_t *api;

    slot = hv_fetch(PL_modglobal, LEF_NATIVE_API_KEY,
        LEF_NATIVE_API_KEY_LEN, 0);
    if (!slot || !*slot || !SvIOK(*slot))
        croak("Linux::Event::Future native API is unavailable");
    api = INT2PTR(const lef_native_api_t *, SvIV(*slot));
    if (!api || api->version != LEF_NATIVE_API_VERSION
        || api->size < sizeof(lef_native_api_t))
        croak("Linux::Event::Future native API is incompatible");
    return api;
}

SV *
les_new_future(pTHX_ SV *loop_sv)
{
    return les_future_api(aTHX)->new_pending(aTHX_
        loop_sv && SvOK(loop_sv) ? loop_sv : &PL_sv_undef);
}

SV *
les_new_done_future(pTHX_ SV *loop_sv, SV *result)
{
    return les_future_api(aTHX)->new_done_one(aTHX_
        loop_sv && SvOK(loop_sv) ? loop_sv : &PL_sv_undef, result);
}

SV *
les_new_done_future_take(pTHX_ SV *result)
{
    return les_future_api(aTHX)->new_done_one_take(aTHX_ result);
}

int
les_future_is_ready(pTHX_ SV *future)
{
    return les_future_api(aTHX)->is_ready(aTHX_ future);
}

void
les_future_done(pTHX_ SV *future, SV *result)
{
    les_future_api(aTHX)->done_one(aTHX_ future, result);
}

int
les_future_done_if_pending(pTHX_ SV *future, SV *result)
{
    return les_future_api(aTHX)->done_one_if_pending(aTHX_
        future, result);
}

int
les_future_done_if_pending_take(pTHX_ SV *future, SV *result)
{
    return les_future_api(aTHX)->done_one_if_pending_take(aTHX_
        future, result);
}

void
les_future_fail(pTHX_ SV *future, SV *failure)
{
    les_future_api(aTHX)->fail(aTHX_ future, failure);
}

int
les_future_fail_if_pending(pTHX_ SV *future, SV *failure)
{
    return les_future_api(aTHX)->fail_if_pending(aTHX_
        future, failure);
}

void
les_discard_recv_state(les_xsstate_t *st)
{
    size_t index;

    if (!st)
        return;
    if (st->recv_queue) {
        for (index = 0; index < st->recv_queue_capacity; index++) {
            if (st->recv_queue[index])
                SvREFCNT_dec(st->recv_queue[index]);
        }
        free(st->recv_queue);
        st->recv_queue = NULL;
    }
    st->recv_queue_capacity = 0;
    st->recv_queue_head = 0;
    st->recv_queue_tail = 0;
    st->recv_queue_count = 0;
    if (st->recv_future) {
        SvREFCNT_dec(st->recv_future);
        st->recv_future = NULL;
    }
    st->recv_batch_mode = 0;
    st->recv_batch_max = 0;
}

static void
les_recv_queue_grow(pTHX_ les_xsstate_t *st)
{
    size_t capacity;
    size_t index;
    SV **next;

    capacity = st->recv_queue_capacity ? st->recv_queue_capacity * 2 : 64;
    if (capacity < st->recv_queue_capacity
        || capacity > (size_t)-1 / sizeof(*next))
        croak("Stream receive queue size overflow");

    next = (SV **)calloc(capacity, sizeof(*next));
    if (!next)
        croak("calloc Stream receive queue failed");

    for (index = 0; index < st->recv_queue_count; index++) {
        size_t source = (st->recv_queue_head + index)
            % st->recv_queue_capacity;
        next[index] = st->recv_queue[source];
    }

    free(st->recv_queue);
    st->recv_queue = next;
    st->recv_queue_capacity = capacity;
    st->recv_queue_head = 0;
    st->recv_queue_tail = st->recv_queue_count;
}

void
les_recv_queue_push(pTHX_ les_xsstate_t *st, SV *message)
{
    if (st->recv_queue_count == st->recv_queue_capacity)
        les_recv_queue_grow(aTHX_ st);

    st->recv_queue[st->recv_queue_tail] =
        SvREFCNT_inc_simple_NN(message);
    st->recv_queue_tail =
        (st->recv_queue_tail + 1) % st->recv_queue_capacity;
    st->recv_queue_count++;
}

SV *
les_recv_queue_pop(les_xsstate_t *st)
{
    SV *message;

    if (!st || st->recv_queue_count == 0)
        return NULL;

    message = st->recv_queue[st->recv_queue_head];
    st->recv_queue[st->recv_queue_head] = NULL;
    st->recv_queue_head =
        (st->recv_queue_head + 1) % st->recv_queue_capacity;
    st->recv_queue_count--;
    if (st->recv_queue_count == 0) {
        st->recv_queue_head = 0;
        st->recv_queue_tail = 0;
    }
    return message;
}

SV *
les_make_recv_batch(les_xsstate_t *st, UV maximum)
{
    AV *batch = newAV();
    UV count = 0;

    while (count < maximum && st->recv_queue_count) {
        SV *message = les_recv_queue_pop(st);
        av_push(batch, message);
        count++;
    }
    return newRV_noinc((SV *)batch);
}

void
les_recv_eof(pTHX_ les_xsstate_t *st)
{
    SV *future;

    if (!st || !st->recv_future)
        return;
    les_flush_recv_future(aTHX_ st);
    if (!st->recv_future)
        return;
    future = st->recv_future;
    st->recv_future = NULL;
    st->recv_batch_mode = 0;
    st->recv_batch_max = 0;
    ENTER;
    SAVEFREESV(future);
    les_future_done_if_pending(aTHX_ future, &PL_sv_undef);
    LEAVE;
}

void
les_recv_fail(pTHX_ les_xsstate_t *st, SV *failure)
{
    SV *future;

    if (!st || !st->recv_future)
        return;
    les_flush_recv_future(aTHX_ st);
    if (!st->recv_future)
        return;
    future = st->recv_future;
    st->recv_future = NULL;
    st->recv_batch_mode = 0;
    st->recv_batch_max = 0;
    ENTER;
    SAVEFREESV(future);
    les_future_fail_if_pending(aTHX_ future, failure);
    LEAVE;
}

void
les_discard_message_batch(les_xsstate_t *st)
{
    if (!st || !st->message_batch)
        return;
    SvREFCNT_dec((SV *)st->message_batch);
    st->message_batch = NULL;
    st->message_batch_count = 0;
    st->message_batch_bytes = 0;
}

void
les_flush_message_batch(pTHX_ les_xsstate_t *st)
{
    AV *batch;
    SV *batch_rv;
    SV *callback;
    UV count;

    if (!st || !st->message_batch || st->message_batch_count == 0)
        return;

    batch = st->message_batch;
    count = st->message_batch_count;
    callback = st->descriptor->message_batch_cb;
    st->message_batch = NULL;
    st->message_batch_count = 0;
    st->message_batch_bytes = 0;

    batch_rv = sv_2mortal(newRV_noinc((SV *)batch));
    st->message_batch_calls++;
    if (count > st->message_batch_peak_messages)
        st->message_batch_peak_messages = count;
    les_call_two(aTHX_ callback, st->stream_sv, batch_rv);
}

void
les_emit_message(pTHX_ les_xsstate_t *st, SV *message)
{
    UV bytes;

    st->frames_emitted++;
    if (!st->descriptor->message_cb && !st->descriptor->message_batch_cb) {
        les_recv_queue_push(aTHX_ st, message);
        return;
    }
    if (!st->descriptor->message_batch_size) {
        st->message_callback_calls++;
        les_call_two(aTHX_ st->descriptor->message_cb, st->stream_sv, message);
        return;
    }

    if (!st->message_batch)
        st->message_batch = newAV();
    bytes = (UV)SvCUR(message);
    av_push(st->message_batch, SvREFCNT_inc_simple_NN(message));
    st->message_batch_count++;
    if (bytes > (UV)-1 - st->message_batch_bytes)
        st->message_batch_bytes = (UV)-1;
    else
        st->message_batch_bytes += bytes;
    if (st->message_batch_bytes > st->message_batch_peak_bytes)
        st->message_batch_peak_bytes = st->message_batch_bytes;

    /* max_buffer also bounds the aggregate retained by one batch. Because the
     * current message has already been decoded, the peak is less than two
     * max_buffer values even when one frame crosses the remaining budget. */
    if (st->message_batch_count >= st->descriptor->message_batch_size
        || st->message_batch_bytes >= st->descriptor->max_buffer)
        les_flush_message_batch(aTHX_ st);
}

void
les_flush_recv_future(pTHX_ les_xsstate_t *st)
{
    SV *future;
    SV *message;

    if (!st || !st->recv_future || st->recv_queue_count == 0)
        return;
    future = st->recv_future;
    if (les_future_is_ready(aTHX_ future)) {
        SvREFCNT_dec(future);
        st->recv_future = NULL;
        st->recv_batch_mode = 0;
        st->recv_batch_max = 0;
        return;
    }
    if (st->recv_batch_mode) {
        SV *batch = les_make_recv_batch(st, st->recv_batch_max);
        st->recv_future = NULL;
        st->recv_batch_mode = 0;
        st->recv_batch_max = 0;
        ENTER;
        SAVEFREESV(future);
        if (!les_future_done_if_pending_take(aTHX_ future, batch))
            SvREFCNT_dec(batch);
        LEAVE;
        return;
    }
    message = les_recv_queue_pop(st);
    st->recv_future = NULL;
    st->recv_batch_mode = 0;
    st->recv_batch_max = 0;
    ENTER;
    SAVEFREESV(future);
    if (!les_future_done_if_pending_take(aTHX_ future, message))
        SvREFCNT_dec(message);
    LEAVE;
}

void
les_flush_raw_batch(pTHX_ les_xsstate_t *st)
{
    const char *data;
    size_t len;
    SV *bytes;

    if (!st || !st->input_len || st->descriptor->read_mode != LES_READ_DELIVER
        || !st->descriptor->read_batch_bytes)
        return;

    data = les_input_data(st);
    len = st->input_len;
    if ((UV)len > st->descriptor->read_batch_bytes)
        len = (size_t)st->descriptor->read_batch_bytes;
    bytes = sv_2mortal(newSVpvn(data, (STRLEN)len));
    les_input_consume(st, len);
    st->read_batch_flushes++;
    if ((unsigned long long)len > st->read_batch_peak_bytes)
        st->read_batch_peak_bytes = (unsigned long long)len;
    les_call_deliver(aTHX_ st, bytes);
}
