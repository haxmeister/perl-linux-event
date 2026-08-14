/*
 * Linux::Event XS reactor core
 * ============================
 *
 * This file contains the native implementation behind Linux::Event::XSLoop
 * and Linux::Event::XSWatcher.  The design goal is a short readiness path:
 *
 *     epoll_wait()
 *       -> epoll_event.data.ptr
 *       -> le_watcher_t *
 *       -> native dispatch
 *       -> one Perl callback
 *
 * The fd-indexed registry is intentionally not used for hot-path lookup after
 * epoll_wait(); it exists for registration, replacement, cancellation and
 * lifecycle operations.  epoll_event.data.ptr points directly at the watcher.
 *
 * The core is a reactor, not a stream implementation.  It reports descriptor
 * readiness and deliberately leaves sysread/syswrite/buffering policy to the
 * caller. Native buffering, write queues, and framing live in the higher-level
 * Linux::Event::Stream layer so the raw watcher API remains general.
 *
 * Lifetime invariant
 * ------------------
 * le_loop_t owns all native le_watcher_t records.  Perl XSWatcher objects are
 * handles into loop-owned state.  Returned epoll batches may still contain a
 * watcher pointer after EPOLL_CTL_DEL, so any optional reuse/reclaim path must
 * not recycle a watcher until the current dispatch batch is finished.
 *
 * Callback invariant
 * ------------------
 * For one epoll event terminal/error readiness is handled before read and
 * write readiness.  The watcher is re-checked after callbacks so a callback
 * may cancel itself safely.  Plain coderefs are stored as direct CVs to avoid
 * an extra RV layer on the hot call path.
 *
 * Profiling
 * ---------
 * Cheap counters are always available.  Nanosecond timing is opt-in because
 * measuring each hot operation changes the workload.  Benchmark-only native
 * echo code remains private and is explicitly marked below.
 */

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <sys/epoll.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <time.h>
#include <limits.h>

#ifndef EPOLLRDHUP
#define EPOLLRDHUP 0x2000
#endif

#define LE_INITIAL_EVENTS 8192
#define LE_INITIAL_REGISTRY 1024
#define LE_CALLBACK_SCOPE_DEFAULT 128

typedef struct le_loop_s le_loop_t;
typedef struct le_watcher_s le_watcher_t;

/*
 * Native watcher record.
 *
 * Callback SVs live here so readiness dispatch does not need a Perl hash or
 * method lookup. Accessor references are optional: lean no-argument watchers
 * can omit them when user code captures its state in the callback closure.
 */
struct le_watcher_s {
    le_watcher_t *next_free;
    int fd;
    uint32_t mask;
    uint32_t flags;
    int active;
    le_loop_t *loop;
    SV *self_sv;
    SV *loop_sv;
    SV *fh_sv;
    SV *data_sv;
    SV *read_cb;
    SV *write_cb;
    SV *error_cb;
    int read_cb_direct_cv;
    int write_cb_direct_cv;
    int error_cb_direct_cv;
    int callback_args;
    int callback_arg_data;
    int lean;
    int bench_native_echo;
};

/*
 * Native loop state.
 *
 * The reusable epoll event array and fd registry are allocated once and kept
 * with the loop. Counters are colocated here so instrumentation does not need
 * Perl-side bookkeeping.
 */
struct le_loop_s {
    int epoll_fd;
    int stop_flag;
    size_t event_cap;
    struct epoll_event *events;
    size_t reg_cap;
    le_watcher_t **registry;
    unsigned long long epoll_wait_calls;
    unsigned long long epoll_wait_empty_calls;
    unsigned long long epoll_wait_full_batches;
    unsigned long long epoll_wait_max_batch;
    unsigned long long ready_events_returned;
    unsigned long long ready_read_events;
    unsigned long long ready_write_events;
    unsigned long long ready_error_events;
    unsigned long long ready_epollerr_events;
    unsigned long long ready_hup_events;
    unsigned long long ready_rdhup_events;
    unsigned long long ready_in_hup_events;
    unsigned long long ready_in_rdhup_events;
    unsigned long long ready_multi_events;
    unsigned long long callback_calls;
    unsigned long long read_callback_calls;
    unsigned long long write_callback_calls;
    unsigned long long error_callback_calls;
    unsigned long long epoll_ctl_add_calls;
    unsigned long long epoll_ctl_mod_calls;
    unsigned long long epoll_ctl_del_calls;
    unsigned long long watcher_lookup_calls;
    unsigned long long direct_watcher_events;
    unsigned long long dispatch_events;
    unsigned long long callback_noarg_calls;
    unsigned long long callback_onearg_calls;
    unsigned long long callback_direct_cv_calls;
    unsigned long long callback_sv_calls;
    unsigned long long callback_batch_scope_enters;
    unsigned long long callback_scope_rotations;
    unsigned long long callback_scope_max_callbacks;
    unsigned int callback_scope_limit;
    unsigned long long run_once_calls;
    unsigned long long run_calls;
    unsigned long long run_for_calls;
    unsigned long long bench_native_echo_read_events;
    unsigned long long bench_native_echo_perl_read_callbacks;
    unsigned long long bench_native_echo_sysread_calls;
    unsigned long long bench_native_echo_syswrite_calls;
    unsigned long long bench_native_echo_bytes_read;
    unsigned long long bench_native_echo_bytes_written;
    unsigned long long bench_native_echo_read_eagain;
    unsigned long long bench_native_echo_write_eagain;
    unsigned long long bench_native_echo_partial_writes;
    unsigned long long bench_native_echo_read_zero;
    unsigned long long bench_native_echo_errors;
    unsigned long long lean_watchers;
    unsigned long long watcher_alloc_calls;
    unsigned long long watcher_reuse_calls;
    unsigned long long watcher_recycle_calls;
    unsigned long long watcher_destroy_calls;
    unsigned long long watcher_freelist_depth;
    unsigned long long watcher_freelist_max_depth;
    int watcher_reclaim_enabled;
    int in_dispatch_batch;
    le_watcher_t *watcher_freelist;
    le_watcher_t *watcher_pending;
    int profile_enabled;
    unsigned long long epoll_wait_ns;
    unsigned long long epoll_ctl_add_ns;
    unsigned long long epoll_ctl_mod_ns;
    unsigned long long epoll_ctl_del_ns;
    unsigned long long watcher_lookup_ns;
    unsigned long long callback_ns;
    unsigned long long dispatch_ns;
};

/* ---- Cheap readiness and epoll instrumentation ----------------------- */

static void le_note_epoll_batch(le_loop_t *loop, int n) {
    loop->epoll_wait_calls++;
    if (n == 0) loop->epoll_wait_empty_calls++;
    if (n == (int)loop->event_cap) loop->epoll_wait_full_batches++;
    if ((unsigned long long)n > loop->epoll_wait_max_batch) loop->epoll_wait_max_batch = (unsigned long long)n;
    loop->ready_events_returned += (unsigned long long)n;
}

static void le_note_ready_flags(le_loop_t *loop, uint32_t events) {
    int buckets = 0;
    if (events & EPOLLERR) loop->ready_epollerr_events++;
    if (events & EPOLLHUP) loop->ready_hup_events++;
    if (events & EPOLLRDHUP) loop->ready_rdhup_events++;
    if ((events & EPOLLIN) && (events & EPOLLHUP)) loop->ready_in_hup_events++;
    if ((events & EPOLLIN) && (events & EPOLLRDHUP)) loop->ready_in_rdhup_events++;
    if (events & (EPOLLERR | EPOLLHUP | EPOLLRDHUP)) { loop->ready_error_events++; buckets++; }
    if (events & EPOLLIN)  { loop->ready_read_events++;  buckets++; }
    if (events & EPOLLOUT) { loop->ready_write_events++; buckets++; }
    if (buckets > 1) loop->ready_multi_events++;
}

static unsigned long long le_now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ((unsigned long long)ts.tv_sec * 1000000000ULL) + (unsigned long long)ts.tv_nsec;
}

static int le_epoll_ctl_timed(le_loop_t *loop, int op, int fd, struct epoll_event *ev) {
    unsigned long long t0 = 0;
    if (loop && loop->profile_enabled) t0 = le_now_ns();
    int rc = epoll_ctl(loop->epoll_fd, op, fd, ev);
    if (loop) {
        unsigned long long *calls = NULL;
        unsigned long long *ns = NULL;
        if (op == EPOLL_CTL_ADD) { calls = &loop->epoll_ctl_add_calls; ns = &loop->epoll_ctl_add_ns; }
        else if (op == EPOLL_CTL_MOD) { calls = &loop->epoll_ctl_mod_calls; ns = &loop->epoll_ctl_mod_ns; }
        else if (op == EPOLL_CTL_DEL) { calls = &loop->epoll_ctl_del_calls; ns = &loop->epoll_ctl_del_ns; }
        if (calls) (*calls)++;
        if (ns && loop->profile_enabled) (*ns) += le_now_ns() - t0;
    }
    return rc;
}

/* ---- Perl object <-> native pointer conversion ---------------------- */

static le_loop_t *le_loop_from_sv(SV *sv) {
    if (!sv_isobject(sv) || !SvROK(sv)) croak("not a loop object");
    return INT2PTR(le_loop_t *, SvIV((SV*)SvRV(sv)));
}

static le_watcher_t *le_watcher_from_sv(SV *sv) {
    if (!sv_isobject(sv) || !SvROK(sv)) croak("not a watcher object");
    return INT2PTR(le_watcher_t *, SvIV((SV*)SvRV(sv)));
}

/* ---- Native fd registry --------------------------------------------- */

static void le_registry_grow(le_loop_t *loop, int fd) {
    if (fd < 0) croak("negative fd");
    if ((size_t)fd < loop->reg_cap) return;
    size_t new_cap = loop->reg_cap ? loop->reg_cap : LE_INITIAL_REGISTRY;
    while ((size_t)fd >= new_cap) new_cap *= 2;
    le_watcher_t **new_reg = (le_watcher_t **)calloc(new_cap, sizeof(le_watcher_t *));
    if (!new_reg) croak("calloc registry failed");
    if (loop->registry) {
        memcpy(new_reg, loop->registry, loop->reg_cap * sizeof(le_watcher_t *));
        free(loop->registry);
    }
    loop->registry = new_reg;
    loop->reg_cap = new_cap;
}

static uint32_t le_mask_from_callbacks(SV *read_cb, SV *write_cb) {
    uint32_t mask = EPOLLERR | EPOLLHUP | EPOLLRDHUP;
    if (read_cb && SvOK(read_cb))  mask |= EPOLLIN;
    if (write_cb && SvOK(write_cb)) mask |= EPOLLOUT;
    return mask;
}

static uint32_t le_epoll_events(le_watcher_t *w) {
    return w->mask | w->flags;
}

static SV *le_stored_callback_from_sv(SV *cb, int *direct_cv) {
    if (direct_cv) *direct_cv = 0;
    if (!cb || !SvOK(cb)) return NULL;
    if (SvROK(cb) && SvTYPE(SvRV(cb)) == SVt_PVCV) {
        if (direct_cv) *direct_cv = 1;
        return SvREFCNT_inc_NN(SvRV(cb));
    }
    return newSVsv(cb);
}

/* ---- Watcher allocation, ownership and safe deferred reuse ---------- */

static void le_watcher_clear_refs(le_watcher_t *w) {
    if (!w) return;
    if (w->read_cb)  { SvREFCNT_dec(w->read_cb);  w->read_cb = NULL; }
    if (w->write_cb) { SvREFCNT_dec(w->write_cb); w->write_cb = NULL; }
    if (w->error_cb) { SvREFCNT_dec(w->error_cb); w->error_cb = NULL; }
    if (w->data_sv)  { SvREFCNT_dec(w->data_sv);  w->data_sv = NULL; }
    if (w->fh_sv)    { SvREFCNT_dec(w->fh_sv);    w->fh_sv = NULL; }
    if (w->loop_sv)  { SvREFCNT_dec(w->loop_sv);  w->loop_sv = NULL; }
    if (w->self_sv)  { SvREFCNT_dec(w->self_sv);  w->self_sv = NULL; }
}

static void le_watcher_destroy(le_watcher_t *w) {
    if (!w) return;
    le_loop_t *loop = w->loop;
    le_watcher_clear_refs(w);
    if (loop) loop->watcher_destroy_calls++;
    free(w);
}

static le_watcher_t *le_watcher_alloc(le_loop_t *loop) {
    le_watcher_t *w = NULL;
    if (loop && loop->watcher_freelist) {
        w = loop->watcher_freelist;
        loop->watcher_freelist = w->next_free;
        if (loop->watcher_freelist_depth) loop->watcher_freelist_depth--;
        loop->watcher_reuse_calls++;
        memset(w, 0, sizeof(*w));
        return w;
    }
    w = (le_watcher_t *)calloc(1, sizeof(le_watcher_t));
    if (!w) croak("calloc watcher failed");
    if (loop) loop->watcher_alloc_calls++;
    return w;
}

static void le_watcher_push_list(le_watcher_t **list, le_watcher_t *w) {
    w->next_free = *list;
    *list = w;
}

static void le_watcher_recycle_or_destroy(le_watcher_t *w) {
    if (!w) return;
    le_loop_t *loop = w->loop;
    if (!loop || !loop->watcher_reclaim_enabled) return;
    le_watcher_clear_refs(w);
    w->active = 0;
    w->fd = -1;
    loop->watcher_recycle_calls++;
    if (loop->in_dispatch_batch) {
        le_watcher_push_list(&loop->watcher_pending, w);
    }
    else {
        le_watcher_push_list(&loop->watcher_freelist, w);
        loop->watcher_freelist_depth++;
        if (loop->watcher_freelist_depth > loop->watcher_freelist_max_depth) loop->watcher_freelist_max_depth = loop->watcher_freelist_depth;
    }
}

static void le_watcher_promote_pending(le_loop_t *loop) {
    le_watcher_t *w;
    if (!loop) return;
    while ((w = loop->watcher_pending) != NULL) {
        loop->watcher_pending = w->next_free;
        le_watcher_push_list(&loop->watcher_freelist, w);
        loop->watcher_freelist_depth++;
        if (loop->watcher_freelist_depth > loop->watcher_freelist_max_depth) loop->watcher_freelist_max_depth = loop->watcher_freelist_depth;
    }
}

static void le_loop_destroy(le_loop_t *loop) {
    if (!loop) return;
    if (loop->registry) {
        for (size_t i = 0; i < loop->reg_cap; i++) {
            le_watcher_t *w = loop->registry[i];
            if (w) {
                loop->registry[i] = NULL;
                w->active = 0;
                le_watcher_destroy(w);
            }
        }
        free(loop->registry);
    }
    while (loop->watcher_pending) { le_watcher_t *w = loop->watcher_pending; loop->watcher_pending = w->next_free; le_watcher_destroy(w); }
    while (loop->watcher_freelist) { le_watcher_t *w = loop->watcher_freelist; loop->watcher_freelist = w->next_free; le_watcher_destroy(w); }
    if (loop->events) free(loop->events);
    if (loop->epoll_fd >= 0) close(loop->epoll_fd);
    free(loop);
}

/* ---- Perl callback dispatch ----------------------------------------- */

static void le_count_callback(le_watcher_t *w, int one_arg, int direct_cv, unsigned long long t0) {
    if (!w || !w->loop) return;
    w->loop->callback_calls++;
    if (one_arg) w->loop->callback_onearg_calls++;
    else w->loop->callback_noarg_calls++;
    if (direct_cv) w->loop->callback_direct_cv_calls++;
    else w->loop->callback_sv_calls++;
    if (w->loop->profile_enabled) w->loop->callback_ns += le_now_ns() - t0;
}

/*
 * Bounded Perl callback temporary scopes.
 *
 * ENTER/SAVETMPS setup is amortized across a bounded group of callbacks while
 * FREETMPS still runs after every callback. The measured default is 128. A
 * limit of zero intentionally means one scope for the complete epoll batch and
 * is retained only as a diagnostic tuning mode.
 */
static void le_call_watcher_cb_noarg(pTHX_ le_watcher_t *w, SV *cb, int direct_cv) {
    if (!cb || (!direct_cv && !SvOK(cb)) || !w || !w->active) return;
    unsigned long long t0 = 0;
    if (w->loop && w->loop->profile_enabled) t0 = le_now_ns();

    dSP;
    PUSHMARK(SP);
    PUTBACK;
    call_sv(cb, G_DISCARD | G_VOID);
    FREETMPS;

    le_count_callback(w, 0, direct_cv, t0);
}

static void le_call_watcher_cb_onearg(pTHX_ le_watcher_t *w, SV *cb, int direct_cv) {
    if (!cb || (!direct_cv && !SvOK(cb)) || !w || !w->active) return;
    unsigned long long t0 = 0;
    if (w->loop && w->loop->profile_enabled) t0 = le_now_ns();

    dSP;
    PUSHMARK(SP);
    EXTEND(SP, 1);
    PUSHs(w->callback_arg_data && w->data_sv ? w->data_sv : w->self_sv);
    PUTBACK;
    call_sv(cb, G_DISCARD | G_VOID);
    FREETMPS;

    le_count_callback(w, 1, direct_cv, t0);
}

static void le_call_watcher_cb(pTHX_ le_watcher_t *w, SV *cb, int direct_cv) {
    if (!w || !w->active) return;
    if (w->callback_args) le_call_watcher_cb_onearg(aTHX_ w, cb, direct_cv);
    else le_call_watcher_cb_noarg(aTHX_ w, cb, direct_cv);
}

/*
 * Benchmark-only native echo path.
 *
 * NOT AN APPLICATION API. This diagnostic keeps the same real TCP workload
 * while removing Perl read/write work, allowing the benchmark to separate
 * callback entry from Perl sysread/buffer/syswrite cost. Mode 1 performs the
 * native echo with no Perl read callback; mode 2 calls an empty Perl callback
 * before the same native echo. Terminal handling remains on the normal path.
 */
static void le_bench_native_echo_read(le_watcher_t *w) {
    char buf[8192];
    le_loop_t *loop;

    if (!w || !w->active || !w->loop) return;
    loop = w->loop;
    loop->bench_native_echo_read_events++;

    while (w->active) {
        ssize_t n;
        size_t off;
        size_t len;

        loop->bench_native_echo_sysread_calls++;
        n = read(w->fd, buf, sizeof(buf));
        if (n > 0) {
            loop->bench_native_echo_bytes_read += (unsigned long long)n;
            off = 0;
            len = (size_t)n;
            while (off < len) {
                ssize_t wr;
                size_t remain = len - off;
                loop->bench_native_echo_syswrite_calls++;
                wr = write(w->fd, buf + off, remain);
                if (wr > 0) {
                    loop->bench_native_echo_bytes_written += (unsigned long long)wr;
                    if ((size_t)wr < remain) loop->bench_native_echo_partial_writes++;
                    off += (size_t)wr;
                    continue;
                }
                if (wr < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                    loop->bench_native_echo_write_eagain++;
                    break;
                }
                loop->bench_native_echo_errors++;
                break;
            }
            continue;
        }
        if (n == 0) {
            loop->bench_native_echo_read_zero++;
            break;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            loop->bench_native_echo_read_eagain++;
            break;
        }
        loop->bench_native_echo_errors++;
        break;
    }
}

/* Apply the watcher's current logical interest mask back to epoll. */
static int le_apply_mask(le_watcher_t *w) {
    struct epoll_event ev;
    memset(&ev, 0, sizeof(ev));
    ev.events = le_epoll_events(w);
    ev.data.ptr = (void *)w;
    return le_epoll_ctl_timed(w->loop, EPOLL_CTL_MOD, w->fd, &ev);
}


/*
 * Dispatch one epoll batch.
 *
 * Every event already carries the watcher pointer in data.ptr. The watcher is
 * validated against its active flag and owner loop before use. Reclaim/reuse
 * is deferred until the batch ends so stale data.ptr values cannot refer to a
 * newly repurposed watcher record.
 */
static void
le_dispatch_batch(pTHX_ le_loop_t *loop, int n) {
    int i;
    unsigned int scope_callbacks = 0;
    unsigned long long callback_before;

    loop->in_dispatch_batch++;
    ENTER;
    SAVETMPS;
    loop->callback_batch_scope_enters++;

    for (i = 0; i < n; i++) {
        uint32_t events = loop->events[i].events;
        le_watcher_t *w = (le_watcher_t *)loop->events[i].data.ptr;
        loop->direct_watcher_events++;
        if (!w || !w->active || w->loop != loop) continue;
        loop->dispatch_events++;
        le_note_ready_flags(loop, events);

        /* Terminal/error callbacks run before normal read/write readiness. */
        if (events & (EPOLLERR | EPOLLHUP | EPOLLRDHUP)) {
            if (w->error_cb) {
                if (loop->callback_scope_limit && scope_callbacks >= loop->callback_scope_limit) {
                    if (scope_callbacks > loop->callback_scope_max_callbacks) loop->callback_scope_max_callbacks = scope_callbacks;
                    FREETMPS;
                    LEAVE;
                    ENTER;
                    SAVETMPS;
                    loop->callback_batch_scope_enters++;
                    loop->callback_scope_rotations++;
                    scope_callbacks = 0;
                }
                loop->error_callback_calls++;
                callback_before = loop->callback_calls;
                le_call_watcher_cb(aTHX_ w, w->error_cb, w->error_cb_direct_cv);
                scope_callbacks += (unsigned int)(loop->callback_calls - callback_before);
            }
            if (!w->active) continue;
        }
        if (events & EPOLLIN) {
            if (w->bench_native_echo) {
                if (w->bench_native_echo == 2 && w->read_cb) {
                    if (loop->callback_scope_limit && scope_callbacks >= loop->callback_scope_limit) {
                        if (scope_callbacks > loop->callback_scope_max_callbacks) loop->callback_scope_max_callbacks = scope_callbacks;
                        FREETMPS;
                        LEAVE;
                        ENTER;
                        SAVETMPS;
                        loop->callback_batch_scope_enters++;
                        loop->callback_scope_rotations++;
                        scope_callbacks = 0;
                    }
                    loop->read_callback_calls++;
                    loop->bench_native_echo_perl_read_callbacks++;
                    callback_before = loop->callback_calls;
                    le_call_watcher_cb(aTHX_ w, w->read_cb, w->read_cb_direct_cv);
                    scope_callbacks += (unsigned int)(loop->callback_calls - callback_before);
                }
                if (!w->active) continue;
                le_bench_native_echo_read(w);
            }
            else if (w->read_cb) {
                if (loop->callback_scope_limit && scope_callbacks >= loop->callback_scope_limit) {
                    if (scope_callbacks > loop->callback_scope_max_callbacks) loop->callback_scope_max_callbacks = scope_callbacks;
                    FREETMPS;
                    LEAVE;
                    ENTER;
                    SAVETMPS;
                    loop->callback_batch_scope_enters++;
                    loop->callback_scope_rotations++;
                    scope_callbacks = 0;
                }
                loop->read_callback_calls++;
                callback_before = loop->callback_calls;
                le_call_watcher_cb(aTHX_ w, w->read_cb, w->read_cb_direct_cv);
                scope_callbacks += (unsigned int)(loop->callback_calls - callback_before);
            }
            if (!w->active) continue;
        }
        if (events & EPOLLOUT) {
            if (w->write_cb) {
                if (loop->callback_scope_limit && scope_callbacks >= loop->callback_scope_limit) {
                    if (scope_callbacks > loop->callback_scope_max_callbacks) loop->callback_scope_max_callbacks = scope_callbacks;
                    FREETMPS;
                    LEAVE;
                    ENTER;
                    SAVETMPS;
                    loop->callback_batch_scope_enters++;
                    loop->callback_scope_rotations++;
                    scope_callbacks = 0;
                }
                loop->write_callback_calls++;
                callback_before = loop->callback_calls;
                le_call_watcher_cb(aTHX_ w, w->write_cb, w->write_cb_direct_cv);
                scope_callbacks += (unsigned int)(loop->callback_calls - callback_before);
            }
        }
        if (loop->stop_flag) break;
    }

    if (scope_callbacks > loop->callback_scope_max_callbacks) loop->callback_scope_max_callbacks = scope_callbacks;
    FREETMPS;
    LEAVE;
    loop->in_dispatch_batch--;
    if (!loop->in_dispatch_batch) le_watcher_promote_pending(loop);
}



typedef struct {
    SV *fh;
    SV *data;
    SV *read_cb;
    SV *write_cb;
    SV *error_cb;
    int oneshot;
    int edge_triggered;
    int callback_args;
    int callback_arg_data;
    int lean;
    int bench_native_echo;
} le_watch_opts_t;

static void le_watch_opts_init(le_watch_opts_t *opt) {
    memset(opt, 0, sizeof(*opt));
    opt->callback_args = 1;
}

static int le_watch_parse_common_option(const char *key, SV *val, le_watch_opts_t *opt) {
    if (strEQ(key, "data")) opt->data = val;
    else if (strEQ(key, "read")) opt->read_cb = val;
    else if (strEQ(key, "write")) opt->write_cb = val;
    else if (strEQ(key, "error")) opt->error_cb = val;
    else if (strEQ(key, "oneshot")) opt->oneshot = SvTRUE(val) ? 1 : 0;
    else if (strEQ(key, "edge_triggered")) opt->edge_triggered = SvTRUE(val) ? 1 : 0;
    else if (strEQ(key, "callback_args")) opt->callback_args = SvIV(val) ? 1 : 0;
    else if (strEQ(key, "no_args")) {
        if (SvTRUE(val)) opt->callback_args = 0;
    }
    else if (strEQ(key, "_callback_data_arg")) {
        opt->callback_arg_data = SvTRUE(val) ? 1 : 0;
        if (opt->callback_arg_data) opt->callback_args = 1;
    }
    else if (strEQ(key, "lean") || strEQ(key, "no_accessor_refs")) {
        opt->lean = SvTRUE(val) ? 1 : 0;
    }
    else if (strEQ(key, "_bench_native_echo")) {
        opt->bench_native_echo = (int)SvIV(val);
        if (opt->bench_native_echo < 0 || opt->bench_native_echo > 2)
            croak("_bench_native_echo must be 0, 1, or 2");
    }
    else return 0;
    return 1;
}

static SV *le_watch_register(SV *loop_obj, le_loop_t *loop, int fd, le_watch_opts_t *opt) {
    le_watcher_t *w;
    SV *watcher_sv;
    struct epoll_event ev;

    if (opt->callback_arg_data) {
        opt->callback_args = 1;
        if (!opt->data || !SvOK(opt->data)) croak("_callback_data_arg requires data");
    }

    le_registry_grow(loop, fd);
    if (loop->registry[fd]) {
        le_watcher_t *old = loop->registry[fd];
        le_epoll_ctl_timed(loop, EPOLL_CTL_DEL, fd, NULL);
        loop->registry[fd] = NULL;
        old->active = 0;
        le_watcher_destroy(old);
    }

    w = le_watcher_alloc(loop);
    w->fd = fd;
    w->loop = loop;
    w->active = 1;
    w->mask = le_mask_from_callbacks(opt->read_cb, opt->write_cb);
    w->flags = (opt->oneshot ? EPOLLONESHOT : 0) | (opt->edge_triggered ? EPOLLET : 0);
    w->callback_args = opt->callback_args ? 1 : 0;
    w->callback_arg_data = opt->callback_arg_data ? 1 : 0;
    w->bench_native_echo = opt->bench_native_echo;
    if (w->bench_native_echo) w->mask |= EPOLLIN;
    w->lean = (opt->lean && !w->callback_args) ? 1 : 0;
    if (w->lean) loop->lean_watchers++;

    watcher_sv = sv_setref_pv(newSV(0), "Linux::Event::XSWatcher", (void*)w);
    if (!w->lean || (w->callback_args && !w->callback_arg_data))
        w->self_sv = newSVsv(watcher_sv);
    if (!w->lean) {
        w->loop_sv = newSVsv(loop_obj);
        if (opt->fh) w->fh_sv = newSVsv(opt->fh);
        if (opt->data) w->data_sv = newSVsv(opt->data);
    }
    if (opt->read_cb) w->read_cb = le_stored_callback_from_sv(opt->read_cb, &w->read_cb_direct_cv);
    if (opt->write_cb) w->write_cb = le_stored_callback_from_sv(opt->write_cb, &w->write_cb_direct_cv);
    if (opt->error_cb) w->error_cb = le_stored_callback_from_sv(opt->error_cb, &w->error_cb_direct_cv);

    memset(&ev, 0, sizeof(ev));
    ev.events = le_epoll_events(w);
    ev.data.ptr = (void *)w;
    if (le_epoll_ctl_timed(loop, EPOLL_CTL_ADD, fd, &ev) < 0) {
        int err = errno;
        le_watcher_destroy(w);
        croak("epoll_ctl ADD fd %d failed: %s", fd, strerror(err));
    }
    loop->registry[fd] = w;
    return watcher_sv;
}

static int le_fd_from_fh(SV *fh) {
    IO *io = sv_2io(fh);
    PerlIO *fp = IoIFP(io);
    int fd;
    if (!fp) fp = IoOFP(io);
    if (!fp) croak("watch(): fh has no file descriptor");
    fd = PerlIO_fileno(fp);
    if (fd < 0) croak("watch(): fh has no file descriptor");
    return fd;
}

MODULE = Linux::Event::XSLoop    PACKAGE = Linux::Event::XSLoop
PROTOTYPES: DISABLE

SV *
new(CLASS)
    const char *CLASS
  CODE:
    le_loop_t *loop = (le_loop_t *)calloc(1, sizeof(le_loop_t));
    if (!loop) croak("calloc loop failed");
    loop->epoll_fd = epoll_create1(EPOLL_CLOEXEC);
    if (loop->epoll_fd < 0) { int err = errno; free(loop); croak("epoll_create1 failed: %s", strerror(err)); }
    loop->event_cap = LE_INITIAL_EVENTS;
    loop->callback_scope_limit = LE_CALLBACK_SCOPE_DEFAULT;
    loop->events = (struct epoll_event *)calloc(loop->event_cap, sizeof(struct epoll_event));
    loop->reg_cap = LE_INITIAL_REGISTRY;
    loop->registry = (le_watcher_t **)calloc(loop->reg_cap, sizeof(le_watcher_t *));
    if (!loop->events || !loop->registry) croak("calloc loop internals failed");
    RETVAL = sv_setref_pv(newSV(0), CLASS, (void*)loop);
  OUTPUT:
    RETVAL

void
DESTROY(loop_obj)
    SV *loop_obj
  CODE:
    le_loop_destroy(le_loop_from_sv(loop_obj));

void
stop(loop_obj)
    SV *loop_obj
  CODE:
    le_loop_from_sv(loop_obj)->stop_flag = 1;

SV *
stats(loop_obj)
    SV *loop_obj
  CODE:
    le_loop_t *loop = le_loop_from_sv(loop_obj);
    HV *hv = newHV();
    hv_stores(hv, "event_capacity", newSVuv(loop->event_cap));
    hv_stores(hv, "epoll_wait_calls", newSVuv(loop->epoll_wait_calls));
    hv_stores(hv, "epoll_wait_empty_calls", newSVuv(loop->epoll_wait_empty_calls));
    hv_stores(hv, "epoll_wait_full_batches", newSVuv(loop->epoll_wait_full_batches));
    hv_stores(hv, "epoll_wait_max_batch", newSVuv(loop->epoll_wait_max_batch));
    hv_stores(hv, "ready_events_returned", newSVuv(loop->ready_events_returned));
    hv_stores(hv, "ready_read_events", newSVuv(loop->ready_read_events));
    hv_stores(hv, "ready_write_events", newSVuv(loop->ready_write_events));
    hv_stores(hv, "ready_error_events", newSVuv(loop->ready_error_events));
    hv_stores(hv, "ready_epollerr_events", newSVuv(loop->ready_epollerr_events));
    hv_stores(hv, "ready_hup_events", newSVuv(loop->ready_hup_events));
    hv_stores(hv, "ready_rdhup_events", newSVuv(loop->ready_rdhup_events));
    hv_stores(hv, "ready_in_hup_events", newSVuv(loop->ready_in_hup_events));
    hv_stores(hv, "ready_in_rdhup_events", newSVuv(loop->ready_in_rdhup_events));
    hv_stores(hv, "ready_multi_events", newSVuv(loop->ready_multi_events));
    hv_stores(hv, "callback_calls", newSVuv(loop->callback_calls));
    hv_stores(hv, "read_callback_calls", newSVuv(loop->read_callback_calls));
    hv_stores(hv, "write_callback_calls", newSVuv(loop->write_callback_calls));
    hv_stores(hv, "error_callback_calls", newSVuv(loop->error_callback_calls));
    hv_stores(hv, "epoll_ctl_add_calls", newSVuv(loop->epoll_ctl_add_calls));
    hv_stores(hv, "epoll_ctl_mod_calls", newSVuv(loop->epoll_ctl_mod_calls));
    hv_stores(hv, "epoll_ctl_del_calls", newSVuv(loop->epoll_ctl_del_calls));
    hv_stores(hv, "watcher_lookup_calls", newSVuv(loop->watcher_lookup_calls));
    hv_stores(hv, "direct_watcher_events", newSVuv(loop->direct_watcher_events));
    hv_stores(hv, "dispatch_events", newSVuv(loop->dispatch_events));
    hv_stores(hv, "callback_noarg_calls", newSVuv(loop->callback_noarg_calls));
    hv_stores(hv, "callback_onearg_calls", newSVuv(loop->callback_onearg_calls));
    hv_stores(hv, "callback_direct_cv_calls", newSVuv(loop->callback_direct_cv_calls));
    hv_stores(hv, "callback_sv_calls", newSVuv(loop->callback_sv_calls));
    hv_stores(hv, "callback_batch_scope_enters", newSVuv(loop->callback_batch_scope_enters));
    hv_stores(hv, "callback_scope_rotations", newSVuv(loop->callback_scope_rotations));
    hv_stores(hv, "callback_scope_max_callbacks", newSVuv(loop->callback_scope_max_callbacks));
    hv_stores(hv, "callback_scope_limit", newSVuv(loop->callback_scope_limit));
    hv_stores(hv, "run_once_calls", newSVuv(loop->run_once_calls));
    hv_stores(hv, "run_calls", newSVuv(loop->run_calls));
    hv_stores(hv, "run_for_calls", newSVuv(loop->run_for_calls));
    hv_stores(hv, "bench_native_echo_read_events", newSVuv(loop->bench_native_echo_read_events));
    hv_stores(hv, "bench_native_echo_perl_read_callbacks", newSVuv(loop->bench_native_echo_perl_read_callbacks));
    hv_stores(hv, "bench_native_echo_sysread_calls", newSVuv(loop->bench_native_echo_sysread_calls));
    hv_stores(hv, "bench_native_echo_syswrite_calls", newSVuv(loop->bench_native_echo_syswrite_calls));
    hv_stores(hv, "bench_native_echo_bytes_read", newSVuv(loop->bench_native_echo_bytes_read));
    hv_stores(hv, "bench_native_echo_bytes_written", newSVuv(loop->bench_native_echo_bytes_written));
    hv_stores(hv, "bench_native_echo_read_eagain", newSVuv(loop->bench_native_echo_read_eagain));
    hv_stores(hv, "bench_native_echo_write_eagain", newSVuv(loop->bench_native_echo_write_eagain));
    hv_stores(hv, "bench_native_echo_partial_writes", newSVuv(loop->bench_native_echo_partial_writes));
    hv_stores(hv, "bench_native_echo_read_zero", newSVuv(loop->bench_native_echo_read_zero));
    hv_stores(hv, "bench_native_echo_errors", newSVuv(loop->bench_native_echo_errors));
    hv_stores(hv, "lean_watchers", newSVuv(loop->lean_watchers));
    hv_stores(hv, "watcher_alloc_calls", newSVuv(loop->watcher_alloc_calls));
    hv_stores(hv, "watcher_reuse_calls", newSVuv(loop->watcher_reuse_calls));
    hv_stores(hv, "watcher_recycle_calls", newSVuv(loop->watcher_recycle_calls));
    hv_stores(hv, "watcher_destroy_calls", newSVuv(loop->watcher_destroy_calls));
    hv_stores(hv, "watcher_freelist_depth", newSVuv(loop->watcher_freelist_depth));
    hv_stores(hv, "watcher_freelist_max_depth", newSVuv(loop->watcher_freelist_max_depth));
    hv_stores(hv, "watcher_reclaim_enabled", newSViv(loop->watcher_reclaim_enabled));
    hv_stores(hv, "profile_enabled", newSViv(loop->profile_enabled));
    hv_stores(hv, "epoll_wait_ns", newSVuv(loop->epoll_wait_ns));
    hv_stores(hv, "epoll_ctl_add_ns", newSVuv(loop->epoll_ctl_add_ns));
    hv_stores(hv, "epoll_ctl_mod_ns", newSVuv(loop->epoll_ctl_mod_ns));
    hv_stores(hv, "epoll_ctl_del_ns", newSVuv(loop->epoll_ctl_del_ns));
    hv_stores(hv, "watcher_lookup_ns", newSVuv(loop->watcher_lookup_ns));
    hv_stores(hv, "callback_ns", newSVuv(loop->callback_ns));
    hv_stores(hv, "dispatch_ns", newSVuv(loop->dispatch_ns));
    RETVAL = newRV_noinc((SV *)hv);
  OUTPUT:
    RETVAL

void
enable_profile(loop_obj, enabled = 1)
    SV *loop_obj
    int enabled
  CODE:
    le_loop_from_sv(loop_obj)->profile_enabled = enabled ? 1 : 0;

void
enable_watcher_reclaim(loop_obj, enabled = 1)
    SV *loop_obj
    int enabled
  CODE:
    le_loop_from_sv(loop_obj)->watcher_reclaim_enabled = enabled ? 1 : 0;


unsigned int
event_capacity(loop_obj)
    SV *loop_obj
  CODE:
    RETVAL = (unsigned int)le_loop_from_sv(loop_obj)->event_cap;
  OUTPUT:
    RETVAL

void
set_event_capacity(loop_obj, capacity)
    SV *loop_obj
    unsigned int capacity
  CODE:
    le_loop_t *loop = le_loop_from_sv(loop_obj);
    struct epoll_event *events;
    if (capacity < 1) croak("event capacity must be >= 1");
    if (capacity > 1048576) croak("event capacity too large");
    events = (struct epoll_event *)calloc((size_t)capacity, sizeof(struct epoll_event));
    if (!events) croak("calloc events failed");
    free(loop->events);
    loop->events = events;
    loop->event_cap = (size_t)capacity;

unsigned int
callback_scope_limit(loop_obj)
    SV *loop_obj
  CODE:
    RETVAL = le_loop_from_sv(loop_obj)->callback_scope_limit;
  OUTPUT:
    RETVAL

void
set_callback_scope_limit(loop_obj, limit)
    SV *loop_obj
    unsigned int limit
  CODE:
    if (limit > 1048576) croak("callback scope limit too large");
    le_loop_from_sv(loop_obj)->callback_scope_limit = limit;

void
reset_stats(loop_obj)
    SV *loop_obj
  CODE:
    le_loop_t *loop = le_loop_from_sv(loop_obj);
    loop->epoll_wait_calls = 0;
    loop->epoll_wait_empty_calls = 0;
    loop->epoll_wait_full_batches = 0;
    loop->epoll_wait_max_batch = 0;
    loop->ready_events_returned = 0;
    loop->ready_read_events = 0;
    loop->ready_write_events = 0;
    loop->ready_error_events = 0;
    loop->ready_epollerr_events = 0;
    loop->ready_hup_events = 0;
    loop->ready_rdhup_events = 0;
    loop->ready_in_hup_events = 0;
    loop->ready_in_rdhup_events = 0;
    loop->ready_multi_events = 0;
    loop->callback_calls = 0;
    loop->read_callback_calls = 0;
    loop->write_callback_calls = 0;
    loop->error_callback_calls = 0;
    loop->epoll_ctl_add_calls = 0;
    loop->epoll_ctl_mod_calls = 0;
    loop->epoll_ctl_del_calls = 0;
    loop->watcher_lookup_calls = 0;
    loop->direct_watcher_events = 0;
    loop->dispatch_events = 0;
    loop->callback_noarg_calls = 0;
    loop->callback_onearg_calls = 0;
    loop->callback_direct_cv_calls = 0;
    loop->callback_sv_calls = 0;
    loop->callback_batch_scope_enters = 0;
    loop->callback_scope_rotations = 0;
    loop->callback_scope_max_callbacks = 0;
    loop->run_once_calls = 0;
    loop->run_calls = 0;
    loop->run_for_calls = 0;
    loop->bench_native_echo_read_events = 0;
    loop->bench_native_echo_perl_read_callbacks = 0;
    loop->bench_native_echo_sysread_calls = 0;
    loop->bench_native_echo_syswrite_calls = 0;
    loop->bench_native_echo_bytes_read = 0;
    loop->bench_native_echo_bytes_written = 0;
    loop->bench_native_echo_read_eagain = 0;
    loop->bench_native_echo_write_eagain = 0;
    loop->bench_native_echo_partial_writes = 0;
    loop->bench_native_echo_read_zero = 0;
    loop->bench_native_echo_errors = 0;
    loop->lean_watchers = 0;
    loop->watcher_alloc_calls = 0;
    loop->watcher_reuse_calls = 0;
    loop->watcher_recycle_calls = 0;
    loop->watcher_destroy_calls = 0;
    loop->watcher_freelist_max_depth = loop->watcher_freelist_depth;
    loop->epoll_wait_ns = 0;
    loop->epoll_ctl_add_ns = 0;
    loop->epoll_ctl_mod_ns = 0;
    loop->epoll_ctl_del_ns = 0;
    loop->watcher_lookup_ns = 0;
    loop->callback_ns = 0;
    loop->dispatch_ns = 0;

SV *
watch(loop_obj, ...)
    SV *loop_obj
  PREINIT:
    int i;
    int fd = -1;
    int has_fh = 0;
    int has_fd = 0;
    SV *fd_sv = NULL;
    le_loop_t *loop;
    le_watch_opts_t opt;
  CODE:
    loop = le_loop_from_sv(loop_obj);
    if (items < 3 || ((items - 1) % 2) != 0)
        croak("watch requires key/value pairs including exactly one of fh or fd");
    le_watch_opts_init(&opt);
    for (i = 1; i < items; i += 2) {
        const char *key = SvPV_nolen(ST(i));
        SV *val = ST(i + 1);
        if (strEQ(key, "fh")) {
            if (has_fh) croak("watch(): duplicate fh option");
            opt.fh = val;
            has_fh = 1;
        }
        else if (strEQ(key, "fd")) {
            if (has_fd) croak("watch(): duplicate fd option");
            fd_sv = val;
            has_fd = 1;
        }
        else if (!le_watch_parse_common_option(key, val, &opt)) {
            croak("unknown watch option '%s'", key);
        }
    }
    if (has_fh == has_fd) croak("watch(): exactly one of fh or fd is required");
    if (has_fh) {
        fd = le_fd_from_fh(opt.fh);
    } else {
        IV iv;
        NV nv;
        if (!fd_sv || !SvOK(fd_sv) || !looks_like_number(fd_sv))
            croak("watch(): fd must be a non-negative integer");
        iv = SvIV(fd_sv);
        nv = SvNV(fd_sv);
        if (iv < 0 || iv > INT_MAX || (NV)iv != nv)
            croak("watch(): fd must be a non-negative integer");
        fd = (int)iv;
    }
    RETVAL = le_watch_register(loop_obj, loop, fd, &opt);
  OUTPUT:
    RETVAL

SV *
watch_fd(loop_obj, fd, ...)
    SV *loop_obj
    int fd
  PREINIT:
    int i;
    le_loop_t *loop;
    le_watch_opts_t opt;
  CODE:
    loop = le_loop_from_sv(loop_obj);
    if (items < 2 || ((items - 2) % 2) != 0)
        croak("watch_fd requires fd plus key/value pairs");
    le_watch_opts_init(&opt);
    for (i = 2; i < items; i += 2) {
        const char *key = SvPV_nolen(ST(i));
        SV *val = ST(i + 1);
        if (strEQ(key, "fh")) opt.fh = val;
        else if (!le_watch_parse_common_option(key, val, &opt))
            croak("unknown watch_fd option '%s'", key);
    }
    RETVAL = le_watch_register(loop_obj, loop, fd, &opt);
  OUTPUT:
    RETVAL

void
unwatch_fd(loop_obj, fd)
    SV *loop_obj
    int fd
  CODE:
    le_loop_t *loop = le_loop_from_sv(loop_obj);
    if (fd < 0 || (size_t)fd >= loop->reg_cap) XSRETURN_EMPTY;
    le_watcher_t *w = loop->registry[fd];
    if (!w) XSRETURN_EMPTY;
    le_epoll_ctl_timed(loop, EPOLL_CTL_DEL, fd, NULL);
    loop->registry[fd] = NULL;
    w->active = 0;
    le_watcher_recycle_or_destroy(w);


int
run_once(loop_obj, timeout_ms = -1)
    SV *loop_obj
    int timeout_ms
  PREINIT:
    int n; le_loop_t *loop; unsigned long long t0; unsigned long long dispatch_t0;
  CODE:
    loop = le_loop_from_sv(loop_obj);
    loop->run_once_calls++;
    if (loop->stop_flag) { RETVAL = 0; }
    else {
        t0 = loop->profile_enabled ? le_now_ns() : 0;
        n = epoll_wait(loop->epoll_fd, loop->events, (int)loop->event_cap, timeout_ms);
        if (loop->profile_enabled) loop->epoll_wait_ns += le_now_ns() - t0;
        if (n < 0) { if (errno == EINTR) RETVAL = 0; else croak("epoll_wait failed: %s", strerror(errno)); }
        else {
            le_note_epoll_batch(loop, n);
            dispatch_t0 = loop->profile_enabled ? le_now_ns() : 0;
            le_dispatch_batch(aTHX_ loop, n);
            if (loop->profile_enabled) loop->dispatch_ns += le_now_ns() - dispatch_t0;
            RETVAL = n;
        }
    }
  OUTPUT:
    RETVAL

void
run(loop_obj)
    SV *loop_obj
  PREINIT:
    le_loop_t *loop;
    int n;
    unsigned long long t0;
    unsigned long long dispatch_t0;
  CODE:
    loop = le_loop_from_sv(loop_obj);
    loop->run_calls++;
    loop->stop_flag = 0;
    while (!loop->stop_flag) {
        t0 = loop->profile_enabled ? le_now_ns() : 0;
        n = epoll_wait(loop->epoll_fd, loop->events, (int)loop->event_cap, -1);
        if (loop->profile_enabled) loop->epoll_wait_ns += le_now_ns() - t0;
        if (n < 0) { if (errno == EINTR) continue; croak("epoll_wait failed: %s", strerror(errno)); }
        le_note_epoll_batch(loop, n);
        dispatch_t0 = loop->profile_enabled ? le_now_ns() : 0;
        le_dispatch_batch(aTHX_ loop, n);
        if (loop->profile_enabled) loop->dispatch_ns += le_now_ns() - dispatch_t0;
    }

void
run_for(loop_obj, seconds)
    SV *loop_obj
    double seconds
  PREINIT:
    le_loop_t *loop;
    int n;
    int timeout_ms;
    unsigned long long now_ns;
    unsigned long long deadline_ns;
    unsigned long long remaining_ns;
    unsigned long long t0;
    unsigned long long dispatch_t0;
  CODE:
    if (seconds < 0.0) croak("run_for seconds must be >= 0");
    loop = le_loop_from_sv(loop_obj);
    loop->run_for_calls++;
    loop->stop_flag = 0;
    now_ns = le_now_ns();
    if (seconds >= 18446744073.0) croak("run_for seconds too large");
    deadline_ns = now_ns + (unsigned long long)(seconds * 1000000000.0);

    while (!loop->stop_flag) {
        now_ns = le_now_ns();
        if (now_ns >= deadline_ns) break;
        remaining_ns = deadline_ns - now_ns;
        timeout_ms = (int)((remaining_ns + 999999ULL) / 1000000ULL);
        if (timeout_ms < 0) timeout_ms = 0;

        t0 = loop->profile_enabled ? le_now_ns() : 0;
        n = epoll_wait(loop->epoll_fd, loop->events, (int)loop->event_cap, timeout_ms);
        if (loop->profile_enabled) loop->epoll_wait_ns += le_now_ns() - t0;
        if (n < 0) {
            if (errno == EINTR) continue;
            croak("epoll_wait failed: %s", strerror(errno));
        }
        if (n == 0) continue;
        le_note_epoll_batch(loop, n);
        dispatch_t0 = loop->profile_enabled ? le_now_ns() : 0;
        le_dispatch_batch(aTHX_ loop, n);
        if (loop->profile_enabled) loop->dispatch_ns += le_now_ns() - dispatch_t0;
    }

MODULE = Linux::Event::XSLoop    PACKAGE = Linux::Event::XSWatcher
PROTOTYPES: DISABLE

void
DESTROY(w_obj)
    SV *w_obj
  CODE:
    /* The loop owns native watcher lifetime; this Perl handle is non-owning. */

int
fd(w_obj)
    SV *w_obj
  CODE:
    RETVAL = le_watcher_from_sv(w_obj)->fd;
  OUTPUT:
    RETVAL

SV *
fh(w_obj)
    SV *w_obj
  CODE:
    le_watcher_t *w = le_watcher_from_sv(w_obj);
    RETVAL = w->fh_sv ? newSVsv(w->fh_sv) : newSV(0);
  OUTPUT:
    RETVAL

SV *
data(w_obj)
    SV *w_obj
  CODE:
    le_watcher_t *w = le_watcher_from_sv(w_obj);
    RETVAL = w->data_sv ? newSVsv(w->data_sv) : newSV(0);
  OUTPUT:
    RETVAL

int
lean(w_obj)
    SV *w_obj
  CODE:
    RETVAL = le_watcher_from_sv(w_obj)->lean;
  OUTPUT:
    RETVAL

SV *
loop(w_obj)
    SV *w_obj
  CODE:
    le_watcher_t *w = le_watcher_from_sv(w_obj);
    RETVAL = w->loop_sv ? newSVsv(w->loop_sv) : newSV(0);
  OUTPUT:
    RETVAL

void
cancel(w_obj)
    SV *w_obj
  CODE:
    le_watcher_t *w = le_watcher_from_sv(w_obj);
    if (w && w->active && w->loop) {
        le_loop_t *loop = w->loop; int fd = w->fd;
        if (fd >= 0 && (size_t)fd < loop->reg_cap && loop->registry[fd] == w) {
            le_epoll_ctl_timed(loop, EPOLL_CTL_DEL, fd, NULL);
            loop->registry[fd] = NULL;
        }
        w->active = 0;
        le_watcher_recycle_or_destroy(w);
    }

void
enable_read(w_obj)
    SV *w_obj
  CODE:
    le_watcher_t *w = le_watcher_from_sv(w_obj);
    if (w && w->active && (!(w->mask & EPOLLIN) || (w->flags & EPOLLONESHOT))) { w->mask |= EPOLLIN; if (le_apply_mask(w) < 0) croak("enable_read epoll_ctl MOD failed: %s", strerror(errno)); }

void
disable_read(w_obj)
    SV *w_obj
  CODE:
    le_watcher_t *w = le_watcher_from_sv(w_obj);
    if (w && w->active && (w->mask & EPOLLIN)) { w->mask &= ~EPOLLIN; if (le_apply_mask(w) < 0) croak("disable_read epoll_ctl MOD failed: %s", strerror(errno)); }

void
enable_write(w_obj)
    SV *w_obj
  CODE:
    le_watcher_t *w = le_watcher_from_sv(w_obj);
    if (w && w->active && (!(w->mask & EPOLLOUT) || (w->flags & EPOLLONESHOT))) { w->mask |= EPOLLOUT; if (le_apply_mask(w) < 0) croak("enable_write epoll_ctl MOD failed: %s", strerror(errno)); }

void
disable_write(w_obj)
    SV *w_obj
  CODE:
    le_watcher_t *w = le_watcher_from_sv(w_obj);
    if (w && w->active && (w->mask & EPOLLOUT)) { w->mask &= ~EPOLLOUT; if (le_apply_mask(w) < 0) croak("disable_write epoll_ctl MOD failed: %s", strerror(errno)); }
