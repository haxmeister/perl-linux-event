/*
 * EPOLLEXCLUSIVE multi-process listener experiment.
 *
 * This is research tooling, NOT a Linux::Event public API or XS implementation.
 * Three distinct setups are measured:
 *   shared:   one inherited socket, conventional registration in each epoll
 *   exclusive:one inherited socket, EPOLLEXCLUSIVE in each epoll
 *   reuseport:independent listening sockets in SO_REUSEPORT group
 *
 * All workers have independent epoll fds. Connections are made over 127.0.0.1.
 * Example:
 *   cc -O2 -Wall -Wextra -std=gnu11 -o /tmp/exclusive bench/experiments/epollexclusive-accept.c
 *   /tmp/exclusive exclusive 4 1000 0
 *
 * Output is one JSON record per run. Kernel behavior depends on scheduler
 * load, hardware, traffic shape and version; use paired repeated trials.
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define MAX_WORKERS 32
#define MAX_EVENTS 4
#define ACCEPT_BUDGET 64

struct worker_stats {
    uint64_t accepted;
    uint64_t ready;
    uint64_t no_accept;
    uint64_t accept_syscalls;
};

struct state {
    int stop;
    uint64_t accepted;
    struct worker_stats workers[MAX_WORKERS];
};

enum mode { SHARED = 0, EXCLUSIVE = 1, REUSEPORT = 2 };

static void fail(const char *what) {
    fprintf(stderr, "%s: %s\n", what, strerror(errno));
    exit(2);
}

static double monotonic(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t) < 0) fail("clock_gettime");
    return t.tv_sec + t.tv_nsec / 1000000000.0;
}

static int listener(int port, int reuse, int *bound_port) {
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (fd < 0) fail("socket listener");
    int one = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one)) < 0)
        fail("SO_REUSEADDR");
    if (reuse && setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof(one)) < 0)
        fail("SO_REUSEPORT");
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons((uint16_t)port);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) fail("bind");
    if (listen(fd, 4096) < 0) fail("listen");
    socklen_t len = sizeof(addr);
    if (getsockname(fd, (struct sockaddr *)&addr, &len) < 0) fail("getsockname");
    if (bound_port) *bound_port = ntohs(addr.sin_port);
    return fd;
}

static void worker(enum mode mode, int index, int listening_fd,
                   int port, struct state *st, int readyfd) {
    if (mode == REUSEPORT) {
        close(listening_fd);
        listening_fd = listener(port, 1, NULL);
    }
    int epfd = epoll_create1(EPOLL_CLOEXEC);
    if (epfd < 0) fail("epoll_create1");
    struct epoll_event event = {0};
    event.events = EPOLLIN | (mode == EXCLUSIVE ? EPOLLEXCLUSIVE : 0);
    event.data.fd = listening_fd;
    if (epoll_ctl(epfd, EPOLL_CTL_ADD, listening_fd, &event) < 0)
        fail("epoll_ctl ADD");
    if (write(readyfd, "R", 1) != 1) fail("worker ready pipe");
    close(readyfd);

    struct worker_stats *w = &st->workers[index];
    struct epoll_event events[MAX_EVENTS];
    while (!__atomic_load_n(&st->stop, __ATOMIC_ACQUIRE)) {
        int n = epoll_wait(epfd, events, MAX_EVENTS, 50);
        if (n < 0) {
            if (errno == EINTR) continue;
            fail("epoll_wait");
        }
        if (!n) continue;
        for (int j = 0; j < n; j++) {
            if (!(events[j].events & EPOLLIN)) continue;
            w->ready++;
            int accepted_this_wakeup = 0;
            for (int k = 0; k < ACCEPT_BUDGET; k++) {
                struct sockaddr_storage peer;
                socklen_t peerlen = sizeof(peer);
                int client = accept4(listening_fd, (void *)&peer, &peerlen,
                                     SOCK_NONBLOCK | SOCK_CLOEXEC);
                w->accept_syscalls++;
                if (client < 0) {
                    if (errno == EINTR) { k--; continue; }
                    if (errno == EAGAIN || errno == EWOULDBLOCK) break;
                    if (errno == ECONNABORTED) continue;
                    fail("accept4");
                }
                accepted_this_wakeup++;
                w->accepted++;
                __atomic_add_fetch(&st->accepted, 1, __ATOMIC_RELAXED);
                close(client);
            }
            if (!accepted_this_wakeup) w->no_accept++;
        }
    }
    close(epfd);
    close(listening_fd);
    _exit(0);
}

static int connect_once(int port) {
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) fail("client socket");
    /* RST on close avoids thousands of lingering client TIME_WAIT sockets. */
    struct linger rst = { .l_onoff = 1, .l_linger = 0 };
    if (setsockopt(fd, SOL_SOCKET, SO_LINGER, &rst, sizeof(rst)) < 0)
        fail("SO_LINGER");
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons((uint16_t)port);
    int ok = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
    int err = errno;
    close(fd);
    if (ok == 0) return 1;
    if (err == EINTR || err == EAGAIN || err == ECONNREFUSED ||
        err == ECONNRESET || err == ETIMEDOUT)
        return 0;
    errno = err;
    fail("connect");
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 5) {
        fprintf(stderr, "usage: %s shared|exclusive|reuseport WORKERS CONNECTIONS GAP_US\n", argv[0]);
        return 2;
    }
    enum mode mode;
    if (!strcmp(argv[1], "shared")) mode = SHARED;
    else if (!strcmp(argv[1], "exclusive")) mode = EXCLUSIVE;
    else if (!strcmp(argv[1], "reuseport")) mode = REUSEPORT;
    else { fprintf(stderr, "invalid mode\n"); return 2; }
    char *end;
    long nworkers = strtol(argv[2], &end, 10);
    if (*end || nworkers < 1 || nworkers > MAX_WORKERS) return 2;
    long nconnections = strtol(argv[3], &end, 10);
    if (*end || nconnections < 1 || nconnections > 100000) return 2;
    long gap = strtol(argv[4], &end, 10);
    if (*end || gap < 0 || gap > 1000000) return 2;

    struct state *st = mmap(NULL, sizeof(*st), PROT_READ | PROT_WRITE,
                            MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    if (st == MAP_FAILED) fail("mmap");
    memset(st, 0, sizeof(*st));
    int port = 0;
    int listening_fd = listener(0, mode == REUSEPORT, &port);
    int ready[2];
    if (pipe2(ready, O_CLOEXEC) < 0) fail("pipe2");
    pid_t pids[MAX_WORKERS];
    for (int i = 0; i < nworkers; i++) {
        pid_t pid = fork();
        if (pid < 0) fail("fork");
        if (pid == 0) {
            close(ready[0]);
            worker(mode, i, listening_fd, port, st, ready[1]);
        }
        pids[i] = pid;
    }
    close(ready[1]);
    for (int i = 0; i < nworkers; i++) {
        char byte;
        ssize_t count;
        do { count = read(ready[0], &byte, 1); } while (count < 0 && errno == EINTR);
        if (count != 1) fail("worker initialization");
    }
    close(ready[0]);
    close(listening_fd);

    const double start = monotonic();
    int sent = 0;
    for (int i = 0; i < nconnections; i++) {
        if (connect_once(port)) sent++;
        if (gap) usleep((useconds_t)gap);
    }
    double generated = monotonic() - start;
    int timed_out = 0;
    const double deadline = monotonic() + 8.0;
    while (__atomic_load_n(&st->accepted, __ATOMIC_RELAXED) < (uint64_t)sent) {
        if (monotonic() > deadline) { timed_out = 1; break; }
        usleep(1000);
    }
    double elapsed = monotonic() - start;
    __atomic_store_n(&st->stop, 1, __ATOMIC_RELEASE);

    uint64_t wakes = 0, no_accept = 0, calls = 0;
    uint64_t min_accepted = UINT64_MAX, max_accepted = 0;
    double cpu_sec = 0;
    int child_failure = 0;
    for (int i = 0; i < nworkers; i++) {
        struct rusage usage = {0};
        int status = 0;
        if (wait4(pids[i], &status, 0, &usage) < 0) fail("wait4");
        if (!WIFEXITED(status) || WEXITSTATUS(status)) child_failure = 1;
        cpu_sec += usage.ru_utime.tv_sec + usage.ru_utime.tv_usec / 1e6;
        cpu_sec += usage.ru_stime.tv_sec + usage.ru_stime.tv_usec / 1e6;
        struct worker_stats *w = &st->workers[i];
        wakes += w->ready;
        no_accept += w->no_accept;
        calls += w->accept_syscalls;
        if (w->accepted < min_accepted) min_accepted = w->accepted;
        if (w->accepted > max_accepted) max_accepted = w->accepted;
    }
    uint64_t done = __atomic_load_n(&st->accepted, __ATOMIC_ACQUIRE);
    printf("{\"mode\":\"%s\",\"workers\":%ld,\"attempts\":%ld,\"sent\":%d,"
           "\"accepted\":%" PRIu64 ",\"gap_us\":%ld,\"elapsed_s\":%.6f,"
           "\"generated_s\":%.6f,\"rate_per_s\":%.2f,"
           "\"worker_cpu_s\":%.6f,\"wakeup_events\":%" PRIu64 ","
           "\"zero_accept_wakeups\":%" PRIu64 ",\"accept_syscalls\":%" PRIu64 ","
           "\"min_worker_accepted\":%" PRIu64 ",\"max_worker_accepted\":%" PRIu64 ","
           "\"timed_out\":%s,\"child_failure\":%s}\n",
           argv[1], nworkers, nconnections, sent, done, gap, elapsed,
           generated, elapsed > 0 ? done / elapsed : 0.0, cpu_sec,
           wakes, no_accept, calls, min_accepted, max_accepted,
           timed_out ? "true" : "false", child_failure ? "true" : "false");
    munmap(st, sizeof(*st));
    return (timed_out || child_failure || (int)done != sent || sent != nconnections) ? 1 : 0;
}
