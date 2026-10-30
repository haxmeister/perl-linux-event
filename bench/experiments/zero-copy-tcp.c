#define _GNU_SOURCE
#define _FILE_OFFSET_BITS 64
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sendfile.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

/*
 * Research only: Linux file -> loopback TCP transfer, NOT a Stream feature.
 * Compare pread/send, sendfile, and file->pipe->socket splice.
 * Sender is nonblocking; receiver checks ALL bytes. Both CPU times are
 * measured using separate CLOCK_THREAD_CPUTIME_ID clocks.
 */
typedef struct { uint64_t preads, sends, sendfiles, splices, polls, eagains; } counters;
typedef struct {
    int listener, error;
    const unsigned char *source;
    size_t size;
    uint64_t expected, received, corrupt;
    double cpu_s;
    unsigned pressure_us;
} receiver;

static double clock_s(clockid_t kind) {
    struct timespec t;
    if (clock_gettime(kind, &t)) { perror("clock_gettime"); exit(2); }
    return t.tv_sec + t.tv_nsec / 1e9;
}
static void die(const char *where) { perror(where); exit(2); }
static void writable(int fd, counters *count) {
    struct pollfd p = {.fd=fd, .events=POLLOUT};
    int n;
    count->polls++;
    do { n=poll(&p,1,5000); } while(n<0 && errno==EINTR);
    if (n<=0 || (p.revents & (POLLHUP|POLLERR|POLLNVAL))) {
        fprintf(stderr,"poll writable failure (result=%d revents=%d)\n",n,p.revents);
        exit(2);
    }
}
static void *sink(void *arg) {
    receiver *r=(receiver *)arg;
    int fd=accept4(r->listener,NULL,NULL,SOCK_CLOEXEC);
    if(fd<0) { r->error=errno; return NULL; }
    unsigned char buf[65536];
    double start=clock_s(CLOCK_THREAD_CPUTIME_ID);
    for (;;) {
        ssize_t n=recv(fd,buf,sizeof(buf),0);
        if(n<0) { if(errno==EINTR)continue; r->error=errno; break; }
        if(n==0)break;
        size_t at=0;
        while(at<(size_t)n) {
            size_t off=(size_t)(r->received%r->size);
            size_t avail=r->size-off;
            if(avail>(size_t)n-at)avail=(size_t)n-at;
            if(memcmp(buf+at,r->source+off,avail))r->corrupt++;
            r->received+=avail;
            at+=avail;
        }
        if(r->pressure_us) {
            struct timespec t={0,(long)r->pressure_us*1000};
            nanosleep(&t,NULL);
        }
    }
    r->cpu_s=clock_s(CLOCK_THREAD_CPUTIME_ID)-start;
    close(fd);
    return NULL;
}
static void copy_one(int file,int sock,size_t bytes,counters *c) {
    unsigned char buf[65536];
    size_t left=bytes;
    off_t offset=0;
    while(left) {
        size_t want=left<sizeof(buf)?left:sizeof(buf);
        ssize_t n;
        do { c->preads++; n=pread(file,buf,want,offset); } while(n<0&&errno==EINTR);
        if(n<=0)die("pread");
        offset+=n; left-=(size_t)n;
        size_t at=0;
        while(at<(size_t)n) {
            ssize_t w;
            do {c->sends++;w=send(sock,buf+at,(size_t)n-at,MSG_NOSIGNAL|MSG_DONTWAIT);}
            while(w<0&&errno==EINTR);
            if(w<0&&(errno==EAGAIN||errno==EWOULDBLOCK)) {
                c->eagains++; writable(sock,c); continue;
            }
            if(w<=0)die("send");
            at+=(size_t)w;
        }
    }
}
static void sendfile_one(int file,int sock,size_t bytes,counters *c) {
    off_t offset=0;
    size_t left=bytes;
    while(left) {
        ssize_t n;
        do {c->sendfiles++;n=sendfile(sock,file,&offset,left);}while(n<0&&errno==EINTR);
        if(n<0&&(errno==EAGAIN||errno==EWOULDBLOCK)) {
            c->eagains++; writable(sock,c); continue;
        }
        if(n<=0)die("sendfile");
        left-=(size_t)n;
    }
}
static void splice_one(int file,int sock,int pipefd[2],size_t bytes,counters *c) {
    off_t offset=0;
    size_t left=bytes;
    while(left) {
        size_t chunk=left<65536?left:65536;
        ssize_t n;
        do {c->splices++;n=splice(file,&offset,pipefd[1],NULL,chunk,SPLICE_F_NONBLOCK);}
        while(n<0&&errno==EINTR);
        if(n<0&&(errno==EAGAIN||errno==EWOULDBLOCK)) {
            c->eagains++;writable(pipefd[1],c);continue;
        }
        if(n<=0)die("splice file to pipe");
        left-=(size_t)n;
        size_t pending=(size_t)n;
        while(pending) {
            ssize_t w;
            do {c->splices++;w=splice(pipefd[0],NULL,sock,NULL,pending,SPLICE_F_NONBLOCK);}
            while(w<0&&errno==EINTR);
            if(w<0&&(errno==EAGAIN||errno==EWOULDBLOCK)) {
                c->eagains++;writable(sock,c);continue;
            }
            if(w<=0)die("splice pipe to socket");
            pending-=(size_t)w;
        }
    }
}
static void trial(const char *mode,int file,const unsigned char *source,
                  size_t bytes,uint64_t rounds,int repeat,unsigned pressure_us) {
    int listen_fd=socket(AF_INET,SOCK_STREAM|SOCK_CLOEXEC,0);
    if(listen_fd<0)die("socket listen");
    struct sockaddr_in addr={.sin_family=AF_INET,.sin_port=htons(0),
                             .sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
    if(bind(listen_fd,(struct sockaddr *)&addr,sizeof(addr))<0)die("bind");
    if(listen(listen_fd,4)<0)die("listen");
    socklen_t alen=sizeof(addr);
    if(getsockname(listen_fd,(struct sockaddr *)&addr,&alen)<0)die("getsockname");
    receiver rx={.listener=listen_fd,.source=source,.size=bytes,
                 .expected=(uint64_t)bytes*rounds,.pressure_us=pressure_us};
    pthread_t thread;
    if(pthread_create(&thread,NULL,sink,&rx))die("pthread_create");
    int sock=socket(AF_INET,SOCK_STREAM|SOCK_CLOEXEC,0);
    if(sock<0)die("socket connect");
    if(connect(sock,(struct sockaddr *)&addr,sizeof(addr))<0)die("connect");
    int flags=fcntl(sock,F_GETFL);
    if(flags<0 || fcntl(sock,F_SETFL,flags|O_NONBLOCK)<0)die("fcntl");
    int pipefd[2]={-1,-1};
    if(!strcmp(mode,"splice")&&pipe2(pipefd,O_CLOEXEC|O_NONBLOCK)<0)die("pipe2");
    counters count={0};
    double wall_at=clock_s(CLOCK_MONOTONIC), cpu_at=clock_s(CLOCK_THREAD_CPUTIME_ID);
    for(uint64_t i=0;i<rounds;i++) {
        if(!strcmp(mode,"copy"))copy_one(file,sock,bytes,&count);
        else if(!strcmp(mode,"sendfile"))sendfile_one(file,sock,bytes,&count);
        else if(!strcmp(mode,"splice"))splice_one(file,sock,pipefd,bytes,&count);
        else {fprintf(stderr,"bad mode %s\n",mode);exit(2);}
    }
    double cpu=clock_s(CLOCK_THREAD_CPUTIME_ID)-cpu_at;
    double enqueue_wall=clock_s(CLOCK_MONOTONIC)-wall_at;
    if(shutdown(sock,SHUT_WR)<0)die("shutdown");
    if(pthread_join(thread,NULL))die("pthread_join");
    double end_to_end_wall=clock_s(CLOCK_MONOTONIC)-wall_at;
    if(pipefd[0]>=0){close(pipefd[0]);close(pipefd[1]);}
    close(sock);close(listen_fd);
    if(rx.error||rx.corrupt||rx.received!=rx.expected) {
        fprintf(stderr,"VERIFY FAIL: %s size=%zu received=%"PRIu64" wanted=%"PRIu64
                " error=%d corrupt=%"PRIu64"\n",mode,bytes,rx.received,rx.expected,rx.error,rx.corrupt);
        exit(3);
    }
    double mib=(double)rx.received/1048576.0;
    printf("{\"mode\":\"%s\",\"size\":%zu,\"rounds\":%"PRIu64",\"repeat\":%d,"
           "\"pressure_us\":%u,\"bytes\":%"PRIu64",\"verified\":true,"
           "\"enqueue_wall_s\":%.9f,\"wall_s\":%.9f,\"sender_cpu_s\":%.9f,\"receiver_cpu_s\":%.9f,"
           "\"mib_s\":%.3f,\"sender_cpu_ms_per_mib\":%.6f,"
           "\"calls\":{\"pread\":%"PRIu64",\"send\":%"PRIu64",\"sendfile\":%"PRIu64
           ",\"splice\":%"PRIu64",\"poll\":%"PRIu64",\"eagain\":%"PRIu64"}}\n",
           mode,bytes,rounds,repeat,pressure_us,rx.received,enqueue_wall,end_to_end_wall,cpu,rx.cpu_s,
           mib/end_to_end_wall,1000*cpu/mib,count.preads,count.sends,count.sendfiles,
           count.splices,count.polls,count.eagains);
    fflush(stdout);
}
static unsigned long positive(const char *str) {
    char *end=NULL;
    errno=0;
    unsigned long value=strtoul(str,&end,10);
    if(errno||end==str||!end||*end){fprintf(stderr,"bad numeric argument %s\n",str);exit(2);}
    return value;
}
int main(int argc,char **argv) {
    size_t bytes=204800;
    uint64_t rounds=400;
    int repeats=3;
    unsigned pressure_us=0;
    for(int i=1;i<argc;i++) {
        if(i+1>=argc){fprintf(stderr,"argument %s requires value\n",argv[i]);return 2;}
        if(!strcmp(argv[i],"--size")) bytes=positive(argv[++i]);
        else if(!strcmp(argv[i],"--rounds")) rounds=positive(argv[++i]);
        else if(!strcmp(argv[i],"--repeats")) repeats=positive(argv[++i]);
        else if(!strcmp(argv[i],"--pressure-us")) pressure_us=positive(argv[++i]);
        else {fprintf(stderr,"unknown argument %s\n",argv[i]);return 2;}
    }
    if(bytes<64||bytes>1048576||rounds<1||rounds>1000000||
       repeats<1||repeats>10||pressure_us>1000||
       (uint64_t)bytes*rounds>512ULL*1024*1024) {
        fprintf(stderr,"out-of-range benchmark settings\n");return 2;
    }
    signal(SIGPIPE,SIG_IGN);
    unsigned char *source=malloc(bytes);
    if(!source)die("malloc");
    for(size_t i=0;i<bytes;i++)source[i]=(unsigned char)((i*67u+(i>>3)*53u+19u)&255u);
    char path[]="/tmp/linux-event-zero-copy-XXXXXX";
    int file=mkstemp(path);
    if(file<0)die("mkstemp");
    unlink(path);
    size_t wrote=0;
    while(wrote<bytes) {
        ssize_t n=write(file,source+wrote,bytes-wrote);
        if(n<0&&errno==EINTR)continue;
        if(n<=0)die("prepare file");
        wrote+=(size_t)n;
    }
    for(int r=0;r<repeats;r++) {
        const char *modes[]={"copy","sendfile","splice"};
        for(int n=0;n<3;n++)
            trial(modes[(n+r)%3],file,source,bytes,rounds,r+1,pressure_us);
    }
    close(file);free(source);
    return 0;
}
