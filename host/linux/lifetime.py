# SPDX-License-Identifier: GPL-3.0-only
"""Own one process group until the GUI's exclusive lifetime pipe closes.

The GUI retains the writer across short-lived worker threads. Neither the engine
nor any exec'd descendant inherits it. No PID lookup or parent-death signal is
used: those bind to a creator thread and can fail on capability-bearing exec.
"""
import os
import select
import signal
import subprocess
import sys


def supervise(reader, argv):
    os.set_inheritable(reader, False)
    # Catch rather than ignore TERM: exec resets a caught disposition for the engine.
    signal.signal(signal.SIGTERM, lambda *_: None)
    try:
        if select.select([reader], [], [], 0)[0] and not os.read(reader, 1):
            return 1
        child = subprocess.Popen(argv, close_fds=True, stdin=subprocess.DEVNULL,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        while True:
            if select.select([reader], [], [], 0.1)[0] and not os.read(reader, 1):
                break
            if child.poll() is not None:
                break
    finally:
        # We are the session/group leader. The GUI keeps this PID unreaped until
        # its own stop completes; group members cannot outlive the lifetime pipe.
        os.killpg(os.getpgrp(), signal.SIGKILL)
    return 1


if __name__ == '__main__':
    supervise(int(sys.argv[1]), sys.argv[2:])
