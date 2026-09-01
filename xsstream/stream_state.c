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
