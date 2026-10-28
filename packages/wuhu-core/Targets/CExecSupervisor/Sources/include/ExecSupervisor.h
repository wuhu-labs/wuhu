#ifndef EXEC_SUPERVISOR_H
#define EXEC_SUPERVISOR_H
#include <stdint.h>
#include <stddef.h>
#include <spawn.h>
typedef struct { int pid; int input; int output; int error; } exec_child;
int exec_disclaim_responsibility_available(void);
int exec_process_birth(int pid, uint64_t *birth);
void exec_run_child(char *const arguments[]);
int exec_spawn_with_receipt(char *const argv[], char *const env[], const char *cwd, int disclaim_responsibility, int receipt, int publication, exec_child *child);
int exec_spawn(char *const argv[], char *const env[], const char *cwd, int disclaim_responsibility, exec_child *child);
typedef int (*exec_disclaim_setter)(posix_spawnattr_t *, int);
int exec_spawn_with_disclaimer(char *const argv[], char *const env[], const char *cwd, int disclaim_responsibility, exec_disclaim_setter setter, exec_child *child);
int exec_observe(int pid, int *tag, int *value);
int exec_reap(int pid);
int exec_reap_nonblocking(int pid);
/// Reaps child `pid` from a detached thread once it exits, whoever else is still around. 0, or the pthread error.
int exec_reap_when_exited(int pid);
int exec_signal_group(int pid, int signal);
int exec_pending(int fd);
int exec_read(int fd, void *bytes, size_t count);
int exec_write(int fd, const void *bytes, size_t count);
void exec_close(int fd);
int exec_launch_detached(char *const argv[], int *pid);
/// Opens `path` (creating it 0600 when `create`) and takes an exclusive flock without waiting; the fd is close-on-exec. Returns the fd or -errno (EWOULDBLOCK while another holds it).
int exec_lock_file(const char *path, int create);
int exec_lock_agent(const char *directory);
/// Connects to the Unix stream socket at `path`, writes `bytes` whole and waits for the first reply bytes or the peer's close, all within `timeout_ms`; the reply is discarded. 0 once written; -errno otherwise (ECONNREFUSED or ENOENT: nothing listens there).
int exec_unix_request(const char *path, const void *bytes, size_t count, int timeout_ms);
#endif
