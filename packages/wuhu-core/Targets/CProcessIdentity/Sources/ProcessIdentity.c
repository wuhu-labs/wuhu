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
#include <poll.h>
#include <pthread.h>
#include <linux/close_range.h>
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

static int machine_arguments(const char *bytes, size_t size) {
    for (size_t i = 0; i < size;) {
        size_t length = strnlen(bytes + i, size - i);
        if (length == size - i) return 0;
        if ((!strcmp(bytes + i, "machine") || !strcmp(bytes + i, "machine-v2")) &&
            i + length + 4 < size && !memcmp(bytes + i + length + 1, "run\0", 4)) return 1;
        i += length + 1;
    }
    return 0;
}

#ifdef __APPLE__
int process_has_machine_agent(unsigned int uid) {
    int count = proc_listallpids(NULL, 0);
    if (count <= 0) return -errno;
    int capacity = count + 1024;
    pid_t *pids = calloc((size_t)capacity, sizeof(pid_t));
    if (!pids) return -ENOMEM;
    count = proc_listallpids(pids, capacity * (int)sizeof(pid_t));
    if (count <= 0 || count >= capacity) { free(pids); return -EAGAIN; }
    int result = 0;
    for (int i = 0; i < count; i++) {
        if (pids[i] <= 0 || pids[i] == getpid()) continue;
        struct proc_bsdinfo info;
        if (proc_pidinfo(pids[i], PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) {
            if (errno == ESRCH || errno == ENOENT) continue;
            result = -(errno ? errno : EIO); break;
        }
        if (info.pbi_uid != uid) continue;
        char args[65536]; size_t size = sizeof(args);
        int mib[] = { CTL_KERN, KERN_PROCARGS2, pids[i] };
        if (sysctl(mib, 3, args, &size, NULL, 0) != 0) {
            if (errno == ESRCH || errno == ENOENT) continue;
            result = -errno; break;
        }
        if (size <= sizeof(int)) { result = -EINVAL; break; }
        int argc; memcpy(&argc, args, sizeof(argc));
        size_t offset = sizeof(int);
        offset += strnlen(args + offset, size - offset);
        while (offset < size && args[offset] == 0) offset++;
        size_t end = offset;
        for (int arg = 0; arg < argc && end < size; arg++) end += strnlen(args + end, size - end) + 1;
        if (end > size) { result = -EINVAL; break; }
        if (machine_arguments(args + offset, end - offset)) { result = 1; break; }
    }
    free(pids); return result;
}
#else
#include <dirent.h>
int process_has_machine_agent(unsigned int uid) {
    DIR *directory = opendir("/proc");
    if (!directory) return -errno;
    int result = 0;
    struct dirent *entry;
    while ((entry = readdir(directory))) {
        char *end; long pid = strtol(entry->d_name, &end, 10);
        if (*end || pid <= 0 || pid == getpid()) continue;
        char path[128], args[65536]; struct stat state;
        snprintf(path, sizeof(path), "/proc/%ld", pid);
        if (stat(path, &state) != 0) { if (errno == ENOENT || errno == ESRCH) continue; result = -errno; break; }
        if (state.st_uid != uid) continue;
        snprintf(path, sizeof(path), "/proc/%ld/cmdline", pid);
        int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
        if (fd < 0) { if (errno == ENOENT || errno == ESRCH) continue; result = -errno; break; }
        ssize_t count;
        do { count = read(fd, args, sizeof(args)); } while (count < 0 && errno == EINTR);
        int failure = errno; close(fd);
        if (count < 0) { if (failure == ENOENT || failure == ESRCH) continue; result = -failure; break; }
        if (count == sizeof(args)) { result = -E2BIG; break; }
        if (count > 0 && machine_arguments(args, (size_t)count)) { result = 1; break; }
    }
    closedir(directory); return result;
}
#endif

#ifdef __APPLE__
int process_exec_pinned_image(int image, char *const argv[], char *const envp[], const int *inherited, size_t count) {
    (void)image; (void)argv; (void)envp; (void)inherited; (void)count;
    return ENOTSUP;
}
#else
struct pinned_exec {
    int image;
    char *const *argv;
    char *const *envp;
    const int *inherited;
    size_t count;
    int failure;
};

static void *exec_private_table(void *raw) {
    struct pinned_exec *request = raw;
    // Linux-only: isolate this exec thread so concurrent NIO opens cannot leak; failure leaves the source table untouched.
    if (syscall(SYS_close_range, 3U, ~0U, CLOSE_RANGE_UNSHARE | CLOSE_RANGE_CLOEXEC) != 0) { request->failure = errno; return NULL; }
    for (size_t i = 0; i < request->count; i++) {
        int descriptor = request->inherited[i];
        if (descriptor <= 2) { request->failure = EINVAL; return NULL; }
        int flags = fcntl(descriptor, F_GETFD);
        if (flags < 0 || fcntl(descriptor, F_SETFD, flags & ~FD_CLOEXEC) != 0) {
            request->failure = errno; return NULL;
        }
    }
    fexecve(request->image, request->argv, request->envp);
    request->failure = errno;
    return NULL;
}

int process_exec_pinned_image(int image, char *const argv[], char *const envp[], const int *inherited, size_t count) {
    struct pinned_exec request = { .image = image, .argv = argv, .envp = envp, .inherited = inherited, .count = count };
    pthread_t thread;
    int failure = pthread_create(&thread, NULL, exec_private_table, &request);
    if (failure) return failure;
    if (pthread_join(thread, NULL) != 0) abort();
    return request.failure;
}
#endif
