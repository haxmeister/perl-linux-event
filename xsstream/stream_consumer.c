#include "stream_internal.h"

static void
les_call_stream_method(pTHX_ les_xsstate_t *st, const char *method)
{
    dSP;

    if (!st || !st->stream_sv)
        return;
    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    EXTEND(SP, 1);
    PUSHs(st->stream_sv);
    PUTBACK;
    call_method(method, G_DISCARD | G_VOID);
    FREETMPS;
    LEAVE;
}

static int
les_consumer_host_resume(pTHX_ void *host_context)
{
    return les_consumer_resume(aTHX_ (les_xsstate_t *)host_context);
}

static int
les_consumer_host_pause(pTHX_ void *host_context)
{
    les_xsstate_t *st = (les_xsstate_t *)host_context;

    if (!les_consumer_live(st) || st->read_eof)
        return 0;
    if (!st->consumer_paused) {
        st->consumer_paused = 1;
        LES_STAT(st, consumer_pause_count)++;
        les_consumer_notify_paused(aTHX_ st);
    }
    return 1;
}

static SV *
les_consumer_host_stream(pTHX_ void *host_context)
{
    les_xsstate_t *st = (les_xsstate_t *)host_context;
    return st && st->stream_sv ? st->stream_sv : &PL_sv_undef;
}

static int
les_consumer_host_is_closed(pTHX_ void *host_context)
{
    les_xsstate_t *st = (les_xsstate_t *)host_context;
    return !st || st->closed ? 1 : 0;
}

static const les_consumer_host_api_v1_t les_consumer_host_v1 = {
    LES_CONSUMER_ABI_VERSION,
    sizeof(les_consumer_host_api_v1_t),
    les_consumer_host_resume,
    les_consumer_host_pause,
    les_consumer_host_stream,
    les_consumer_host_is_closed
};

int
les_consumer_create(pTHX_ les_xsstate_t *st)
{
    if (!st || !st->descriptor || !st->descriptor->consumer_ops)
        return 1;

    st->consumer_ops = st->descriptor->consumer_ops;
    st->consumer_context = st->consumer_ops->create(aTHX_
        &les_consumer_host_v1, st, st->stream_sv);
    if (!st->consumer_context) {
        st->consumer_ops = NULL;
        return 0;
    }
    st->consumer_paused =
        (st->consumer_ops->flags & LES_CONSUMER_F_START_PAUSED) ? 1 : 0;
    return 1;
}

void
les_consumer_destroy(pTHX_ les_xsstate_t *st)
{
    const les_consumer_ops_v1_t *ops;
    void *context;

    if (!st || !st->consumer_ops || !st->consumer_context)
        return;
    ops = st->consumer_ops;
    context = st->consumer_context;
    st->consumer_ops = NULL;
    st->consumer_context = NULL;
    ops->destroy(aTHX_ context);
}

void
les_consumer_notify_paused(pTHX_ les_xsstate_t *st)
{
    if (st && !st->closed && st->consumer_paused)
        les_call_stream_method(aTHX_ st, "_xs_consumer_paused");
}

/* operation is NULL for the entry points whose diagnostics historically carried
 * no "from <op>" suffix; the two message variants are otherwise identical. */
static int
les_consumer_apply_status(pTHX_ les_xsstate_t *st, int status,
    const char *operation)
{
    if (status == LES_CONSUMER_CONTINUE)
        return status;
    if (status == LES_CONSUMER_PAUSE) {
        if (!st->consumer_paused) {
            st->consumer_paused = 1;
            LES_STAT(st, consumer_pause_count)++;
            les_consumer_notify_paused(aTHX_ st);
        }
        return status;
    }
    if (status == LES_CONSUMER_CLOSE) {
        les_call_stream_method(aTHX_ st, "_xs_consumer_close");
        return status;
    }
    if (status == LES_CONSUMER_ERROR) {
        if (operation)
            croak("native Stream consumer '%s' reported an error from %s",
                st->consumer_ops->name, operation);
        croak("native Stream consumer '%s' reported an error",
            st->consumer_ops->name);
    }
    if (operation)
        croak("native Stream consumer '%s' returned invalid status %d from %s",
            st->consumer_ops->name, status, operation);
    croak("native Stream consumer '%s' returned invalid status %d",
        st->consumer_ops->name, status);
    return LES_CONSUMER_ERROR;
}

int
les_consumer_message(pTHX_ les_xsstate_t *st, SV *message)
{
    int status;

    if (!st || !st->consumer_ops || !st->consumer_context)
        croak("native Stream consumer is not attached");
    LES_STAT(st, consumer_message_calls)++;
    status = st->consumer_ops->message(aTHX_ st->consumer_context, message);
    /* Only a completed dispatch owes a flush: a message() that croaks or
     * reports an error must not leave the flag set for an unrelated drain. */
    st->consumer_flush_pending = 1;
    return les_consumer_apply_status(aTHX_ st, status, NULL);
}

int
les_consumer_flush(pTHX_ les_xsstate_t *st)
{
    int status;

    if (!les_consumer_live(st) || !st->consumer_flush_pending)
        return LES_CONSUMER_CONTINUE;
    st->consumer_flush_pending = 0;
    if (!(st->consumer_ops->flags & LES_CONSUMER_F_WANT_FLUSH))
        return LES_CONSUMER_CONTINUE;
    LES_STAT(st, consumer_flush_calls)++;
    status = st->consumer_ops->flush(aTHX_ st->consumer_context);
    /* flush() reports pause/close/error only. CONTINUE means "no state
     * change" -- it must not revoke a pause the consumer asked for from
     * message(), which would invert backpressure and resume delivery of
     * messages the consumer just refused. */
    return les_consumer_apply_status(aTHX_ st, status, "flush");
}

void
les_consumer_event(pTHX_ les_xsstate_t *st, uint32_t event, int error,
    const char *message)
{
    if (!st || !st->consumer_ops || !st->consumer_context
        || st->consumer_terminal)
        return;
    /* Deliver anything the consumer has already accepted before it is told
     * the stream is finished; after this point les_consumer_live() is false
     * and no further flush can be issued. */
    les_consumer_flush(aTHX_ st);
    st->consumer_terminal = 1;
    LES_STAT(st, consumer_event_calls)++;
    st->consumer_ops->event(aTHX_ st->consumer_context, event, error,
        message ? message : "");
}

int
les_consumer_resume(pTHX_ les_xsstate_t *st)
{
    if (!les_consumer_live(st) || st->read_eof)
        return 0;

    if (st->consumer_paused) {
        st->consumer_paused = 0;
        LES_STAT(st, consumer_resume_count)++;
    }

    if (!st->read_paused && st->input_dispatch_depth == 0 && st->input_len) {
        ENTER;
        SAVEINT(st->input_dispatch_depth);
        st->input_dispatch_depth++;
        les_process_existing_input(aTHX_ st, 1);
        LEAVE;
    }

    if (!LES_INPUT_PAUSED(st) && !st->closed && !st->read_eof)
        les_call_stream_method(aTHX_ st, "_xs_consumer_resumed");
    return !LES_INPUT_PAUSED(st) && !st->closed && !st->read_eof;
}
