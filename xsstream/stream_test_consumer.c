#include "stream_internal.h"

/* Private conformance provider used only by the core regression suite. It
 * exercises the same exported table an independent XS distribution supplies. */
typedef struct les_test_consumer_s {
    const les_consumer_host_api_v1_t *host;
    void *host_context;
    AV *messages;
    AV *events;
    SV *ready_cb;
    UV permits;
    UV delivered;
    UV flushes;
} les_test_consumer_t;

static UV les_test_destroyed = 0;

static void *
les_test_create(pTHX_ const les_consumer_host_api_v1_t *host,
    void *host_context, SV *stream)
{
    les_test_consumer_t *context;
    PERL_UNUSED_ARG(stream);

    Newxz(context, 1, les_test_consumer_t);
    context->host = host;
    context->host_context = host_context;
    context->messages = newAV();
    context->events = newAV();
    return context;
}

static void *
les_test_create_failure(pTHX_ const les_consumer_host_api_v1_t *host,
    void *host_context, SV *stream)
{
    PERL_UNUSED_ARG(host);
    PERL_UNUSED_ARG(host_context);
    PERL_UNUSED_ARG(stream);
    PERL_UNUSED_CONTEXT;
    return NULL;
}

static int
les_test_message(pTHX_ void *opaque, SV *message)
{
    les_test_consumer_t *context = (les_test_consumer_t *)opaque;
    SV *callback;
    dSP;

    if (!context->permits)
        return LES_CONSUMER_ERROR;
    context->permits--;
    context->delivered++;
    av_push(context->messages, newSVsv(message));

    callback = context->ready_cb;
    context->ready_cb = NULL;
    if (callback) {
        ENTER;
        SAVETMPS;
        SAVEFREESV(callback);
        PUSHMARK(SP);
        PUTBACK;
        call_sv(callback, G_DISCARD | G_VOID);
        FREETMPS;
        LEAVE;
    }
    return context->permits ? LES_CONSUMER_CONTINUE : LES_CONSUMER_PAUSE;
}

static void
les_test_event(pTHX_ void *opaque, uint32_t event, int error,
    const char *message)
{
    les_test_consumer_t *context = (les_test_consumer_t *)opaque;
    AV *row = newAV();
    SV *callback;
    dSP;

    av_push(row, newSVuv((UV)event));
    av_push(row, newSViv((IV)error));
    av_push(row, newSVpv(message ? message : "", 0));
    av_push(context->events, newRV_noinc((SV *)row));
    context->permits = 0;
    callback = context->ready_cb;
    context->ready_cb = NULL;
    if (callback) {
        ENTER;
        SAVETMPS;
        SAVEFREESV(callback);
        PUSHMARK(SP);
        PUTBACK;
        call_sv(callback, G_DISCARD | G_VOID);
        FREETMPS;
        LEAVE;
    }
}

static int
les_test_flush(pTHX_ void *opaque)
{
    les_test_consumer_t *context = (les_test_consumer_t *)opaque;
    PERL_UNUSED_CONTEXT;

    context->flushes++;
    return context->permits ? LES_CONSUMER_CONTINUE : LES_CONSUMER_PAUSE;
}

static void
les_test_destroy(pTHX_ void *opaque)
{
    les_test_consumer_t *context = (les_test_consumer_t *)opaque;
    PERL_UNUSED_CONTEXT;

    if (!context)
        return;
    if (context->ready_cb)
        SvREFCNT_dec(context->ready_cb);
    SvREFCNT_dec((SV *)context->messages);
    SvREFCNT_dec((SV *)context->events);
    Safefree(context);
    les_test_destroyed++;
}

static const les_consumer_ops_v1_t les_test_ops = {
    LES_CONSUMER_ABI_VERSION,
    sizeof(les_consumer_ops_v1_t),
    "Linux::Event core test consumer",
    LES_CONSUMER_F_START_PAUSED | LES_CONSUMER_F_WANT_FLUSH,
    les_test_create,
    les_test_message,
    les_test_event,
    les_test_destroy,
    les_test_flush
};

/* The original ABI v1 ended at destroy. Keep a provider with that exact
 * layout in the conformance suite so appended optional fields cannot make old
 * external providers fail validation or be read past struct_size. */
typedef struct les_test_original_ops_v1_s {
    uint32_t abi_version;
    size_t struct_size;
    const char *name;
    uint32_t flags;
    void *(*create)(pTHX_ const les_consumer_host_api_v1_t *host,
        void *host_context, SV *stream);
    int (*message)(pTHX_ void *context, SV *message);
    void (*event)(pTHX_ void *context, uint32_t event, int error,
        const char *message);
    void (*destroy)(pTHX_ void *context);
} les_test_original_ops_v1_t;

static const les_test_original_ops_v1_t les_test_original_ops = {
    LES_CONSUMER_ABI_VERSION,
    sizeof(les_test_original_ops_v1_t),
    "original-layout ABI v1 test consumer",
    LES_CONSUMER_F_START_PAUSED,
    les_test_create,
    les_test_message,
    les_test_event,
    les_test_destroy
};

static const les_consumer_ops_v1_t les_test_incomplete_ops = {
    LES_CONSUMER_ABI_VERSION,
    sizeof(les_consumer_ops_v1_t),
    "incomplete test consumer",
    LES_CONSUMER_F_START_PAUSED,
    les_test_create,
    NULL,
    les_test_event,
    les_test_destroy,
    NULL
};

static const les_consumer_ops_v1_t les_test_wrong_version_ops = {
    LES_CONSUMER_ABI_VERSION + 1,
    sizeof(les_consumer_ops_v1_t),
    "wrong-version test consumer",
    LES_CONSUMER_F_START_PAUSED,
    les_test_create,
    les_test_message,
    les_test_event,
    les_test_destroy,
    NULL
};

static const les_consumer_ops_v1_t les_test_missing_flush_ops = {
    LES_CONSUMER_ABI_VERSION,
    sizeof(les_consumer_ops_v1_t),
    "missing-flush test consumer",
    LES_CONSUMER_F_START_PAUSED | LES_CONSUMER_F_WANT_FLUSH,
    les_test_create,
    les_test_message,
    les_test_event,
    les_test_destroy,
    NULL
};

static const les_consumer_ops_v1_t les_test_unknown_flags_ops = {
    LES_CONSUMER_ABI_VERSION,
    sizeof(les_consumer_ops_v1_t),
    "unknown-flags test consumer",
    LES_CONSUMER_F_START_PAUSED | 0x80000000U,
    les_test_create,
    les_test_message,
    les_test_event,
    les_test_destroy,
    NULL
};

static const les_consumer_ops_v1_t les_test_create_failure_ops = {
    LES_CONSUMER_ABI_VERSION,
    sizeof(les_consumer_ops_v1_t),
    "create-failure test consumer",
    LES_CONSUMER_F_START_PAUSED,
    les_test_create_failure,
    les_test_message,
    les_test_event,
    les_test_destroy,
    NULL
};

static les_test_consumer_t *
les_test_context(les_xsstate_t *st)
{
    if (!st || (st->consumer_ops != &les_test_ops
        && st->consumer_ops != (const les_consumer_ops_v1_t *)
            &les_test_original_ops) || !st->consumer_context)
        croak("Stream does not use the Linux::Event core test consumer");
    return (les_test_consumer_t *)st->consumer_context;
}

SV *
les_test_consumer_definition(pTHX_ const char *variant)
{
    const les_consumer_ops_v1_t *ops = &les_test_ops;
    UV declared_version = LES_CONSUMER_ABI_VERSION;
    HV *definition = newHV();

    if (strEQ(variant, "incomplete"))
        ops = &les_test_incomplete_ops;
    else if (strEQ(variant, "original-v1"))
        ops = (const les_consumer_ops_v1_t *)&les_test_original_ops;
    else if (strEQ(variant, "wrong-table-version"))
        ops = &les_test_wrong_version_ops;
    else if (strEQ(variant, "missing-flush"))
        ops = &les_test_missing_flush_ops;
    else if (strEQ(variant, "unknown-flags"))
        ops = &les_test_unknown_flags_ops;
    else if (strEQ(variant, "create-failure"))
        ops = &les_test_create_failure_ops;
    else if (strEQ(variant, "wrong-declaration-version"))
        declared_version++;
    else if (!strEQ(variant, "valid"))
        croak("unknown test consumer definition variant '%s'", variant);

    hv_stores(definition, "provider", newSVpvs("Linux::Event core test consumer"));
    hv_stores(definition, "abi_version", newSVuv(declared_version));
    hv_stores(definition, "operations_address", newSVuv(PTR2UV(ops)));
    return newRV_noinc((SV *)definition);
}

void
les_test_consumer_arm(pTHX_ les_xsstate_t *st, SV *callback)
{
    les_test_consumer_t *context = les_test_context(st);

    if (context->permits || context->ready_cb)
        croak("test consumer already has an armed receive");
    context->permits = 1;
    if (callback && SvOK(callback))
        context->ready_cb = les_store_cb(callback, "test consumer callback");
    context->host->resume(aTHX_ context->host_context);
}

void
les_test_consumer_cancel(pTHX_ les_xsstate_t *st)
{
    les_test_consumer_t *context = les_test_context(st);

    context->permits = 0;
    if (context->ready_cb) {
        SvREFCNT_dec(context->ready_cb);
        context->ready_cb = NULL;
    }
    context->host->pause(aTHX_ context->host_context);
}

SV *
les_test_consumer_take(pTHX_ les_xsstate_t *st)
{
    les_test_consumer_t *context = les_test_context(st);
    SV *message = av_shift(context->messages);
    PERL_UNUSED_CONTEXT;
    return message ? message : newSV(0);
}

SV *
les_test_consumer_events(pTHX_ les_xsstate_t *st)
{
    les_test_consumer_t *context = les_test_context(st);
    AV *copy = newAV();
    SSize_t index;

    for (index = 0; index <= av_top_index(context->events); index++) {
        SV **row = av_fetch(context->events, index, 0);
        if (row)
            av_push(copy, newSVsv(*row));
    }
    return newRV_noinc((SV *)copy);
}

SV *
les_test_consumer_stats(pTHX_ les_xsstate_t *st)
{
    les_test_consumer_t *context = les_test_context(st);
    HV *stats = newHV();
    PERL_UNUSED_CONTEXT;

    hv_stores(stats, "permits", newSVuv(context->permits));
    hv_stores(stats, "queued_messages",
        newSVuv((UV)(av_top_index(context->messages) + 1)));
    hv_stores(stats, "delivered", newSVuv(context->delivered));
    hv_stores(stats, "flushes", newSVuv(context->flushes));
    return newRV_noinc((SV *)stats);
}

UV
les_test_consumer_destroy_count(void)
{
    return les_test_destroyed;
}
