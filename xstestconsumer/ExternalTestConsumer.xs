#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "stream_consumer_abi.h"

typedef struct le_external_test_consumer_s {
    const les_consumer_host_api_v1_t *host;
    void *host_context;
    SV *stream;
} le_external_test_consumer_t;

static UV le_external_destroyed = 0;

static void *
le_external_create(pTHX_ const les_consumer_host_api_v1_t *host,
    void *host_context, SV *stream)
{
    le_external_test_consumer_t *context;

    if (!host
        || host->abi_version != LES_CONSUMER_ABI_VERSION
        || host->struct_size < LES_CONSUMER_HOST_V1_RETAIN_REQUIRED_SIZE
        || !host->retain || !host->release)
        return NULL;

    Newxz(context, 1, le_external_test_consumer_t);
    if (!context)
        return NULL;

    context->host = host;
    context->host_context = host_context;
    context->stream = SvREFCNT_inc(stream);
    return context;
}

static int
le_external_input(pTHX_ void *opaque, const char *data, size_t length,
    size_t *consumed)
{
    le_external_test_consumer_t *context
        = (le_external_test_consumer_t *)opaque;

    PERL_UNUSED_CONTEXT;
    PERL_UNUSED_ARG(data);
    if (!context || !consumed)
        return LES_CONSUMER_ERROR;

    *consumed = length;
    return LES_CONSUMER_CONTINUE;
}

static void
le_external_event(pTHX_ void *opaque, uint32_t event, int error,
    const char *message)
{
    PERL_UNUSED_CONTEXT;
    PERL_UNUSED_ARG(opaque);
    PERL_UNUSED_ARG(event);
    PERL_UNUSED_ARG(error);
    PERL_UNUSED_ARG(message);
}

static void
le_external_destroy(pTHX_ void *opaque)
{
    le_external_test_consumer_t *context
        = (le_external_test_consumer_t *)opaque;

    PERL_UNUSED_CONTEXT;
    if (!context)
        return;

    if (context->stream)
        SvREFCNT_dec(context->stream);
    Safefree(context);
    le_external_destroyed++;
}

static const les_consumer_ops_v1_t le_external_ops = {
    LES_CONSUMER_ABI_VERSION,
    sizeof(les_consumer_ops_v1_t),
    "Linux::Event external raw-input test consumer",
    LES_CONSUMER_F_RAW_INPUT,
    le_external_create,
    NULL,
    le_external_event,
    le_external_destroy,
    NULL,
    le_external_input
};

MODULE = Linux::Event::_ByteStream::ExternalTestConsumer
    PACKAGE = Linux::Event::_ByteStream::ExternalTestConsumer
PROTOTYPES: DISABLE

UV
operations_address()
  CODE:
    RETVAL = PTR2UV(&le_external_ops);
  OUTPUT:
    RETVAL

UV
destroy_count()
  CODE:
    RETVAL = le_external_destroyed;
  OUTPUT:
    RETVAL
