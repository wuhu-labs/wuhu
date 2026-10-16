#ifndef PROCESS_IDENTITY_H
#define PROCESS_IDENTITY_H
#include <stddef.h>
int process_birth_identity(int pid, char *output, size_t capacity);
int process_matches_worker(int pid, const char *executable);
int process_open_handle(int pid);
int process_signal_handle(int handle, int signal);
int process_handle_exited(int handle);
/* 1 = matching CLI machine agent, 0 = none, negative errno = inventory unavailable. */
int process_has_machine_agent(unsigned int uid);

/* Linux: the caller becomes non-dumpable; 0 or errno. Darwin: 0, a no-op. */
int process_deny_inspection(void);
/* Linux: 1 when the caller is dumpable, 0 when not, negative errno on failure. Darwin: 1. */
int process_is_dumpable(void);

int process_exec_pinned_image(int image, char *const argv[], char *const envp[], const int *inherited, size_t count);

int process_watch_child(int pid);
int process_child_exited(int handle);
int process_spawn_worker(const char *image, char *const argv[], int lease, int *pid, int *input);

#endif
