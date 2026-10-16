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

int process_exec_pinned_image(int image, char *const argv[], char *const envp[], const int *inherited, size_t count);

#endif
