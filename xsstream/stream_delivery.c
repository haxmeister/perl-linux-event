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

void
les_future_fail(pTHX_ SV *future, SV *failure)
{
    les_future_api(aTHX)->fail(aTHX_ future, failure);
}

void
les_discard_recv_state(les_xsstate_t *st)
{
    if (!st)
        return;
    if (st->recv_queue) {
        SvREFCNT_dec((SV *)st->recv_queue);
        st->recv_queue = NULL;
    }
    if (st->recv_future) {
        SvREFCNT_dec(st->recv_future);
        st->recv_future = NULL;
    }
}

void
les_recv_eof(pTHX_ les_xsstate_t *st)
{
    SV *future;

    if (!st || !st->recv_future)
        return;
    future = st->recv_future;
    st->recv_future = NULL;
    ENTER;
    SAVEFREESV(future);
    if (!les_future_is_ready(aTHX_ future))
        les_future_done(aTHX_ future, &PL_sv_undef);
    LEAVE;
}

void
les_recv_fail(pTHX_ les_xsstate_t *st, SV *failure)
{
    SV *future;

    if (!st || !st->recv_future)
        return;
    future = st->recv_future;
    st->recv_future = NULL;
    ENTER;
    SAVEFREESV(future);
    if (!les_future_is_ready(aTHX_ future))
        les_future_fail(aTHX_ future, failure);
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
        if (!st->recv_queue)
            st->recv_queue = newAV();
        av_push(st->recv_queue, SvREFCNT_inc_simple_NN(message));
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

    if (!st || !st->recv_future || !st->recv_queue
        || av_count(st->recv_queue) == 0)
        return;
    future = st->recv_future;
    if (les_future_is_ready(aTHX_ future)) {
        SvREFCNT_dec(future);
        st->recv_future = NULL;
        return;
    }
    message = av_shift(st->recv_queue);
    st->recv_future = NULL;
    ENTER;
    SAVEFREESV(future);
    SAVEFREESV(message);
    les_future_done(aTHX_ future, message);
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
