#define _GNU_SOURCE
#include "include/ExecSupervisor.h"
#include <spawn.h>
#include <stdio.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/wait.h>
#include <sys/ioctl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#ifdef __APPLE__
#include <libproc.h>
#include <mach-o/dyld.h>
#include <limits.h>
#endif
extern char **environ;
#ifdef __APPLE__
extern int responsibility_spawnattrs_setdisclaim(posix_spawnattr_t *, int) __attribute__((weak_import));
#endif

int exec_process_birth(int pid, uint64_t *birth) {
#ifdef __APPLE__
    struct proc_bsdinfo info;
    errno=0;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return errno ? errno : EIO;
    *birth = info.pbi_start_tvsec * 1000000 + info.pbi_start_tvusec;
#else
    char path[64], bytes[4096];
    snprintf(path,sizeof(path),"/proc/%d/stat",pid);
    FILE *file=fopen(path,"r");
    if(!file) return errno==ENOENT ? ESRCH : errno;
    size_t count=fread(bytes,1,sizeof(bytes)-1,file);
    int failure=ferror(file);
    fclose(file);
    if(!count || failure || count==sizeof(bytes)-1) return EIO;
    bytes[count]=0;
    char *tail=strrchr(bytes,')');
    if(!tail) return EIO;
    char *save=NULL, *field=strtok_r(tail+2," ",&save);
    for(int index=3;field;index++,field=strtok_r(NULL," ",&save)) {
        if(index!=22) continue;
        char *end;
        *birth=strtoull(field,&end,10);
        return *birth && (*end==0 || *end=='\n') ? 0 : EIO;
    }
    return EIO;
#endif
    return 0;
}

int exec_disclaim_responsibility_available(void) {
#ifdef __APPLE__
    return responsibility_spawnattrs_setdisclaim != NULL;
#else
    return 0;
#endif
}

static int make_pipe(int p[2]) {
    if (pipe(p)) return errno;
    fcntl(p[0], F_SETFD, FD_CLOEXEC);
    fcntl(p[1], F_SETFD, FD_CLOEXEC);
    return 0;
}
static void close_pipe(int p[2]) { if(p[0]>=0) close(p[0]); if(p[1]>=0) close(p[1]); }
static int close_inherited(posix_spawn_file_actions_t *actions, short *flags) {
#ifdef __APPLE__
    *flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
    return 0;
#else
    (void)flags;
    return posix_spawn_file_actions_addclosefrom_np(actions,3);
#endif
}
static void nonblocking(int fd) { fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK); }
static int spawn_exec(char *const argv[], char *const env[], const char *cwd, int disclaim_responsibility, exec_disclaim_setter setter, int receipt, int publication, exec_child *child);
int exec_spawn(char *const argv[], char *const env[], const char *cwd, int disclaim_responsibility, exec_child *child) {
    return exec_spawn_with_receipt(argv,env,cwd,disclaim_responsibility,-1,-1,child);
}
int exec_spawn_with_receipt(char *const argv[], char *const env[], const char *cwd, int disclaim_responsibility, int receipt, int publication, exec_child *child) {
#ifdef __APPLE__
    exec_disclaim_setter setter=responsibility_spawnattrs_setdisclaim;
#else
    exec_disclaim_setter setter=NULL;
#endif
    return spawn_exec(argv,env,cwd,disclaim_responsibility,setter,receipt,publication,child);
}
int exec_spawn_with_disclaimer(char *const argv[], char *const env[], const char *cwd, int disclaim_responsibility, exec_disclaim_setter setter, exec_child *child) {
    return spawn_exec(argv,env,cwd,disclaim_responsibility,setter,-1,-1,child);
}
static int spawn_exec(char *const argv[], char *const env[], const char *cwd, int disclaim_responsibility, exec_disclaim_setter setter, int receipt, int publication, exec_child *child) {
    int a[2]={-1,-1},b[2]={-1,-1},c[2]={-1,-1},errors[2]={-1,-1};
    int r=make_pipe(a); if(!r) r=make_pipe(b); if(!r) r=make_pipe(c);
    if(!r && receipt>=0) r=make_pipe(errors);
    int inherited[3]={-1,-1,-1};
    if(!r && receipt>=0) {
        int originals[]={receipt,publication,errors[1]};
        for(int i=0;i<3;i++) {
            inherited[i]=fcntl(originals[i],F_DUPFD_CLOEXEC,6);
            if(inherited[i]<0) { r=errno;break; }
        }
    }
    if(r) { close_pipe(a);close_pipe(b);close_pipe(c);close_pipe(errors);for(int i=0;i<3;i++) if(inherited[i]>=0)close(inherited[i]);return r; }
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attr;
    posix_spawn_file_actions_init(&actions);posix_spawnattr_init(&attr);
    posix_spawn_file_actions_adddup2(&actions,a[0],0);
    posix_spawn_file_actions_adddup2(&actions,b[1],1);
    posix_spawn_file_actions_adddup2(&actions,c[1],2);
    for(int i=0;i<2;i++) { posix_spawn_file_actions_addclose(&actions,a[i]);posix_spawn_file_actions_addclose(&actions,b[i]);posix_spawn_file_actions_addclose(&actions,c[i]); }
    #ifdef __APPLE__
    r=posix_spawn_file_actions_addchdir(&actions,cwd);
    #else
    r=posix_spawn_file_actions_addchdir_np(&actions,cwd);
    #endif
    sigset_t defaults,mask;sigemptyset(&defaults);sigemptyset(&mask);
    sigaddset(&defaults,SIGPIPE);sigaddset(&defaults,SIGTERM);sigaddset(&defaults,SIGINT);
    posix_spawnattr_setsigdefault(&attr,&defaults);posix_spawnattr_setsigmask(&attr,&mask);
    posix_spawnattr_setpgroup(&attr,0);
    short flags=POSIX_SPAWN_SETPGROUP|POSIX_SPAWN_SETSIGDEF|POSIX_SPAWN_SETSIGMASK;
    if(!r && receipt>=0) {
        for(int i=0;i<3 && !r;i++) r=posix_spawn_file_actions_adddup2(&actions,inherited[i],i+3);
#ifdef __APPLE__
        flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#else
        if(!r) r=posix_spawn_file_actions_addclosefrom_np(&actions,6);
#endif
    } else if(!r) r=close_inherited(&actions,&flags);
    if(!r) r=posix_spawnattr_setflags(&attr,flags);
#ifdef __APPLE__
    if(!r && disclaim_responsibility && setter) {
        r=setter(&attr,1);
    }
#else
    (void)disclaim_responsibility;
    (void)setter;
#endif
    pid_t pid=0;
    if(!r && receipt>=0) {
#ifdef __APPLE__
        char executable[PATH_MAX];
        uint32_t size=sizeof(executable);
        if(_NSGetExecutablePath(executable,&size)) r=ENAMETOOLONG;
#else
        const char *executable="/proc/self/exe";
#endif
        size_t count=0;while(argv[count]) count++;
        char **arguments=calloc(count+5,sizeof(char *));
        char default_path[4096];
        const char *path=getenv("PATH");
        if(!path) {
            if(!confstr(_CS_PATH,default_path,sizeof(default_path))) r=EIO;
            path=default_path;
        }
        if(!arguments) r=ENOMEM;
        if(!r) {
            arguments[0]=(char *)executable;arguments[1]="machine-v2";arguments[2]="exec-child";arguments[3]=(char *)path;
            for(size_t i=0;i<count;i++) arguments[i+4]=argv[i];
            r=posix_spawn(&pid,executable,&actions,&attr,arguments,env);
        }
        free(arguments);
    } else if(!r) r=posix_spawnp(&pid,argv[0],&actions,&attr,argv,env);
    posix_spawn_file_actions_destroy(&actions);posix_spawnattr_destroy(&attr);
    close(a[0]);close(b[1]);close(c[1]);
    for(int i=0;i<3;i++) if(inherited[i]>=0)close(inherited[i]);
    if(errors[1]>=0)close(errors[1]);
    if(!r && receipt>=0) {
        int failure=0;size_t received=0;
        while(received<sizeof(failure)) {
            ssize_t n=read(errors[0],((char *)&failure)+received,sizeof(failure)-received);
            if(n<0 && errno==EINTR) continue;
            if(n<0) { r=errno;break; }
            if(!n) break;
            received+=(size_t)n;
        }
        if(received) r=received==sizeof(failure) ? failure : EIO;
    }
    if(errors[0]>=0)close(errors[0]);
    if(r) {
        if(pid>0) { kill(-pid,SIGKILL);while(waitpid(pid,NULL,0)<0 && errno==EINTR) {} }
        close(a[1]);close(b[0]);close(c[0]);return r;
    }
    nonblocking(a[1]);nonblocking(b[0]);nonblocking(c[0]);
    child->pid=pid;child->input=a[1];child->output=b[0];child->error=c[0];return 0;
}
static int child_exec(char *const arguments[]) {
    if(!arguments[0] || !arguments[1]) return EINVAL;
    const char *path=arguments[0];
    char *const *argv=arguments+1;
    if(strchr(argv[0],'/')) { execve(argv[0],argv,environ);return errno; }
    int denied=0;
    const char *begin=path;
    do {
        const char *end=strchr(begin,':');
        size_t length=end ? (size_t)(end-begin) : strlen(begin);
        char *candidate=malloc(length+strlen(argv[0])+2);
        if(!candidate) return ENOMEM;
        if(length) { memcpy(candidate,begin,length);candidate[length]='/';strcpy(candidate+length+1,argv[0]); }
        else strcpy(candidate,argv[0]);
        execve(candidate,argv,environ);
        int failure=errno;
        free(candidate);
        if(failure==EACCES) denied=1;
        else if(failure!=ENOENT && failure!=ENOTDIR) return failure;
        if(!end) break;
        begin=end+1;
    } while(1);
    return denied ? EACCES : ENOENT;
}
void exec_run_child(char *const arguments[]) {
    int failure=getpgrp()==getpid() ? 0 : EINVAL;
    if(fcntl(5,F_SETFD,FD_CLOEXEC)<0) failure=errno;
    uint64_t birth=0;
    if(!failure) failure=exec_process_birth(getpid(),&birth);
    char bytes[96];
    int length=snprintf(bytes,sizeof(bytes),"%d %llu",getpid(),(unsigned long long)birth);
    if(!failure && (ftruncate(3,0) || pwrite(3,bytes,(size_t)length,0)!=length)) failure=errno ? errno : EIO;
    close(4);
    if(!failure) failure=child_exec(arguments);
    const char *cursor=(const char *)&failure;
    size_t left=sizeof(failure);
    while(left) {
        ssize_t n=write(5,cursor,left);
        if(n<0 && errno==EINTR) continue;
        if(n<=0) break;
        cursor+=n;left-=(size_t)n;
    }
    _exit(127);
}
int exec_observe(int pid,int *tag,int *value) {
    siginfo_t info={0};
    if(waitid(P_PID,(id_t)pid,&info,WEXITED|WNOHANG|WNOWAIT)) return -errno;
    if(!info.si_pid) return 0;
    *tag=info.si_code==CLD_EXITED?0:1;*value=info.si_status;return 1;
}
int exec_reap(int pid) { int status; return waitpid(pid,&status,0)<0 ? errno : 0; }
static void *exec_reaper(void *argument) { int status; pid_t pid=(pid_t)(intptr_t)argument; while(waitpid(pid,&status,0)<0 && errno==EINTR) {} return NULL; }
int exec_reap_when_exited(int pid) {
    pthread_attr_t attr; pthread_t thread;
    int r=pthread_attr_init(&attr);
    if(r) return r;
    r=pthread_attr_setdetachstate(&attr,PTHREAD_CREATE_DETACHED);
    if(!r) r=pthread_create(&thread,&attr,exec_reaper,(void *)(intptr_t)pid);
    pthread_attr_destroy(&attr);
    return r;
}
int exec_reap_nonblocking(int pid) { int status; int r=waitpid(pid,&status,WNOHANG); return r<0 ? -errno : r==pid; }
int exec_signal_group(int pid,int sig) { return kill(-pid,sig)<0 && errno!=ESRCH?errno:0; }
int exec_pending(int fd) { int n=0;return ioctl(fd,FIONREAD,&n)<0 ? -errno : n; }
int exec_read(int fd,void *bytes,size_t count) { ssize_t n=read(fd,bytes,count);return n<0?-errno:(int)n; }
int exec_write(int fd,const void *bytes,size_t count) { ssize_t n=write(fd,bytes,count);return n<0?-errno:(int)n; }
void exec_close(int fd) { if(fd>=0) close(fd); }
int exec_launch_detached(char *const argv[],int *pid) {
    posix_spawn_file_actions_t actions;posix_spawnattr_t attr;
    posix_spawn_file_actions_init(&actions);posix_spawnattr_init(&attr);
    for(int fd=0;fd<3;fd++) posix_spawn_file_actions_addopen(&actions,fd,"/dev/null",fd==0?O_RDONLY:O_WRONLY,0);
    short flags=POSIX_SPAWN_SETPGROUP;
    int r=posix_spawnattr_setpgroup(&attr,0);
    if(!r) r=close_inherited(&actions,&flags);
    if(!r) r=posix_spawnattr_setflags(&attr,flags);
    pid_t child;
    if(!r) r=posix_spawn(&child,argv[0],&actions,&attr,argv,environ);
    posix_spawn_file_actions_destroy(&actions);posix_spawnattr_destroy(&attr);
    if(!r) *pid=child;
    return r;
}
#include <sys/file.h>
#include <sys/stat.h>
int exec_lock_file(const char *path, int create) {
    int fd=open(path,O_RDWR|O_NOFOLLOW|O_CLOEXEC|(create?O_CREAT:0),0600);
    if(fd<0) return -errno;
    struct stat state;
    if(fstat(fd,&state) || state.st_uid!=getuid() || (state.st_mode&0777)!=0600 || flock(fd,LOCK_EX|LOCK_NB)) { int e=errno?errno:EACCES;close(fd);return -e; }
    return fd;
}

int exec_lock_agent(const char *directory) {
    char path[4096];
    if(snprintf(path,sizeof(path),"%s/.agent.lock",directory)>=(int)sizeof(path)) return -ENAMETOOLONG;
    return exec_lock_file(path,1);
}

#include <poll.h>
#include <string.h>
#include <time.h>
#include <sys/socket.h>
#include <sys/un.h>
static long exec_remaining_ms(const struct timespec *until) {
    struct timespec now; clock_gettime(CLOCK_MONOTONIC,&now);
    long ms=(until->tv_sec-now.tv_sec)*1000+(until->tv_nsec-now.tv_nsec)/1000000;
    return ms>0?ms:0;
}
int exec_unix_request(const char *path, const void *bytes, size_t count, int timeout_ms) {
    struct sockaddr_un address; memset(&address,0,sizeof(address)); address.sun_family=AF_UNIX;
    if(strlen(path)>=sizeof(address.sun_path)) return -ENAMETOOLONG;
    strcpy(address.sun_path,path);
    int fd=socket(AF_UNIX,SOCK_STREAM,0);
    if(fd<0) return -errno;
    fcntl(fd,F_SETFD,FD_CLOEXEC); fcntl(fd,F_SETFL,O_NONBLOCK);
#ifdef SO_NOSIGPIPE
    int one=1; setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one));
#endif
    struct timespec until; clock_gettime(CLOCK_MONOTONIC,&until);
    until.tv_sec+=timeout_ms/1000; until.tv_nsec+=(long)(timeout_ms%1000)*1000000;
    if(until.tv_nsec>=1000000000) { until.tv_sec+=1; until.tv_nsec-=1000000000; }
    if(connect(fd,(struct sockaddr *)&address,sizeof(address))) {
        int e=errno;
        if(e!=EINPROGRESS && e!=EAGAIN) { close(fd); return -e; }
        struct pollfd ready={fd,POLLOUT,0};
        int error=0; socklen_t size=sizeof(error);
        if(poll(&ready,1,(int)exec_remaining_ms(&until))<=0 || getsockopt(fd,SOL_SOCKET,SO_ERROR,&error,&size) || error) { close(fd); return -(error?error:ETIMEDOUT); }
    }
    size_t sent=0;
    while(sent<count) {
#ifdef MSG_NOSIGNAL
        ssize_t n=send(fd,(const char *)bytes+sent,count-sent,MSG_NOSIGNAL);
#else
        ssize_t n=send(fd,(const char *)bytes+sent,count-sent,0);
#endif
        if(n>0) { sent+=(size_t)n; continue; }
        if(n<0 && errno!=EAGAIN && errno!=EINTR) { int e=errno; close(fd); return -e; }
        struct pollfd ready={fd,POLLOUT,0};
        if(poll(&ready,1,(int)exec_remaining_ms(&until))<=0) { close(fd); return -ETIMEDOUT; }
    }
    char sink[512];
    for(;;) {
        struct pollfd ready={fd,POLLIN,0};
        if(poll(&ready,1,(int)exec_remaining_ms(&until))<=0) break;
        ssize_t n=read(fd,sink,sizeof(sink));
        if(n>0) break;
        if(n==0 || (errno!=EAGAIN && errno!=EINTR)) break;
    }
    close(fd);
    return 0;
}
