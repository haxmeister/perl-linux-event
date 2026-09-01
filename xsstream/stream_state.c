#include "stream_internal.h"

les_xsstate_t *
les_state_from_sv(SV *sv)
{
    if (!sv_isobject(sv) || !SvROK(sv))
        croak("not a Linux::Event::Stream::XSState object");
    return INT2PTR(les_xsstate_t *, SvIV((SV *)SvRV(sv)));
}

les_descriptor_t *
les_descriptor_from_sv(SV *sv)
{
    if (!sv_isobject(sv) || !SvROK(sv))
        croak("not a Linux::Event::Stream::XSDescriptor object");
    return INT2PTR(les_descriptor_t *, SvIV((SV *)SvRV(sv)));
}

SV *
les_store_cb(SV *cb, const char *name)
{
    SV *cv;
    if (!cb || !SvOK(cb) || !SvROK(cb) || SvTYPE(SvRV(cb)) != SVt_PVCV)
        croak("%s must be a coderef", name);
    cv = SvRV(cb);
    SvREFCNT_inc(cv);
    return cv;
}

SV *
les_store_optional_cb(SV *cb, const char *name)
{
    if (!cb || !SvOK(cb))
        return NULL;
    return les_store_cb(cb, name);
}

/*
 * A readable Stream must have somewhere to put what it decodes. This is the
 * single definition of that invariant: XSState::new enforces it at construction
 * and les_transition_descriptor() re-enforces it for the incoming descriptor,
 * because a transition can otherwise install a framed descriptor with no
 * message sink and reach call_sv(NULL) from the native read loop.
 *
 * `context` is NULL at construction time, where the diagnostic has no prefix.
 */
void
les_require_read_sink(pTHX_ const les_descriptor_t *descriptor,
    const char *context)
{
    const char *problem;

    if (descriptor->read_mode == LES_READ_DELIVER)
        problem = descriptor->deliver_cb
            ? NULL : "readable raw Stream requires on_data callback";
    else
        problem = (descriptor->consumer_ops || descriptor->message_batch_size
                || descriptor->message_cb)
            ? NULL
            : "readable framed Stream requires on_message or a native consumer";

    if (!problem)
        return;
    if (context)
        croak("%s: %s", context, problem);
    croak("%s", problem);
}

/* Every counter is reported under its own field name, so the accessor used to
 * be 40 near-identical hv_stores() lines that had to be kept in sync with the
 * struct by hand. Table-driven instead: one row per counter, name and offset
 * together. */
typedef struct les_stat_field_s {
    const char *name;
    size_t offset;
} les_stat_field_t;

static const les_stat_field_t les_stat_fields[] = {
    { "activity_clock_calls", offsetof(les_xsstats_t, activity_clock_calls) },
    { "read_ready_calls", offsetof(les_xsstats_t, read_ready_calls) },
    { "read_calls", offsetof(les_xsstats_t, read_calls) },
    { "bytes_read", offsetof(les_xsstats_t, bytes_read) },
    { "read_eagain_count", offsetof(les_xsstats_t, read_eagain_count) },
    { "read_eintr_count", offsetof(les_xsstats_t, read_eintr_count) },
    { "eof_count", offsetof(les_xsstats_t, eof_count) },
    { "read_error_count", offsetof(les_xsstats_t, read_error_count) },
    { "delivery_calls", offsetof(les_xsstats_t, delivery_calls) },
    { "read_batch_flushes", offsetof(les_xsstats_t, read_batch_flushes) },
    { "read_batch_peak_bytes", offsetof(les_xsstats_t, read_batch_peak_bytes) },
    { "input_appends", offsetof(les_xsstats_t, input_appends) },
    { "input_compactions", offsetof(les_xsstats_t, input_compactions) },
    { "input_peak_bytes", offsetof(les_xsstats_t, input_peak_bytes) },
    { "delimiter_searches", offsetof(les_xsstats_t, delimiter_searches) },
    { "frames_emitted", offsetof(les_xsstats_t, frames_emitted) },
    { "message_callback_calls", offsetof(les_xsstats_t, message_callback_calls) },
    { "message_batch_calls", offsetof(les_xsstats_t, message_batch_calls) },
    { "message_batch_peak_messages", offsetof(les_xsstats_t, message_batch_peak_messages) },
    { "message_batch_peak_bytes", offsetof(les_xsstats_t, message_batch_peak_bytes) },
    { "framing_error_count", offsetof(les_xsstats_t, framing_error_count) },
    { "transition_count", offsetof(les_xsstats_t, transition_count) },
    { "consumer_message_calls", offsetof(les_xsstats_t, consumer_message_calls) },
    { "consumer_pause_count", offsetof(les_xsstats_t, consumer_pause_count) },
    { "consumer_resume_count", offsetof(les_xsstats_t, consumer_resume_count) },
    { "consumer_event_calls", offsetof(les_xsstats_t, consumer_event_calls) },
    { "consumer_flush_calls", offsetof(les_xsstats_t, consumer_flush_calls) },
    { "write_submit_calls", offsetof(les_xsstats_t, write_submit_calls) },
    { "write_ready_calls", offsetof(les_xsstats_t, write_ready_calls) },
    { "write_calls", offsetof(les_xsstats_t, write_calls) },
    { "writev_calls", offsetof(les_xsstats_t, writev_calls) },
    { "bytes_written", offsetof(les_xsstats_t, bytes_written) },
    { "write_eagain_count", offsetof(les_xsstats_t, write_eagain_count) },
    { "write_eintr_count", offsetof(les_xsstats_t, write_eintr_count) },
    { "write_error_count", offsetof(les_xsstats_t, write_error_count) },
    { "output_limit_count", offsetof(les_xsstats_t, output_limit_count) },
    { "queued_segments", offsetof(les_xsstats_t, queued_segments) },
    { "queue_peak_bytes", offsetof(les_xsstats_t, queue_peak_bytes) },
    { "drain_calls", offsetof(les_xsstats_t, drain_calls) },
    { "empty_calls", offsetof(les_xsstats_t, empty_calls) }
};

SV *
les_state_stats(pTHX_ les_xsstate_t *st)
{
    HV *hv = newHV();
    const char *base = (const char *)st->stats;
    size_t i;

    for (i = 0; i < sizeof(les_stat_fields) / sizeof(les_stat_fields[0]); i++) {
        const les_stat_field_t *field = &les_stat_fields[i];
        unsigned long long value;
        memcpy(&value, base + field->offset, sizeof(value));
        hv_store(hv, field->name, (I32)strlen(field->name),
            newSVuv((UV)value), 0);
    }

    /* Derived and configuration values, which are not counters. */
    hv_stores(hv, "read_budget_bytes",
        newSVuv(st->descriptor->read_budget_bytes));
    hv_stores(hv, "read_batch_bytes", newSVuv(st->descriptor->read_batch_bytes));
    hv_stores(hv, "message_batch_size",
        newSVuv(st->descriptor->message_batch_size));
    hv_stores(hv, "input_buffered_bytes", newSVuv(st->input_len));
    hv_stores(hv, "consumer_paused", newSViv(st->consumer_paused ? 1 : 0));
    hv_stores(hv, "pending_bytes", newSVuv(st->pending_bytes));
    hv_stores(hv, "write_blocked", newSViv(st->write_blocked ? 1 : 0));
    hv_stores(hv, "activity_tracking", newSViv(st->activity_tracking ? 1 : 0));

    return newRV_noinc((SV *)hv);
}

/* XSDescriptor::new used to take 29 positional arguments, which meant the
 * Perl caller and the XS signature had to agree on an order nothing enforced:
 * inserting a field in the wrong place silently shifted every later value.
 * It now takes a single hash, and these helpers read it by name. Unknown keys
 * are rejected so a typo fails loudly instead of defaulting to zero. */
static const char *const les_spec_keys[] = {
    "read_size", "read_budget_bytes", "read_batch_bytes", "message_batch_size",
    "high_watermark", "low_watermark", "max_pending_bytes", "max_buffer",
    "read_mode", "deliver_cb", "message_cb", "message_batch_cb", "drain_cb",
    "eof_cb", "read_error_cb", "write_error_cb", "output_limit_cb",
    "write_empty_cb", "framing_error_cb", "delimiter", "include_delimiter",
    "max_frame", "fixed_size", "prefix_bytes", "prefix_little",
    "include_prefix", "consumer_provider", "consumer_abi_version",
    "consumer_ops_address"
};

void
les_spec_check_keys(pTHX_ HV *spec)
{
    HE *entry;
    size_t i;

    hv_iterinit(spec);
    while ((entry = hv_iternext(spec))) {
        I32 len = 0;
        const char *key = hv_iterkey(entry, &len);
        int known = 0;
        for (i = 0; i < sizeof(les_spec_keys) / sizeof(les_spec_keys[0]); i++) {
            if (strEQ(key, les_spec_keys[i])) { known = 1; break; }
        }
        if (!known)
            croak("unknown Stream descriptor field '%s'", key);
    }
}

SV *
les_spec_sv(pTHX_ HV *spec, const char *key)
{
    SV **slot = hv_fetch(spec, key, (I32)strlen(key), 0);
    return slot ? *slot : NULL;
}

UV
les_spec_uv(pTHX_ HV *spec, const char *key)
{
    SV *sv = les_spec_sv(aTHX_ spec, key);
    return sv && SvOK(sv) ? SvUV(sv) : 0;
}

int
les_spec_int(pTHX_ HV *spec, const char *key)
{
    SV *sv = les_spec_sv(aTHX_ spec, key);
    return sv && SvOK(sv) ? (int)SvIV(sv) : 0;
}
