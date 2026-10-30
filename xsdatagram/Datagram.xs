/* Needed for recvmmsg() / struct mmsghdr on glibc. Linux-only module. */
#ifndef _GNU_SOURCE
# define _GNU_SOURCE 1
#endif
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

MODULE = Linux::Event::_Socket::Dgram    PACKAGE = Linux::Event::_Socket::Dgram

PROTOTYPES: DISABLE

SV *
_recv_batch(fd, maximum_size, maximum_count)
    int fd
    UV maximum_size
    UV maximum_count
  PREINIT:
    unsigned char *buffer;
    AV *batch;
    UV received = 0;
    int saved_errno = 0;
  CODE:
    if (maximum_size == 0 || maximum_size > 16777216)
        croak("maximum datagram size must be between 1 and 16777216 bytes");
    /*
     * Private benchmark switch. No application-facing API is changed.
     * A bounded 256-KiB scratch area and at most 32 messages prevent
     * large max_datagram_size settings from multiplying allocations.
     * In particular, a single oversized datagram still follows recvmsg.
     */
    {
        const char *setting = getenv("LINUX_EVENT_EXPERIMENT_RECVMMSG");
        UV slots = 0;
        if (setting && setting[0] >= '1' && setting[0] <= '9') {
            char *end = NULL;
            unsigned long requested = strtoul(setting, &end, 10);
            if (end && *end == '\0' && requested >= 2)
                slots = requested > 32 ? 32 : (UV)requested;
        }
        if (maximum_size > 262144)
            slots = 0;
        else if (slots > 262144 / maximum_size)
            slots = 262144 / maximum_size;
        if (slots > 1) {
            struct mmsghdr messages[32];
            struct iovec iovecs[32];
            struct sockaddr_storage peers[32];
            unsigned char *packet_buffers;
            UV per_batch = slots;
            UV count = 0;
            int batch_errno = 0;
            AV *results = newAV();

            packet_buffers = (unsigned char *)malloc(
                (size_t)maximum_size * (size_t)per_batch);
            if (!packet_buffers)
                croak("cannot allocate datagram receive batch buffers");
            av_push(results, newSViv(0));
            for (;;) {
                unsigned int wanted = (unsigned int)per_batch;
                int got;
                UV k;
                if (maximum_count && count >= maximum_count)
                    break;
                if (maximum_count && maximum_count - count < wanted)
                    wanted = (unsigned int)(maximum_count - count);
                memset(messages, 0, sizeof(messages));
                memset(peers, 0, sizeof(peers));
                for (k = 0; k < wanted; k++) {
                    iovecs[k].iov_base = packet_buffers
                        + k * (size_t)maximum_size;
                    iovecs[k].iov_len = (size_t)maximum_size;
                    messages[k].msg_hdr.msg_name = &peers[k];
                    messages[k].msg_hdr.msg_namelen = sizeof(peers[k]);
                    messages[k].msg_hdr.msg_iov = &iovecs[k];
                    messages[k].msg_hdr.msg_iovlen = 1;
                }
                do {
                    got = recvmmsg(fd, messages, wanted,
                        MSG_DONTWAIT | MSG_TRUNC, NULL);
                } while (got < 0 && errno == EINTR);
                if (got < 0) {
                    if (errno != EAGAIN && errno != EWOULDBLOCK)
                        batch_errno = errno;
                    break;
                }
                if (got == 0)
                    break;
                for (k = 0; k < (UV)got; k++) {
                    UV length = (UV)messages[k].msg_len;
                    int truncated = (messages[k].msg_hdr.msg_flags
                        & MSG_TRUNC) != 0 || length > maximum_size;
                    if (truncated)
                        av_push(results, newSV(0));
                    else
                        av_push(results, newSVpvn(
                            (const char *)(packet_buffers
                                + k * (size_t)maximum_size),
                            (STRLEN)length));
                    av_push(results, newSVpvn((const char *)&peers[k],
                        (STRLEN)messages[k].msg_hdr.msg_namelen));
                    av_push(results, newSVuv(length));
                    av_push(results, newSViv(truncated));
                }
                count += (UV)got;
            }
            free(packet_buffers);
            sv_setiv(*av_fetch(results, 0, 0), batch_errno);
            RETVAL = newRV_noinc((SV *)results);
            goto _recv_batch_done;
        }
    }
    buffer = (unsigned char *)malloc((size_t)maximum_size);
    if (!buffer)
        croak("cannot allocate datagram receive buffer");
    batch = newAV();
    av_push(batch, newSViv(0));
    while (maximum_count == 0 || received < maximum_count) {
        struct sockaddr_storage peer;
        struct iovec iov;
        struct msghdr message;
        ssize_t length;
        int truncated;

        memset(&peer, 0, sizeof(peer));
        memset(&message, 0, sizeof(message));
        iov.iov_base = buffer;
        iov.iov_len = (size_t)maximum_size;
        message.msg_name = &peer;
        message.msg_namelen = sizeof(peer);
        message.msg_iov = &iov;
        message.msg_iovlen = 1;
        do {
            length = recvmsg(fd, &message, MSG_DONTWAIT | MSG_TRUNC);
        } while (length < 0 && errno == EINTR);
        if (length < 0) {
            if (errno != EAGAIN && errno != EWOULDBLOCK)
                saved_errno = errno;
            break;
        }
        truncated = (message.msg_flags & MSG_TRUNC) != 0
            || (UV)length > maximum_size;
        if (truncated)
            av_push(batch, newSV(0));
        else
            av_push(batch, newSVpvn((const char *)buffer, (STRLEN)length));
        av_push(batch, newSVpvn((const char *)&peer,
            (STRLEN)message.msg_namelen));
        av_push(batch, newSVuv((UV)length));
        av_push(batch, newSViv(truncated));
        received++;
    }
    free(buffer);
    sv_setiv(*av_fetch(batch, 0, 0), saved_errno);
    RETVAL = newRV_noinc((SV *)batch);
  _recv_batch_done:
  OUTPUT:
    RETVAL

void
_send_packet(fd, payload, address = &PL_sv_undef)
    int fd
    SV *payload
    SV *address
  PREINIT:
    STRLEN payload_length, address_length = 0;
    const char *payload_bytes, *address_bytes = NULL;
    ssize_t sent;
    int saved_errno = 0;
  PPCODE:
    payload_bytes = SvPVbyte(payload, payload_length);
    if (SvOK(address))
        address_bytes = SvPVbyte(address, address_length);
    do {
        if (address_bytes) {
            sent = sendto(fd, payload_bytes, payload_length,
                MSG_DONTWAIT | MSG_NOSIGNAL,
                (const struct sockaddr *)address_bytes,
                (socklen_t)address_length);
        } else {
            sent = send(fd, payload_bytes, payload_length,
                MSG_DONTWAIT | MSG_NOSIGNAL);
        }
    } while (sent < 0 && errno == EINTR);
    if (sent < 0)
        saved_errno = errno;
    EXTEND(SP, 2);
    PUSHs(sv_2mortal(newSViv((IV)sent)));
    PUSHs(sv_2mortal(newSViv(saved_errno)));
