#ifndef PROCESS_IDENTITY_H
#define PROCESS_IDENTITY_H
#include <stddef.h>
int process_birth_identity(int pid, char *output, size_t capacity);

/* Linux: the caller becomes non-dumpable; 0 or errno. Darwin: 0, a no-op. */
int process_deny_inspection(void);
/* Linux: 1 when the caller is dumpable, 0 when not, negative errno on failure. Darwin: 1. */
int process_is_dumpable(void);



#endif
