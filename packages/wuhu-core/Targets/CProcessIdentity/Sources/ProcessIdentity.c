#include "include/ProcessIdentity.h"
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef __APPLE__
#include <libproc.h>
#include <sys/sysctl.h>
#else
#include <fcntl.h>
#include <unistd.h>
#include <poll.h>
#include <sys/syscall.h>
#include <sys/stat.h>
#endif

#ifndef __APPLE__
static int read_bounded(const char *path, char *output, size_t capacity) {
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return errno;
    ssize_t count;
    do { count = read(fd, output, capacity - 1); } while (count < 0 && errno == EINTR);
    int failure = count < 0 ? errno : count == 0 || (size_t)count == capacity - 1 ? EINVAL : 0;
    close(fd);
    if (!failure) output[count] = 0;
    return failure;
}
#endif

int process_matches_worker(int pid, const char *executable) {
#ifdef __APPLE__
    (void)pid; (void)executable;
    return -ENOTSUP;
#else
    if (pid <= 0 || pid == getpid() || !executable) return 0;
    char path[64], command[4096] = {0};
    struct stat process, actual, expected;
    snprintf(path, sizeof(path), "/proc/%d", pid);
    if (stat(path, &process) != 0) return -errno;
    if (process.st_uid != geteuid()) return 0;
    snprintf(path, sizeof(path), "/proc/%d/exe", pid);
    if (stat(path, &actual) != 0 || stat(executable, &expected) != 0) return -errno;
    if (actual.st_dev != expected.st_dev || actual.st_ino != expected.st_ino) return 0;
    snprintf(path, sizeof(path), "/proc/%d/cmdline", pid);
    int failure = read_bounded(path, command, sizeof(command));
    if (failure) return -failure;
    size_t argument = strlen(command) + 1;
    return argument < sizeof(command) && strcmp(command + argument, "_execution-worker") == 0;
#endif
}

int process_open_handle(int pid) {
#ifdef __APPLE__
    (void)pid;
    return -ENOTSUP;
#else
    if (pid <= 0 || pid == getpid()) return -EINVAL;
    int handle = (int)syscall(SYS_pidfd_open, pid, 0);
    return handle < 0 ? -errno : handle;
#endif
}

int process_signal_handle(int handle, int signal) {
#ifdef __APPLE__
    (void)handle; (void)signal;
    return ENOTSUP;
#else
    return syscall(SYS_pidfd_send_signal, handle, signal, NULL, 0) == 0 ? 0 : errno;
#endif
}

int process_handle_exited(int handle) {
#ifdef __APPLE__
    (void)handle;
    return -ENOTSUP;
#else
    struct pollfd descriptor = { .fd = handle, .events = POLLIN };
    int ready = poll(&descriptor, 1, 0);
    if (ready < 0) return -errno;
    return ready > 0 && (descriptor.revents & POLLIN) ? 1 : 0;
#endif
}

int process_birth_identity(int pid, char *output, size_t capacity) {
    if (pid <= 0 || capacity < 128) return EINVAL;
    char boot[128] = {0};
    int count;
#ifdef __APPLE__
    struct proc_bsdinfo info;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return ESRCH;
    size_t size = sizeof(boot);
    if (sysctlbyname("kern.bootsessionuuid", boot, &size, NULL, 0) != 0) return errno;
    boot[sizeof(boot) - 1] = 0;
    count = snprintf(output, capacity, "darwin:%s:%llu:%llu", boot, (unsigned long long)info.pbi_start_tvsec, (unsigned long long)info.pbi_start_tvusec);
#else
    char path[64], state[4096];
    snprintf(path, sizeof(path), "/proc/%d/stat", pid);
    int failure = read_bounded(path, state, sizeof(state));
    if (failure) return failure;
    failure = read_bounded("/proc/sys/kernel/random/boot_id", boot, sizeof(boot));
    if (failure) return failure;
    boot[strcspn(boot, "\r\n")] = 0;
    char *cursor = strrchr(state, ')');
    if (!cursor || cursor[1] != ' ') return EINVAL;
    cursor += 2;
    for (int field = 3; field < 22; ++field) {
        cursor = strchr(cursor, ' ');
        if (!cursor) return EINVAL;
        ++cursor;
    }
    char *end;
    errno = 0;
    unsigned long long ticks = strtoull(cursor, &end, 10);
    if (errno || end == cursor || *end != ' ' || ticks == 0) return EINVAL;
    count = snprintf(output, capacity, "linux:%s:%llu", boot, ticks);
#endif
    return count < 0 || (size_t)count >= capacity ? EOVERFLOW : 0;
}
