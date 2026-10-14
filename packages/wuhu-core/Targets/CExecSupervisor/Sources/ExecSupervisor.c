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
extern char **environ;

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
int exec_spawn(char *const argv[], char *const env[], const char *cwd, exec_child *child) {
    int a[2]={-1,-1},b[2]={-1,-1},c[2]={-1,-1};
    int r=make_pipe(a); if(!r) r=make_pipe(b); if(!r) r=make_pipe(c);
    if(r) { close_pipe(a);close_pipe(b);close_pipe(c);return r; }
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
    if(!r) r=close_inherited(&actions,&flags);
    if(!r) r=posix_spawnattr_setflags(&attr,flags);
    pid_t pid;
    if(!r) r=posix_spawnp(&pid,argv[0],&actions,&attr,argv,env);
    posix_spawn_file_actions_destroy(&actions);posix_spawnattr_destroy(&attr);
    close(a[0]);close(b[1]);close(c[1]);
    if(r) { close(a[1]);close(b[0]);close(c[0]);return r; }
    nonblocking(a[1]);nonblocking(b[0]);nonblocking(c[0]);
    child->pid=pid;child->input=a[1];child->output=b[0];child->error=c[0];return 0;
}
int exec_observe(int pid,int *tag,int *value) {
    siginfo_t info={0};
    if(waitid(P_PID,(id_t)pid,&info,WEXITED|WNOHANG|WNOWAIT)) return -errno;
    if(!info.si_pid) return 0;
    *tag=info.si_code==CLD_EXITED?0:1;*value=info.si_status;return 1;
}
int exec_reap(int pid) { int status; return waitpid(pid,&status,0)<0 ? errno : 0; }
int exec_reap_nonblocking(int pid) { int status; int r=waitpid(pid,&status,WNOHANG); return r<0 ? -errno : r==pid; }
int exec_signal_group(int pid,int sig) { return kill(-pid,sig)<0 && errno!=ESRCH?errno:0; }
int exec_pending(int fd) { int n=0;return ioctl(fd,FIONREAD,&n)<0 ? -errno : n; }
int exec_read(int fd,void *bytes,size_t count) { ssize_t n=read(fd,bytes,count);return n<0?-errno:(int)n; }
int exec_write(int fd,const void *bytes,size_t count) { ssize_t n=write(fd,bytes,count);return n<0?-errno:(int)n; }
void exec_close(int fd) { if(fd>=0) close(fd); }
int exec_launch_supervisor(const char *executable,const char *directory,int *pid) {
    posix_spawn_file_actions_t actions;posix_spawnattr_t attr;
    posix_spawn_file_actions_init(&actions);posix_spawnattr_init(&attr);
    for(int fd=0;fd<3;fd++) posix_spawn_file_actions_addopen(&actions,fd,"/dev/null",fd==0?O_RDONLY:O_WRONLY,0);
    short flags=POSIX_SPAWN_SETPGROUP;
    int r=posix_spawnattr_setpgroup(&attr,0);
    if(!r) r=close_inherited(&actions,&flags);
    if(!r) r=posix_spawnattr_setflags(&attr,flags);
    char *args[]={(char *)executable,"machine-v2","supervise",(char *)directory,NULL};
    pid_t child;
    if(!r) r=posix_spawn(&child,executable,&actions,&attr,args,environ);
    posix_spawn_file_actions_destroy(&actions);posix_spawnattr_destroy(&attr);
    if(!r) *pid=child;
    return r;
}
#include <sys/file.h>
#include <sys/stat.h>
int exec_lock_agent(const char *directory) {
    char path[4096];
    if(snprintf(path,sizeof(path),"%s/.agent.lock",directory)>=(int)sizeof(path)) return -ENAMETOOLONG;
    int fd=open(path,O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC,0600);
    if(fd<0) return -errno;
    struct stat state;
    if(fstat(fd,&state) || state.st_uid!=getuid() || (state.st_mode&0777)!=0600 || flock(fd,LOCK_EX|LOCK_NB)) { int e=errno?errno:EACCES;close(fd);return -e; }
    return fd;
}
