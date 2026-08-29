#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include "future_native.h"

enum {
    LEF_PENDING = 0,
    LEF_DONE = 1,
    LEF_FAILED = 2,
    LEF_CANCELLED = 3
};

typedef struct lef_future_s {
    int state;
    SV *loop_sv;
    SV *result;
    AV *results;
    SV *failure;
    SV *ready_callback;
    AV *ready_callbacks;
    AV *cancel_callbacks;
    AV *cancel_chain;
} lef_future_t;

static lef_future_t *
lef_from_sv(SV *future_obj)
{
    lef_future_t *future;

    if (!sv_isobject(future_obj) || !SvROK(future_obj))
        croak("not a Linux::Event::Future object");
    future = INT2PTR(lef_future_t *, SvIV((SV *)SvRV(future_obj)));
    if (!future)
        croak("Linux::Event::Future object is destroyed");
    return future;
}

static SV *
lef_new_stash(HV *stash, SV *loop_sv)
{
    lef_future_t *future;

    Newxz(future, 1, lef_future_t);
    future->state = LEF_PENDING;
    if (loop_sv && SvOK(loop_sv))
        future->loop_sv = newSVsv(loop_sv);
    return sv_bless(newRV_noinc(newSViv(PTR2IV(future))),
        stash);
}

static SV *
lef_new(const char *class_name, SV *loop_sv)
{
    return lef_new_stash(gv_stashpv(class_name, GV_ADD), loop_sv);
}

static void
lef_require_pending(lef_future_t *future)
{
    if (future->state != LEF_PENDING)
        croak("Future is already ready");
}

static void
lef_require_callback(SV *callback)
{
    if (!callback || !SvROK(callback)
        || SvTYPE(SvRV(callback)) != SVt_PVCV)
        croak("Future callback must be a coderef");
}

static void
lef_call_callback(pTHX_ SV *callback)
{
    dSP;

    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    PUTBACK;
    call_sv(callback, G_DISCARD | G_VOID);
    FREETMPS;
    LEAVE;
}

static void
lef_call_callbacks(pTHX_ AV *callbacks, SV **failure)
{
    SSize_t index;
    SSize_t last;

    if (!callbacks)
        return;
    last = av_count(callbacks) - 1;
    for (index = 0; index <= last; index++) {
        SV **callback = av_fetch(callbacks, index, 0);
        if (callback && *callback) {
            dSP;

            ENTER;
            SAVETMPS;
            PUSHMARK(SP);
            PUTBACK;
            call_sv(*callback, G_DISCARD | G_VOID | G_EVAL);
            if (SvTRUE(ERRSV)) {
                if (!*failure)
                    *failure = newSVsv(ERRSV);
                sv_setsv(ERRSV, &PL_sv_undef);
            }
            FREETMPS;
            LEAVE;
        }
    }
    SvREFCNT_dec((SV *)callbacks);
}

static void
lef_call_callback_catching(pTHX_ SV *callback, SV **failure)
{
    dSP;

    if (!callback)
        return;
    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    PUTBACK;
    call_sv(callback, G_DISCARD | G_VOID | G_EVAL);
    if (SvTRUE(ERRSV)) {
        if (!*failure)
            *failure = newSVsv(ERRSV);
        sv_setsv(ERRSV, &PL_sv_undef);
    }
    FREETMPS;
    LEAVE;
    SvREFCNT_dec(callback);
}

static void
lef_add_callback(SV **single, AV **overflow, SV *callback)
{
    if (!*single) {
        *single = newSVsv(callback);
        return;
    }
    if (!*overflow)
        *overflow = newAV();
    av_push(*overflow, newSVsv(callback));
}

static void
lef_cancel_chained(pTHX_ AV *chain, SV **failure)
{
    SSize_t index;
    SSize_t last;

    if (!chain)
        return;
    last = av_count(chain) - 1;
    for (index = 0; index <= last; index++) {
        SV **target = av_fetch(chain, index, 0);
        dSP;

        if (!target || !*target)
            continue;
        ENTER;
        SAVETMPS;
        PUSHMARK(SP);
        PUSHs(*target);
        PUTBACK;
        call_method("cancel", G_DISCARD | G_VOID | G_EVAL);
        if (SvTRUE(ERRSV)) {
            if (!*failure)
                *failure = newSVsv(ERRSV);
            sv_setsv(ERRSV, &PL_sv_undef);
        }
        FREETMPS;
        LEAVE;
    }
    SvREFCNT_dec((SV *)chain);
}

static void
lef_notify_ready(pTHX_ lef_future_t *future)
{
    SV *callback = future->ready_callback;
    AV *callbacks = future->ready_callbacks;
    SV *failure = NULL;

    future->ready_callback = NULL;
    future->ready_callbacks = NULL;
    lef_call_callback_catching(aTHX_ callback, &failure);
    lef_call_callbacks(aTHX_ callbacks, &failure);
    if (failure)
        croak_sv(sv_2mortal(failure));
}

static void
lef_discard_cancel_state(lef_future_t *future)
{
    if (future->cancel_callbacks) {
        SvREFCNT_dec((SV *)future->cancel_callbacks);
        future->cancel_callbacks = NULL;
    }
    if (future->cancel_chain) {
        SvREFCNT_dec((SV *)future->cancel_chain);
        future->cancel_chain = NULL;
    }
}

static void
lef_set_done(pTHX_ lef_future_t *future, I32 first, I32 last, SV **stack)
{
    I32 count;
    I32 index;

    lef_require_pending(future);
    count = last >= first ? last - first + 1 : 0;
    if (count == 1) {
        future->result = newSVsv(stack[first]);
    } else if (count > 1) {
        future->results = newAV();
        for (index = first; index <= last; index++)
            av_push(future->results, newSVsv(stack[index]));
    }
    future->state = LEF_DONE;
    lef_discard_cancel_state(future);
    lef_notify_ready(aTHX_ future);
}

static void
lef_set_failed(pTHX_ lef_future_t *future, SV *failure)
{
    lef_require_pending(future);
    future->failure = newSVsv(failure);
    future->state = LEF_FAILED;
    lef_discard_cancel_state(future);
    lef_notify_ready(aTHX_ future);
}

static SV *
lef_api_new_pending(pTHX_ SV *loop_sv)
{
    PERL_UNUSED_CONTEXT;
    return lef_new("Linux::Event::Future", loop_sv);
}

static int
lef_api_is_ready(pTHX_ SV *future_obj)
{
    PERL_UNUSED_CONTEXT;
    return lef_from_sv(future_obj)->state != LEF_PENDING;
}

static SV *
lef_api_new_done_one(pTHX_ SV *loop_sv, SV *result)
{
    SV *future_obj = lef_new("Linux::Event::Future", loop_sv);
    lef_future_t *future = lef_from_sv(future_obj);

    future->result = SvREFCNT_inc_simple_NN(result);
    future->state = LEF_DONE;
    return future_obj;
}

static void
lef_api_done_one(pTHX_ SV *future_obj, SV *result)
{
    SV *values[1];

    values[0] = result;
    lef_set_done(aTHX_ lef_from_sv(future_obj), 0, 0, values);
}

static void
lef_api_fail(pTHX_ SV *future_obj, SV *failure)
{
    lef_set_failed(aTHX_ lef_from_sv(future_obj), failure);
}

static const lef_native_api_t lef_native_api = {
    LEF_NATIVE_API_VERSION,
    sizeof(lef_native_api_t),
    lef_api_new_pending,
    lef_api_new_done_one,
    lef_api_is_ready,
    lef_api_done_one,
    lef_api_fail
};

MODULE = Linux::Event::Future    PACKAGE = Linux::Event::Future
PROTOTYPES: DISABLE

BOOT:
    {
        SV **slot = hv_fetch(PL_modglobal, LEF_NATIVE_API_KEY,
            LEF_NATIVE_API_KEY_LEN, 1);
        if (!slot)
            croak("could not register Linux::Event::Future native API");
        sv_setiv(*slot, PTR2IV(&lef_native_api));
    }

SV *
new(CLASS, loop = &PL_sv_undef)
    const char *CLASS
    SV *loop
  CODE:
    if (loop && SvOK(loop)
        && (!sv_isobject(loop)
            || !sv_derived_from(loop, "Linux::Event::Loop")))
        croak("Future Loop must be a Linux::Event::Loop object");
    RETVAL = lef_new(CLASS, loop);
  OUTPUT:
    RETVAL

SV *
AWAIT_NEW_DONE(CLASS, ...)
    const char *CLASS
  PREINIT:
    lef_future_t *future;
  CODE:
    RETVAL = lef_new(CLASS, NULL);
    future = lef_from_sv(RETVAL);
    lef_set_done(aTHX_ future, 1, items - 1, &ST(0));
  OUTPUT:
    RETVAL

SV *
AWAIT_NEW_FAIL(CLASS, failure)
    const char *CLASS
    SV *failure
  PREINIT:
    lef_future_t *future;
  CODE:
    RETVAL = lef_new(CLASS, NULL);
    future = lef_from_sv(RETVAL);
    lef_set_failed(aTHX_ future, failure);
  OUTPUT:
    RETVAL

SV *
AWAIT_CLONE(future_obj)
    SV *future_obj
  PREINIT:
    lef_future_t *future;
    const char *class_name;
  CODE:
    future = lef_from_sv(future_obj);
    lef_require_pending(future);
    class_name = HvNAME(SvSTASH(SvRV(future_obj)));
    RETVAL = lef_new(class_name, future->loop_sv);
  OUTPUT:
    RETVAL

SV *
AWAIT_DONE(future_obj, ...)
    SV *future_obj
  PREINIT:
    lef_future_t *future;
  CODE:
    future = lef_from_sv(future_obj);
    lef_set_done(aTHX_ future, 1, items - 1, &ST(0));
    RETVAL = newSVsv(future_obj);
  OUTPUT:
    RETVAL

SV *
AWAIT_FAIL(future_obj, failure)
    SV *future_obj
    SV *failure
  PREINIT:
    lef_future_t *future;
  CODE:
    future = lef_from_sv(future_obj);
    lef_set_failed(aTHX_ future, failure);
    RETVAL = newSVsv(future_obj);
  OUTPUT:
    RETVAL

int
AWAIT_IS_READY(future_obj)
    SV *future_obj
  CODE:
    RETVAL = lef_from_sv(future_obj)->state != LEF_PENDING;
  OUTPUT:
    RETVAL

int
AWAIT_IS_CANCELLED(future_obj)
    SV *future_obj
  CODE:
    RETVAL = lef_from_sv(future_obj)->state == LEF_CANCELLED;
  OUTPUT:
    RETVAL

void
AWAIT_GET(future_obj)
    SV *future_obj
  PREINIT:
    lef_future_t *future;
    SSize_t count;
    SSize_t index;
    SV **value;
  PPCODE:
    future = lef_from_sv(future_obj);
    if (future->state == LEF_PENDING)
        croak("Future is not ready");
    if (future->state == LEF_CANCELLED)
        croak("Future was cancelled");
    if (future->state == LEF_FAILED)
        croak_sv(future->failure);

    count = future->result ? 1
        : (future->results ? av_count(future->results) : 0);
    if (GIMME_V == G_VOID)
        XSRETURN_EMPTY;
    if (GIMME_V == G_SCALAR) {
        if (future->result)
            PUSHs(sv_2mortal(newSVsv(future->result)));
        else {
            value = count ? av_fetch(future->results, 0, 0) : NULL;
            PUSHs(value && *value
                ? sv_2mortal(newSVsv(*value)) : &PL_sv_undef);
        }
        XSRETURN(1);
    }
    EXTEND(SP, count);
    if (future->result) {
        PUSHs(sv_2mortal(newSVsv(future->result)));
        XSRETURN(1);
    }
    for (index = 0; index < count; index++) {
        value = av_fetch(future->results, index, 0);
        PUSHs(value && *value
            ? sv_2mortal(newSVsv(*value)) : &PL_sv_undef);
    }

void
AWAIT_ON_READY(future_obj, callback)
    SV *future_obj
    SV *callback
  PREINIT:
    lef_future_t *future;
  CODE:
    lef_require_callback(callback);
    future = lef_from_sv(future_obj);
    if (future->state != LEF_PENDING) {
        lef_call_callback(aTHX_ callback);
    } else {
        lef_add_callback(&future->ready_callback,
            &future->ready_callbacks, callback);
    }

void
AWAIT_ON_CANCEL(future_obj, callback)
    SV *future_obj
    SV *callback
  PREINIT:
    lef_future_t *future;
  CODE:
    lef_require_callback(callback);
    future = lef_from_sv(future_obj);
    if (future->state == LEF_CANCELLED) {
        lef_call_callback(aTHX_ callback);
    } else if (future->state == LEF_PENDING) {
        if (!future->cancel_callbacks)
            future->cancel_callbacks = newAV();
        av_push(future->cancel_callbacks, newSVsv(callback));
    }

void
AWAIT_CHAIN_CANCEL(future_obj, target)
    SV *future_obj
    SV *target
  PREINIT:
    lef_future_t *future;
  CODE:
    if (!sv_isobject(target) || !SvROK(target))
        croak("cancellation target must be an object");
    future = lef_from_sv(future_obj);
    if (future->state == LEF_CANCELLED) {
        ENTER;
        SAVETMPS;
        PUSHMARK(SP);
        PUSHs(target);
        PUTBACK;
        call_method("cancel", G_DISCARD | G_VOID);
        FREETMPS;
        LEAVE;
    } else if (future->state == LEF_PENDING) {
        if (!future->cancel_chain)
            future->cancel_chain = newAV();
        av_push(future->cancel_chain, newSVsv(target));
    }

SV *
cancel(future_obj)
    SV *future_obj
  PREINIT:
    lef_future_t *future;
    AV *cancel_callbacks;
    AV *cancel_chain;
    SV *ready_callback;
    AV *ready_callbacks;
    SV *failure = NULL;
  CODE:
    future = lef_from_sv(future_obj);
    if (future->state == LEF_PENDING) {
        cancel_callbacks = future->cancel_callbacks;
        cancel_chain = future->cancel_chain;
        ready_callback = future->ready_callback;
        ready_callbacks = future->ready_callbacks;
        future->cancel_callbacks = NULL;
        future->cancel_chain = NULL;
        future->ready_callback = NULL;
        future->ready_callbacks = NULL;
        future->state = LEF_CANCELLED;
        lef_call_callbacks(aTHX_ cancel_callbacks, &failure);
        lef_cancel_chained(aTHX_ cancel_chain, &failure);
        lef_call_callback_catching(aTHX_ ready_callback, &failure);
        lef_call_callbacks(aTHX_ ready_callbacks, &failure);
        if (failure)
            croak_sv(sv_2mortal(failure));
    }
    RETVAL = newSVsv(future_obj);
  OUTPUT:
    RETVAL

SV *
loop(future_obj)
    SV *future_obj
  PREINIT:
    lef_future_t *future;
  CODE:
    future = lef_from_sv(future_obj);
    RETVAL = future->loop_sv ? newSVsv(future->loop_sv) : &PL_sv_undef;
  OUTPUT:
    RETVAL

void
DESTROY(future_obj)
    SV *future_obj
  PREINIT:
    lef_future_t *future;
  CODE:
    if (sv_isobject(future_obj) && SvROK(future_obj)) {
        future = INT2PTR(lef_future_t *, SvIV((SV *)SvRV(future_obj)));
        if (future) {
            if (future->loop_sv) SvREFCNT_dec(future->loop_sv);
            if (future->result) SvREFCNT_dec(future->result);
            if (future->results) SvREFCNT_dec((SV *)future->results);
            if (future->failure) SvREFCNT_dec(future->failure);
            if (future->ready_callback)
                SvREFCNT_dec(future->ready_callback);
            if (future->ready_callbacks)
                SvREFCNT_dec((SV *)future->ready_callbacks);
            if (future->cancel_callbacks)
                SvREFCNT_dec((SV *)future->cancel_callbacks);
            if (future->cancel_chain)
                SvREFCNT_dec((SV *)future->cancel_chain);
            Safefree(future);
            sv_setiv(SvRV(future_obj), 0);
        }
    }
