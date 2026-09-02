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

void
les_require_read_sink(pTHX_ const les_descriptor_t *descriptor, int read_fd,
    const char *raw_error, const char *framed_error)
{
    if (read_fd < 0)
        return;
    if (descriptor->read_mode == LES_READ_DELIVER) {
        if (!descriptor->deliver_cb)
            croak("%s", raw_error);
        return;
    }
    if (!descriptor->consumer_ops && !descriptor->message_batch_size
        && !descriptor->message_cb)
        croak("%s", framed_error);
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

typedef struct les_stat_field_s {
    const char *name;
    I32 name_length;
    size_t offset;
} les_stat_field_t;

#define LES_STAT_FIELD(name) \
    { #name, (I32)(sizeof(#name) - 1), offsetof(les_xsstats_t, name) }

static const les_stat_field_t les_stat_fields[] = {
    LES_STAT_FIELD(activity_clock_calls),
    LES_STAT_FIELD(read_ready_calls),
    LES_STAT_FIELD(read_calls),
    LES_STAT_FIELD(bytes_read),
    LES_STAT_FIELD(read_eagain_count),
    LES_STAT_FIELD(read_eintr_count),
    LES_STAT_FIELD(eof_count),
    LES_STAT_FIELD(read_error_count),
    LES_STAT_FIELD(delivery_calls),
    LES_STAT_FIELD(read_batch_flushes),
    LES_STAT_FIELD(read_batch_peak_bytes),
    LES_STAT_FIELD(input_appends),
    LES_STAT_FIELD(input_compactions),
    LES_STAT_FIELD(input_peak_bytes),
    LES_STAT_FIELD(delimiter_searches),
    LES_STAT_FIELD(frames_emitted),
    LES_STAT_FIELD(message_callback_calls),
    LES_STAT_FIELD(message_batch_calls),
    LES_STAT_FIELD(message_batch_peak_messages),
    LES_STAT_FIELD(message_batch_peak_bytes),
    LES_STAT_FIELD(framing_error_count),
    LES_STAT_FIELD(transition_count),
    LES_STAT_FIELD(consumer_message_calls),
    LES_STAT_FIELD(consumer_pause_count),
    LES_STAT_FIELD(consumer_resume_count),
    LES_STAT_FIELD(consumer_event_calls),
    LES_STAT_FIELD(consumer_flush_calls),
    LES_STAT_FIELD(write_submit_calls),
    LES_STAT_FIELD(write_ready_calls),
    LES_STAT_FIELD(write_calls),
    LES_STAT_FIELD(writev_calls),
    LES_STAT_FIELD(bytes_written),
    LES_STAT_FIELD(write_eagain_count),
    LES_STAT_FIELD(write_eintr_count),
    LES_STAT_FIELD(write_error_count),
    LES_STAT_FIELD(output_limit_count),
    LES_STAT_FIELD(queued_segments),
    LES_STAT_FIELD(queue_peak_bytes),
    LES_STAT_FIELD(drain_calls),
    LES_STAT_FIELD(empty_calls),
};

#undef LES_STAT_FIELD

SV *
les_state_stats(pTHX_ les_xsstate_t *st)
{
    HV *hv = newHV();
    const char *base = (const char *)&st->stats;
    size_t i;

    for (i = 0; i < sizeof(les_stat_fields) / sizeof(les_stat_fields[0]); i++) {
        const les_stat_field_t *field = &les_stat_fields[i];
        unsigned long long value;

        memcpy(&value, base + field->offset, sizeof(value));
        hv_store(hv, field->name, field->name_length,
            newSVuv((UV)value), 0);
    }

    hv_stores(hv, "read_budget_bytes",
        newSVuv(st->descriptor->read_budget_bytes));
    hv_stores(hv, "read_batch_bytes",
        newSVuv(st->descriptor->read_batch_bytes));
    hv_stores(hv, "message_batch_size",
        newSVuv(st->descriptor->message_batch_size));
    hv_stores(hv, "input_buffered_bytes", newSVuv(st->input_len));
    hv_stores(hv, "consumer_flush_pending",
        newSViv(st->consumer_flush_pending ? 1 : 0));
    hv_stores(hv, "consumer_paused",
        newSViv(st->consumer_paused ? 1 : 0));
    hv_stores(hv, "pending_bytes", newSVuv(st->pending_bytes));
    hv_stores(hv, "write_blocked", newSViv(st->write_blocked ? 1 : 0));
    hv_stores(hv, "activity_tracking",
        newSViv(st->activity_tracking ? 1 : 0));

    return newRV_noinc((SV *)hv);
}

void
les_state_destroy(pTHX_ les_xsstate_t *st)
{
    if (!st)
        return;
    les_clear_write_queue(st);
    les_discard_message_batch(st);
    les_consumer_destroy(aTHX_ st);
    if (st->stream_sv) SvREFCNT_dec(st->stream_sv);
    if (st->descriptor_sv) SvREFCNT_dec(st->descriptor_sv);
    if (st->transport_provider_sv) SvREFCNT_dec(st->transport_provider_sv);
    free(st->read_buffer);
    free(st->input_buffer);
    free(st);
}
