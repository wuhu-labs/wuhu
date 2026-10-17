# CProcessIdentity

`process_birth_identity(pid, output, capacity)` writes a NUL-terminated OS birth identity and returns zero, or returns a nonzero errno-style failure. The buffer must contain at least 128 bytes. The identity combines Linux's boot UUID and `/proc/<pid>/stat` start ticks, or macOS's boot-session UUID and `PROC_PIDTBSDINFO` start seconds/microseconds. Linux process names containing spaces or parentheses do not change field parsing. Invalid or inaccessible PIDs fail closed. This is a probe, not authentication: image-retention callers use it to distinguish the original process from a reused PID.






`process_deny_inspection()` sets Linux `PR_SET_DUMPABLE` to 0 and returns zero or errno: other processes of the same user, the caller's own children included, can no longer read its `/proc/<pid>/environ` or memory or ptrace it, and `execve` restores dumpability for whatever the caller runs. `process_is_dumpable()` reads the flag back as 1 or 0, or negative errno. On Darwin the first is a no-op returning zero and the second returns 1.
