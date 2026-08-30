#ifndef LINUX_EVENT_FUTURE_NATIVE_H
#define LINUX_EVENT_FUTURE_NATIVE_H

#include "EXTERN.h"
#include "perl.h"

#define LEF_NATIVE_API_VERSION 3
#define LEF_NATIVE_API_KEY "Linux::Event::Future::_native_api_v3"
#define LEF_NATIVE_API_KEY_LEN (sizeof(LEF_NATIVE_API_KEY) - 1)

typedef struct lef_native_api_s {
    UV version;
    UV size;
    SV *(*new_pending)(pTHX_ SV *loop_sv);
    SV *(*new_done_one)(pTHX_ SV *loop_sv, SV *result);
    SV *(*new_done_one_take)(pTHX_ SV *result);
    int (*is_ready)(pTHX_ SV *future_obj);
    void (*done_one)(pTHX_ SV *future_obj, SV *result);
    int (*done_one_if_pending)(pTHX_ SV *future_obj, SV *result);
    int (*done_one_if_pending_take)(pTHX_ SV *future_obj, SV *result);
    void (*fail)(pTHX_ SV *future_obj, SV *failure);
    int (*fail_if_pending)(pTHX_ SV *future_obj, SV *failure);
} lef_native_api_t;

#endif
