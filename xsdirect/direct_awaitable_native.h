#ifndef LINUX_EVENT_DIRECT_AWAITABLE_NATIVE_H
#define LINUX_EVENT_DIRECT_AWAITABLE_NATIVE_H

#include "EXTERN.h"
#include "perl.h"

#define LEDA_NATIVE_API_VERSION 1
#define LEDA_NATIVE_API_KEY "Linux::Event::DirectAwaitable/native_api"
#define LEDA_NATIVE_API_KEY_LEN (sizeof(LEDA_NATIVE_API_KEY) - 1)

typedef struct leda_native_api_s {
    unsigned int version;
    size_t size;
    int (*is_ready)(pTHX_ SV *awaitable);
    void (*done_ref)(pTHX_ SV *awaitable, SV *result);
    void (*fail)(pTHX_ SV *awaitable, SV *failure);
} leda_native_api_t;

#endif
