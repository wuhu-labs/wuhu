#ifndef EXEC_SUPERVISOR_H
#define EXEC_SUPERVISOR_H
#include <stdint.h>
#include <stddef.h>
#include <spawn.h>
typedef struct { int pid; int input; int output; int error; } exec_child;
int exec_disclaim_responsibility_available(void);
int exec_spawn(char *const argv[], char *const env[], const char *cwd, int disclaim_responsibility, exec_child *child);
typedef int (*exec_disclaim_setter)(posix_spawnattr_t *, int);
int exec_spawn_with_disclaimer(char *const argv[], char *const env[], const char *cwd, int disclaim_responsibility, exec_disclaim_setter setter, exec_child *child);
int exec_observe(int pid, int *tag, int *value);
int exec_reap(int pid);
int exec_reap_nonblocking(int pid);
int exec_signal_group(int pid, int signal);
int exec_pending(int fd);
int exec_read(int fd, void *bytes, size_t count);
int exec_write(int fd, const void *bytes, size_t count);
void exec_close(int fd);
int exec_launch_detached(char *const argv[], int *pid);
int exec_launch_supervisor(const char *executable, const char *directory, int *pid);
int exec_lock_agent(const char *directory);
#endif
