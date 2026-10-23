// SPDX-License-Identifier: GPL-3.0-only
// Own the pinned host process group until the app's exclusive pipe EOF.
// No shell, PID discovery, parent PID polling, user files, or service APIs.
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;
// This additional restriction is inherited across exec. It cannot grant access
// denied by an enclosing sandbox. Upstream's web restart forks then changes the
// child's process group; refusing every fork closes that lifetime escape.
static const char sandbox_program[] = "/usr/bin/sandbox-exec";
static const char sandbox_profile[] = "(version 1)(allow default)(deny process-fork)";
static volatile sig_atomic_t stopping;
static void stop_requested(int signal_number) { (void)signal_number; stopping = 1; }

static void cleanup(void) {
    // The helper is the leader from its first spawn. A child inherits this group
    // at fork, including while posix_spawn is still preparing its exec. Killing
    // the group includes this helper, so EOF still works after abrupt app death.
    // The app holds our PID unreaped before any fallback group signal. This
    // helper never reaps its original child before group cleanup either.
    if (getpgrp() == getpid()) (void)kill(-getpid(), SIGKILL);
    _exit(125);
}

static long long milliseconds(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) cleanup();
    return (long long)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static int valid_host_arguments(int argc, char **argv, int first) {
    if (argc < first + 1 || argc > first + 257 || argv[first][0] != '/') return 0;
    size_t bytes = 0;
    for (int i = first; i < argc; ++i) {
        size_t length = strnlen(argv[i], 16385);
        if (length > 16384 || (bytes += length + 1) > 131072) return 0;
    }
    return 1;
}

static void restricted_environment(char **environment) {
    environment[0] = "PATH=/usr/bin:/bin:/usr/sbin:/sbin";
    environment[1] = "LANG=en_US.UTF-8";
    size_t count = 2;
    const char *allowed[] = {"HOME=", "TMPDIR=", "USER=", "LOGNAME="};
    for (size_t i = 0; i < sizeof(allowed) / sizeof(allowed[0]); ++i) {
        for (char **entry = environ; *entry; ++entry) {
            if (strncmp(*entry, allowed[i], strlen(allowed[i])) == 0) {
                environment[count++] = *entry;
                break;
            }
        }
    }
    environment[count] = NULL;
}

static int exec_host(int argc, char **argv) {
    if (argc < 4 || strcmp(argv[2], "--") != 0 || !valid_host_arguments(argc, argv, 3)) return 126;
    // Refuse to execute the host if sandbox-exec was unavailable, rejected the
    // profile, or did not actually install the restriction. An unexpected probe
    // child never executes host code and is reaped before this process refuses.
    errno = 0;
    pid_t probe = fork();
    int failure = errno;
    if (probe == 0) _exit(126);
    if (probe > 0) {
        (void)kill(probe, SIGKILL);
        while (waitpid(probe, NULL, 0) < 0 && errno == EINTR) {}
        return 126;
    }
    if (failure != EPERM) return 126;
    char *environment[7];
    restricted_environment(environment);
    // No fork, spawn, shell or PID change between the verified restriction and
    // the exact, already validated target executable.
    execve(argv[3], &argv[3], environment);
    return 126;
}

int main(int argc, char **argv) {
    if (argc >= 2 && strcmp(argv[1], "--exec-host") == 0) return exec_host(argc, argv);
    if (getpgrp() != getpid()) return 2;
    // fd 3 has exactly one reader (us) and one writer (the app). Any data is a
    // protocol error: stop uses an owned-group TERM, force/deinit uses EOF.
    struct stat input;
    int flags = fcntl(3, F_GETFL);
    if (fstat(3, &input) != 0 || !S_ISFIFO(input.st_mode) || flags < 0 ||
        (flags & O_ACCMODE) != O_RDONLY || fcntl(3, F_SETFD, FD_CLOEXEC) != 0 ||
        fcntl(3, F_SETFL, flags | O_NONBLOCK) != 0) cleanup();
    if (argc < 3 || strcmp(argv[1], "--") != 0 || !valid_host_arguments(argc, argv, 2)) cleanup();
    char byte;
    if (read(3, &byte, 1) != -1 || errno != EAGAIN) cleanup();
    struct sigaction action = {0};
    action.sa_handler = stop_requested;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGTERM, &action, NULL) != 0) cleanup();

    posix_spawnattr_t attributes;
    if (posix_spawnattr_init(&attributes) != 0) cleanup();
    posix_spawn_file_actions_t files;
    if (posix_spawn_file_actions_init(&files) != 0 ||
        posix_spawn_file_actions_addopen(&files, STDIN_FILENO, "/dev/null", O_RDONLY, 0) != 0 ||
        posix_spawn_file_actions_addopen(&files, STDOUT_FILENO, "/dev/null", O_WRONLY, 0) != 0 ||
        posix_spawn_file_actions_addopen(&files, STDERR_FILENO, "/dev/null", O_WRONLY, 0) != 0) cleanup();
    sigset_t defaults, mask;
    sigemptyset(&defaults); sigemptyset(&mask);
    sigaddset(&defaults, SIGTERM); sigaddset(&defaults, SIGINT);
    sigaddset(&defaults, SIGHUP); sigaddset(&defaults, SIGQUIT);
    sigaddset(&defaults, SIGPIPE); sigaddset(&defaults, SIGCHLD);
    if (posix_spawnattr_setsigdefault(&attributes, &defaults) != 0 ||
        posix_spawnattr_setsigmask(&attributes, &mask) != 0 ||
        posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK |
                                POSIX_SPAWN_CLOEXEC_DEFAULT) != 0) cleanup();
    // Restrict the exec environment again at this boundary, even if the helper
    // were invoked outside the app. No loader/interpreter injection variables.
    char *environment[7];
    restricted_environment(environment);
    char self[PATH_MAX], resolved[PATH_MAX];
    uint32_t capacity = sizeof(self);
    if (_NSGetExecutablePath(self, &capacity) != 0 || realpath(self, resolved) == NULL || resolved[0] != '/') cleanup();
    char *sandbox_arguments[266] = {(char *)sandbox_program, "-p", (char *)sandbox_profile, resolved, "--exec-host", "--"};
    for (int i = 2; i < argc; ++i) sandbox_arguments[i + 4] = argv[i];
    sandbox_arguments[argc + 4] = NULL;
    pid_t child = 0;
    if (posix_spawn(&child, sandbox_program, &files, &attributes, sandbox_arguments, environment) != 0 || child <= 0) cleanup();
    posix_spawn_file_actions_destroy(&files);
    posix_spawnattr_destroy(&attributes);
    long long deadline = 0;
    for (;;) {
        siginfo_t info = {0};
        int result;
        do { result = waitid(P_PID, (id_t)child, &info, WEXITED | WNOHANG | WNOWAIT); } while (result < 0 && errno == EINTR);
        if (result < 0 || info.si_pid == child) cleanup();
        if (stopping && deadline == 0) deadline = milliseconds() + 3000;
        if (deadline && milliseconds() >= deadline) cleanup();
        struct pollfd lifetime = {.fd = 3, .events = POLLIN | POLLHUP};
        result = poll(&lifetime, 1, 25);
        if (result < 0 && errno == EINTR) continue;
        if (result < 0 || (result > 0 && lifetime.revents)) cleanup();
    }
}
