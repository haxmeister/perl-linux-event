#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include "direct_awaitable_native.h"

enum {
    LEDA_PENDING = 0,
    LEDA_DONE = 1,
    LEDA_FAILED = 2
};

typedef struct leda_s {
    int state;
    SV *result;
    SV *failure;
    SV *callback;
} leda_t;

static leda_t *
leda_from_sv(SV *obj)
{
    leda_t *state;

    if (!sv_isobject(obj) || !SvROK(obj))
        croak("not a Linux::Event::DirectAwaitable object");
    state = INT2PTR(leda_t *, SvIV((SV *)SvRV(obj)));
    if (!state)
        croak("Linux::Event::DirectAwaitable object is destroyed");
    return state;
}

static SV *
leda_new(const char *class_name)
{
    leda_t *state;

    Newxz(state, 1, leda_t);
    state->state = LEDA_PENDING;
    return sv_bless(newRV_noinc(newSViv(PTR2IV(state))),
        gv_stashpv(class_name, GV_ADD));
}

static void
leda_require_callback(SV *callback)
{
    if (!callback || !SvROK(callback)
        || SvTYPE(SvRV(callback)) != SVt_PVCV)
        croak("DirectAwaitable callback must be a coderef");
}

static void
leda_notify(pTHX_ leda_t *state)
{
    SV *callback = state->callback;
    dSP;

    if (!callback)
        return;
    state->callback = NULL;
    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    PUTBACK;
    call_sv(callback, G_DISCARD | G_VOID);
    FREETMPS;
    LEAVE;
    SvREFCNT_dec(callback);
}

static void
leda_done_ref(pTHX_ leda_t *state, SV *result)
{
    if (state->state != LEDA_PENDING)
        croak("DirectAwaitable is already ready");
    state->result = newSVsv(result);
    state->state = LEDA_DONE;
    leda_notify(aTHX_ state);
}

static void
leda_done_take(pTHX_ leda_t *state, SV *result)
{
    if (state->state != LEDA_PENDING)
        croak("DirectAwaitable is already ready");
    state->result = result;
    state->state = LEDA_DONE;
    leda_notify(aTHX_ state);
}

static void
leda_fail(pTHX_ leda_t *state, SV *failure)
{
    if (state->state != LEDA_PENDING)
        croak("DirectAwaitable is already ready");
    state->failure = newSVsv(failure);
    state->state = LEDA_FAILED;
    leda_notify(aTHX_ state);
}

static SV *
leda_api_new_pending(pTHX)
{
    PERL_UNUSED_CONTEXT;
    return leda_new("Linux::Event::DirectAwaitable");
}

static int
leda_api_is_ready(pTHX_ SV *obj)
{
    PERL_UNUSED_CONTEXT;
    return leda_from_sv(obj)->state != LEDA_PENDING;
}

static void
leda_api_done_ref(pTHX_ SV *obj, SV *result)
{
    leda_done_ref(aTHX_ leda_from_sv(obj), result);
}

static void
leda_api_done_take(pTHX_ SV *obj, SV *result)
{
    leda_done_take(aTHX_ leda_from_sv(obj), result);
}

static void
leda_api_fail(pTHX_ SV *obj, SV *failure)
{
    leda_fail(aTHX_ leda_from_sv(obj), failure);
}

static const leda_native_api_t leda_native_api = {
    LEDA_NATIVE_API_VERSION,
    sizeof(leda_native_api_t),
    leda_api_new_pending,
    leda_api_is_ready,
    leda_api_done_ref,
    leda_api_done_take,
    leda_api_fail
};

MODULE = Linux::Event::DirectAwaitable    PACKAGE = Linux::Event::DirectAwaitable
PROTOTYPES: DISABLE

BOOT:
    {
        SV **slot = hv_fetch(PL_modglobal, LEDA_NATIVE_API_KEY,
            LEDA_NATIVE_API_KEY_LEN, 1);
        if (!slot)
            croak("could not register Linux::Event::DirectAwaitable native API");
        sv_setiv(*slot, PTR2IV(&leda_native_api));
    }

SV *
new(CLASS)
    const char *CLASS
  CODE:
    RETVAL = leda_new(CLASS);
  OUTPUT:
    RETVAL

SV *
AWAIT_CLONE(obj)
    SV *obj
  PREINIT:
    const char *class_name;
  CODE:
    if (leda_from_sv(obj)->state != LEDA_PENDING)
        croak("DirectAwaitable is already ready");
    class_name = HvNAME(SvSTASH(SvRV(obj)));
    RETVAL = leda_new(class_name);
  OUTPUT:
    RETVAL

SV *
AWAIT_DONE(obj, result = &PL_sv_undef)
    SV *obj
    SV *result
  CODE:
    leda_done_ref(aTHX_ leda_from_sv(obj), result);
    RETVAL = newSVsv(obj);
  OUTPUT:
    RETVAL

SV *
complete(obj, result = &PL_sv_undef)
    SV *obj
    SV *result
  CODE:
    leda_done_ref(aTHX_ leda_from_sv(obj), result);
    RETVAL = newSVsv(obj);
  OUTPUT:
    RETVAL

SV *
AWAIT_FAIL(obj, failure)
    SV *obj
    SV *failure
  CODE:
    leda_fail(aTHX_ leda_from_sv(obj), failure);
    RETVAL = newSVsv(obj);
  OUTPUT:
    RETVAL

int
AWAIT_IS_READY(obj)
    SV *obj
  CODE:
    RETVAL = leda_from_sv(obj)->state != LEDA_PENDING;
  OUTPUT:
    RETVAL

int
AWAIT_IS_CANCELLED(obj)
    SV *obj
  CODE:
    PERL_UNUSED_VAR(obj);
    RETVAL = 0;
  OUTPUT:
    RETVAL

void
AWAIT_GET(obj)
    SV *obj
  PREINIT:
    leda_t *state;
  PPCODE:
    state = leda_from_sv(obj);
    if (state->state == LEDA_PENDING)
        croak("DirectAwaitable is not ready");
    if (state->state == LEDA_FAILED)
        croak_sv(state->failure);
    if (GIMME_V != G_VOID)
        PUSHs(state->result
            ? sv_2mortal(newSVsv(state->result)) : &PL_sv_undef);

void
AWAIT_ON_READY(obj, callback)
    SV *obj
    SV *callback
  PREINIT:
    leda_t *state;
    dSP;
  CODE:
    leda_require_callback(callback);
    state = leda_from_sv(obj);
    if (state->state != LEDA_PENDING) {
        ENTER;
        SAVETMPS;
        PUSHMARK(SP);
        PUTBACK;
        call_sv(callback, G_DISCARD | G_VOID);
        FREETMPS;
        LEAVE;
    } else {
        if (state->callback)
            croak("DirectAwaitable already has a waiter");
        state->callback = newSVsv(callback);
    }

void
AWAIT_ON_CANCEL(obj, callback)
    SV *obj
    SV *callback
  CODE:
    PERL_UNUSED_VAR(obj);
    PERL_UNUSED_VAR(callback);

void
AWAIT_CHAIN_CANCEL(obj, target)
    SV *obj
    SV *target
  CODE:
    PERL_UNUSED_VAR(obj);
    PERL_UNUSED_VAR(target);

void
DESTROY(obj)
    SV *obj
  PREINIT:
    leda_t *state;
  CODE:
    if (sv_isobject(obj) && SvROK(obj)) {
        state = INT2PTR(leda_t *, SvIV((SV *)SvRV(obj)));
        if (state) {
            if (state->result) SvREFCNT_dec(state->result);
            if (state->failure) SvREFCNT_dec(state->failure);
            if (state->callback) SvREFCNT_dec(state->callback);
            Safefree(state);
            sv_setiv(SvRV(obj), 0);
        }
    }
