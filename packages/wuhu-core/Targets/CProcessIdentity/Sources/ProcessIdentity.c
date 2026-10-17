#include "include/ProcessIdentity.h"
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#ifdef __APPLE__
#include <libproc.h>
#include <sys/sysctl.h>
#else
#include <fcntl.h>
#include <sys/prctl.h>
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

int process_deny_inspection(void) {
#ifdef __APPLE__
    return 0;
#else
    return prctl(PR_SET_DUMPABLE, 0, 0, 0, 0) == 0 ? 0 : errno;
#endif
}

int process_is_dumpable(void) {
#ifdef __APPLE__
    return 1;
#else
    int dumpable = prctl(PR_GET_DUMPABLE, 0, 0, 0, 0);
    return dumpable < 0 ? -errno : dumpable != 0;
#endif
}
