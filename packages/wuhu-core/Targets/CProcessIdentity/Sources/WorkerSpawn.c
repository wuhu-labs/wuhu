#define _GNU_SOURCE
#include "include/ProcessIdentity.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <unistd.h>
#include <sys/socket.h>

int process_spawn_worker(const char *image, char *const argv[], int lease, int *pid, int *input) {
    int pipes[2];
#ifdef __APPLE__
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, pipes) != 0) return errno;
    if (fcntl(pipes[0], F_SETFD, FD_CLOEXEC) != 0 || fcntl(pipes[1], F_SETFD, FD_CLOEXEC) != 0) {
        int failure = errno; close(pipes[0]); close(pipes[1]); return failure;
    }
#else
    if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, pipes) != 0) return errno;
#endif
    int null = open("/dev/null", O_RDWR | O_CLOEXEC);
    if (null < 0) { int failure = errno; close(pipes[0]); close(pipes[1]); return failure; }
#ifdef __APPLE__
    int enabled = 1;
    if (setsockopt(pipes[1], SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled)) != 0) {
        int failure = errno; close(null); close(pipes[0]); close(pipes[1]); return failure;
    }
#endif
    // Normalize action sources before remapping stdio, including when the parent has closed stdio.
    int child_input = fcntl(pipes[0], F_DUPFD_CLOEXEC, 4);
    int child_null = fcntl(null, F_DUPFD_CLOEXEC, 4);
    int child_lease = lease >= 0 ? fcntl(lease, F_DUPFD_CLOEXEC, 4) : -1;
    if (child_input < 0 || child_null < 0 || (lease >= 0 && child_lease < 0)) {
        int failure = errno;
        if (child_input >= 0) close(child_input);
        if (child_null >= 0) close(child_null);
        if (child_lease >= 0) close(child_lease);
        close(null); close(pipes[0]); close(pipes[1]); return failure;
    }
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    int failure = posix_spawn_file_actions_init(&actions);
    if (failure) goto close_files;
    failure = posix_spawnattr_init(&attributes);
    if (failure) goto destroy_actions;
    sigset_t mask, defaults;
    sigemptyset(&mask);
    sigfillset(&defaults);
    sigdelset(&defaults, SIGKILL);
    sigdelset(&defaults, SIGSTOP);
    short flags = POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETPGROUP;
#ifdef __APPLE__
    flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
    if ((failure = posix_spawnattr_setflags(&attributes, flags)) ||
        (failure = posix_spawnattr_setsigmask(&attributes, &mask)) ||
        (failure = posix_spawnattr_setsigdefault(&attributes, &defaults)) ||
        (failure = posix_spawnattr_setpgroup(&attributes, 0)) ||
        (failure = posix_spawn_file_actions_adddup2(&actions, child_input, 0)) ||
        (failure = posix_spawn_file_actions_adddup2(&actions, child_null, 1)) ||
        (failure = posix_spawn_file_actions_adddup2(&actions, child_null, 2))) goto destroy_attributes;
    if (lease >= 0 && (failure = posix_spawn_file_actions_adddup2(&actions, child_lease, 3))) goto destroy_attributes;
#ifndef __APPLE__
    if ((failure = posix_spawn_file_actions_addclosefrom_np(&actions, lease >= 0 ? 4 : 3))) goto destroy_attributes;
#endif
    char *environment[] = { NULL };
    pid_t child;
    failure = posix_spawn(&child, image, &actions, &attributes, argv, environment);
    if (!failure) { *pid = child; *input = pipes[1]; pipes[1] = -1; }
destroy_attributes:
    posix_spawnattr_destroy(&attributes);
destroy_actions:
    posix_spawn_file_actions_destroy(&actions);
close_files:
    close(child_input); close(child_null); if (child_lease >= 0) close(child_lease);
    close(null); close(pipes[0]); if (pipes[1] >= 0) close(pipes[1]);
    return failure;
}

#ifdef __APPLE__
#include <sys/event.h>
int process_watch_child(int pid) {
    int descriptor = kqueue();
    if (descriptor < 0) return -errno;
    struct kevent event;
    EV_SET(&event, pid, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0, NULL);
    if (fcntl(descriptor, F_SETFD, FD_CLOEXEC) != 0 || kevent(descriptor, &event, 1, NULL, 0, NULL) != 0) {
        int failure = errno; close(descriptor); return -failure;
    }
    return descriptor;
}
int process_child_exited(int handle) {
    struct kevent event;
    struct timespec timeout = { 0, 0 };
    int result = kevent(handle, NULL, 0, &event, 1, &timeout);
    return result < 0 ? -errno : result;
}
#else
int process_watch_child(int pid) { return process_open_handle(pid); }
int process_child_exited(int handle) { return process_handle_exited(handle); }
#endif
