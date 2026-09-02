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
