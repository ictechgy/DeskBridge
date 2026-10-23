#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Actual MacHostChild + native helper, fresh inert /tmp processes only. No app UI/host."""
from pathlib import Path
import argparse, errno, fcntl, hashlib, json, os, signal, subprocess, tempfile, time

ROOT = Path(__file__).resolve().parents[2]

FIXTURE = r'''
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
extern char **environ;
static volatile sig_atomic_t stopped;
static pid_t replacement;
static void term(int n) { (void)n; stopped = 1; }
static void forward(int n) { if (replacement > 0) kill(replacement, n); }
static void *worker(void *value) { return value; }
static void marker(const char *base, const char *suffix, long value) {
    char path[4096]; if (snprintf(path, sizeof(path), "%s.%s", base, suffix) >= (int)sizeof(path)) _exit(80);
    FILE *file = fopen(path, "wx"); if (!file) _exit(81);
    fprintf(file, "%ld\n", value); fclose(file);
}
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    if (strcmp(argv[1], "companion") == 0) {
        marker(argv[2], "companion", getpid()); for (;;) pause();
    }
    if (strcmp(argv[1], "replacement") == 0) {
        marker(argv[2], "descendant", getpid()); for (;;) pause();
    }
    marker(argv[2], "leader", getpid());
    int inherited = 0;
    for (int fd = 3; fd < 256; ++fd) if (fcntl(fd, F_GETFD) >= 0) ++inherited;
    marker(argv[2], "inherited-fds", inherited);
    pthread_t thread;
    int thread_result = pthread_create(&thread, NULL, worker, NULL);
    if (!thread_result) thread_result = pthread_join(thread, NULL);
    marker(argv[2], "pthread-result", thread_result);
    if (strcmp(argv[1], "restart") == 0) {
        // Exact pinned Sunshine restart topology: original stays alive,
        // forwards TERM/INT/HUP, waits; fork child escapes the group then execs.
        replacement = fork();
        if (replacement < 0) { int error = errno; marker(argv[2], "restart-denied", error); return error == EPERM ? 0 : 3; }
        if (!replacement) {
            if (setpgid(0, 0) != 0) _exit(4);
            char *values[] = {argv[0], "replacement", argv[2], NULL};
            execv(argv[0], values); _exit(5);
        }
        signal(SIGTERM, forward); signal(SIGINT, forward); signal(SIGHUP, forward);
        while (waitpid(replacement, NULL, 0) < 0 && errno == EINTR) {}
        return 0;
    }
    if (strcmp(argv[1], "primitives") == 0) {
        errno = 0;
        pid_t child = fork(); int error = errno;
        if (!child) _exit(0);
        if (child > 0) while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
        marker(argv[2], "fork-denied", child == -1 && error == EPERM);
        errno = 0;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        child = vfork(); error = errno;
#pragma clang diagnostic pop
        if (!child) _exit(0);
        if (child > 0) while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
        marker(argv[2], "vfork-denied", child == -1 && error == EPERM);
        char *values[] = {"/usr/bin/true", NULL};
        child = 0;
        int result = posix_spawn(&child, values[0], NULL, NULL, values, environ);
        if (!result) while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
        marker(argv[2], "spawn-denied", result == EPERM && child == 0);
    }
    if (strcmp(argv[1], "ignore") == 0) signal(SIGTERM, SIG_IGN);
    else signal(SIGTERM, term);
    marker(argv[2], "ready", getpid());
    if (strcmp(argv[1], "crash-supervisor") == 0) {
        usleep(20000); kill(getppid(), SIGKILL);
    }
    while (!stopped) pause();
    marker(argv[2], "term", getpid()); return 0;
}
'''

HARNESS = r'''
import Darwin
import Foundation
enum MacHostPolicy { enum Failure: Error { case exited, helperUnavailable } }
@MainActor enum MacHostRuntime { static var supervisorExecutable: URL { URL(fileURLWithPath: "/unused-synthetic-default") } }
@main struct Check {
 @MainActor static func main() async throws {
    let values = CommandLine.arguments
    let supervisor = URL(fileURLWithPath: values[1])
    let fixture = URL(fileURLWithPath: values[2])
    let mode = values[3]; let base = values[4]
    func exists(_ suffix: String) -> Bool { FileManager.default.fileExists(atPath: base + "." + suffix) }
    func settle(_ child: MacHostChild) async throws {
        for _ in 0..<2500 { if !child.running { return }; try await Task.sleep(for: .milliseconds(2)) }
        child.forceStop(); throw NSError(domain: "Synthetic host did not settle", code: 1)
    }
    if mode == "failure" {
        func descriptors() -> Int { (0..<4096).filter { fcntl(Int32($0), F_GETFD) >= 0 }.count }
        let before = descriptors()
        for _ in 0..<64 {
            do {
                _ = try MacHostChild(executable: fixture, arguments: [], supervisor: supervisor.appendingPathComponent("absent"))
                throw NSError(domain: "Spawn failure accepted", code: 1)
            } catch MacHostPolicy.Failure.helperUnavailable {}
        }
        for arguments in [[String(repeating: "x", count: 16_385)], ["embedded\0nul"], Array(repeating: "x", count: 257)] {
            do {
                _ = try MacHostChild(executable: fixture, arguments: arguments, supervisor: supervisor)
                throw NSError(domain: "Unbounded argv accepted", code: 1)
            } catch MacHostPolicy.Failure.helperUnavailable {}
        }
        guard descriptors() == before else { throw NSError(domain: "Failed spawn leaked lifetime pipe", code: 1) }
        return
    }
    let fixtureMode = ["normal": "graceful", "bounded": "ignore", "force": "ignore", "restart": "restart", "race": "restart", "primitives": "primitives", "helper-crash": "crash-supervisor"][mode] ?? "linger"
    var owned: MacHostChild? = try MacHostChild(executable: fixture, arguments: [fixtureMode, base], supervisor: supervisor)
    for _ in 0..<1500 {
        if exists("ready") { break }
        if owned?.running == false && exists("leader") { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    guard exists("leader") else { owned?.forceStop(); throw NSError(domain: "Inert host did not start", code: 1) }
    if mode == "writer-leak" {
        let companion = Process(); companion.executableURL = fixture; companion.arguments = ["companion", base]
        companion.standardInput = FileHandle.nullDevice; companion.standardOutput = FileHandle.nullDevice; companion.standardError = FileHandle.nullDevice
        try companion.run()
        for _ in 0..<1000 { if exists("companion") { break }; try await Task.sleep(for: .milliseconds(2)) }
        guard exists("companion") else { throw NSError(domain: "Inert companion did not start", code: 1) }
        withExtendedLifetime((owned, companion)) { _exit(0) }
    }
    if mode == "parent-death" { withExtendedLifetime(owned) { _exit(0) } }
    if mode == "release" {
        owned = nil
        try await Task.sleep(for: .milliseconds(300))
        return
    }
    guard let child = owned else { fatalError("synthetic ownership") }
    if mode == "normal" || mode == "bounded" || mode == "primitives" { child.stop() }
    if mode == "force" { child.forceStop() }
    try await settle(child)
    // Queued/repeated stop operations after exit cannot signal a reused group.
    child.stop(); child.forceStop(); child.stop()
 }
}
'''


def run(argv, **kwargs):
    result = subprocess.run([str(a) for a in argv], capture_output=True, timeout=90, **kwargs)
    if result.returncode:
        raise RuntimeError(f"Synthetic command failed ({result.returncode}): {argv}\n" + result.stderr.decode(errors="replace")[-8000:])
    return result


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    # Orphaned synthetic zombies can briefly await launchd. Inspect only this
    # known fixture PID, never enumerate the machine's processes or user data.
    state = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "stat="], capture_output=True, text=True).stdout.strip()
    return bool(state) and not state.startswith("Z")


def gone(pid):
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        if not alive(pid):
            return
        time.sleep(.01)
    raise AssertionError(f"Owned synthetic PID {pid} outlived cleanup")


def check(supervisor):
    checks = 0
    known = set()
    with tempfile.TemporaryDirectory(prefix="knot-mac-host-lifetime-") as temporary:
        root = Path(temporary)
        try:
            source = root / "inert.c"; source.write_text(FIXTURE)
            fixture = root / "inert"
            run(["/usr/bin/clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2", source, "-o", fixture])
            # Compile the actual production class, unchanged. The unrelated
            # AppKit/host entry point is omitted; only its error type is stubbed.
            production = (ROOT / "Sources/DeskBridgeApp/MacHostRuntime.swift").read_text()
            production = production.split("@MainActor enum MacHostRuntime {", 1)[0].replace("import DeskBridgeCore\n", "")
            child_source = root / "MacHostChild.swift"; child_source.write_text(production)
            harness = root / "Harness.swift"; harness.write_text(HARNESS)
            parent = root / "synthetic-parent"
            run(["/usr/bin/swiftc", "-parse-as-library", "-swift-version", "6", "-module-cache-path", root / "module-cache", child_source, harness, "-o", parent])
            companion = subprocess.Popen([str(fixture), "companion", str(root / "unrelated")], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            known.add(companion.pid)
            for mode in ["parent-death", "writer-leak", "normal", "bounded", "force", "release", "restart", "primitives", "helper-crash", *(["race"] * 24), "failure"]:
                base = root / (str(checks) + "-" + mode)
                result = run([parent, supervisor, fixture, mode, base])
                assert result.returncode == 0
                if mode != "failure":
                    pids = [int(path.read_text()) for suffix in ("leader", "descendant") if (path := Path(str(base) + "." + suffix)).exists()]
                    assert pids
                    known.update(pids)
                    for pid in pids:
                        gone(pid)
                    assert Path(str(base) + ".inherited-fds").read_text().strip() == "0", "Host inherited a lifetime descriptor"
                    assert Path(str(base) + ".pthread-result").read_text().strip() == "0", "Ordinary host threads failed"
                if mode in ("restart", "race"):
                    assert Path(str(base) + ".restart-denied").read_text().strip() == str(errno.EPERM)
                    assert not Path(str(base) + ".descendant").exists(), "Pinned restart escaped the owned group"
                if mode == "primitives":
                    for primitive in ("fork", "vfork", "spawn"):
                        assert Path(str(base) + "." + primitive + "-denied").read_text().strip() == "1", primitive + " was allowed"
                if mode == "normal":
                    assert Path(str(base) + ".term").exists(), "Graceful stop did not reach child"
                if mode == "writer-leak":
                    unrelated_pid = int(Path(str(base) + ".companion").read_text())
                    known.add(unrelated_pid)
                    assert alive(unrelated_pid), "An unrelated exec was killed or carried the lifetime writer"
                assert companion.poll() is None, "Owned cleanup signalled an unrelated process group"
                checks += 1

            # The child exec mode must refuse when called without the fixed
            # restriction. Its probe child exits without ever executing a host.
            base = root / "unrestricted-child-mode"
            result = subprocess.run([str(supervisor), "--exec-host", "--", str(fixture), "linger", str(base)],
                                    capture_output=True, timeout=5)
            assert result.returncode == 126
            assert not Path(str(base) + ".leader").exists()
            checks += 1

            # Exercise the native parser/spawn boundary directly with a valid
            # exclusive pipe. Its reader must never reach the inert executable.
            # Two fresh source mutations exercise unavailable wrapper / invalid
            # profile branches, with no system file or production binary change.
            unavailable = {}
            supervisor_source = (ROOT / "host/macos/KnotHostSupervisor.c").read_text()
            for name, old, new in (
                    ("wrapper-unavailable", '"/usr/bin/sandbox-exec"', '"/nonexistent-knot-synthetic-sandbox-exec"'),
                    ("profile-rejected", '"(version 1)(allow default)(deny process-fork)"', '"(invalid-knot-synthetic-profile"')):
                assert supervisor_source.count(old) == 1
                source = root / (name + ".c"); source.write_text(supervisor_source.replace(old, new))
                binary = root / name
                run(["/usr/bin/clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2", source, "-o", binary])
                unavailable[name] = binary
            for mode in ("eof-before-spawn", "invalid-data", "invalid-argv", "spawn-failure", *unavailable):
                reader, writer = os.pipe()
                source_fd = fcntl.fcntl(reader, fcntl.F_DUPFD_CLOEXEC, 10)
                os.close(reader)
                helper = unavailable.get(mode, supervisor)
                command = [str(helper), "--", str(fixture), "linger", str(root / mode)]
                if mode == "invalid-argv": command[1] = "bad-protocol"
                if mode == "spawn-failure": command[2] = str(root / "absent-inert")
                if mode == "eof-before-spawn": os.close(writer); writer = -1
                if mode == "invalid-data": os.write(writer, b"invalid")
                actions = [(os.POSIX_SPAWN_DUP2, source_fd, 3), (os.POSIX_SPAWN_CLOSE, source_fd)]
                if writer >= 0: actions.append((os.POSIX_SPAWN_CLOSE, writer))
                process = os.posix_spawn(str(helper), command, {"PATH": "/usr/bin:/bin"}, file_actions=actions, setpgroup=0)
                os.close(source_fd)
                try:
                    deadline = time.monotonic() + 3
                    while time.monotonic() < deadline:
                        reaped, status = os.waitpid(process, os.WNOHANG)
                        if reaped: break
                        time.sleep(.01)
                    else:
                        os.killpg(process, signal.SIGKILL)
                        os.waitpid(process, 0)
                        raise AssertionError("Invalid helper invocation did not fail closed")
                    assert os.WIFSIGNALED(status) and os.WTERMSIG(status) == signal.SIGKILL
                    assert not Path(str(root / mode) + ".leader").exists(), "Invalid helper invocation spawned a host"
                finally:
                    if writer >= 0: os.close(writer)
                checks += 1
        finally:
            for pid in known:
                if alive(pid):
                    try: os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError: pass
            if "companion" in locals(): companion.wait(timeout=3)
    return {"status": "passed", "checks": checks, "actualMacHostChild": True,
            "nativeSupervisor": True, "freshSyntheticOnly": True, "productionHostLaunched": False,
            "appAbruptDeath": True, "gracefulStop": True, "boundedStop": True,
            "restartDescendantCleanup": True, "writerNotInherited": True, "supervisorCrashCleanup": True,
            "testedSupervisorSHA256": hashlib.sha256(supervisor.read_bytes()).hexdigest(),
            "pinnedRestartForkDenied": True, "forkVforkSpawnDenied": True,
            "normalThreadsAndFiles": True, "unrestrictedChildModeRefused": True,
            "wrapperAndProfileUnavailableRefused": True}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--supervisor", required=True, type=Path)
    options = parser.parse_args()
    print(json.dumps(check(options.supervisor.resolve()), sort_keys=True))
