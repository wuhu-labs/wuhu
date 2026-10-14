#ifndef EXEC_SUPERVISOR_H
#define EXEC_SUPERVISOR_H
#include <stdint.h>
#include <stddef.h>
typedef struct { int pid; int input; int output; int error; } exec_child;
int exec_spawn(char *const argv[], char *const env[], const char *cwd, exec_child *child);
int exec_observe(int pid, int *tag, int *value);
int exec_reap(int pid);
int exec_reap_nonblocking(int pid);
int exec_signal_group(int pid, int signal);
int exec_pending(int fd);
int exec_read(int fd, void *bytes, size_t count);
int exec_write(int fd, const void *bytes, size_t count);
void exec_close(int fd);
int exec_launch_supervisor(const char *executable, const char *directory, int *pid);
int exec_lock_agent(const char *directory);
#endif
