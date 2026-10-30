#!/usr/bin/env python3
"""PTY regressions for `hookfeed run`; uses only temporary stores and stdlib.

Build: swift build --scratch-path .build-astra-signal --product hookfeed
Run:   python3 scripts/test-run-terminal.py --binary .build-astra-signal/debug/hookfeed

A separate session acts as a small job-control shell. It observes the terminal's
foreground group BEFORE reclaiming it on wrapper exit/stop, so shell cleanup
cannot hide a broken restoration. All waits and fixture lifetimes are bounded.
"""
import argparse
import errno
import fcntl
import json
import os
from pathlib import Path
import re
import select
import shlex
import signal
import subprocess
import sys
import tempfile
import termios
import time


ROOT = Path(__file__).resolve().parents[1]
TIMEOUT = 8


def shell_driver(config):
    """Internal subprocess entry point; stdin/out/err already point at the PTY."""
    control, events = config["control"], config["events"]
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)
    shell_group = os.getpgrp()
    signal.signal(signal.SIGTTOU, signal.SIG_IGN)
    os.tcsetpgrp(0, shell_group)
    attrs = termios.tcgetattr(0)
    attrs[3] |= termios.ISIG | termios.ICANON
    attrs[3] &= ~termios.ECHO
    if config.get("tostop"):
        attrs[3] |= termios.TOSTOP
    termios.tcsetattr(0, termios.TCSANOW, attrs)
    gate_read, gate_write = os.pipe()
    wrapper = os.fork()
    if wrapper == 0:
        os.close(gate_write)
        os.close(control)
        os.close(events)
        os.setpgid(0, 0)
        for number in (signal.SIGTTOU, signal.SIGTTIN, signal.SIGTSTP):
            signal.signal(number, signal.SIG_DFL)
        os.read(gate_read, 1)
        os.close(gate_read)
        os.execve(config["argv"][0], config["argv"], os.environ)
    os.close(gate_read)
    os.setpgid(wrapper, wrapper)
    if not config.get("background"):
        os.tcsetpgrp(0, wrapper)
    os.write(gate_write, b"x")
    os.close(gate_write)

    def emit(event, **values):
        os.write(events, (json.dumps(dict(event=event, **values)) + "\n").encode())

    emit("started", wrapper=wrapper, shell=shell_group)
    groups = {wrapper}
    buffer = b""
    finished = False
    try:
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            foreground = os.tcgetpgrp(0)
            if foreground > 0 and foreground != shell_group:
                groups.add(foreground)
            if not finished:
                found, status = os.waitpid(wrapper, os.WNOHANG | os.WUNTRACED)
                if found:
                    foreground = os.tcgetpgrp(0)
                    if os.WIFSTOPPED(status):
                        emit("stopped", signal=os.WSTOPSIG(status), foreground=foreground)
                    else:
                        finished = True
                        emit("exited", status=os.waitstatus_to_exitcode(status), foreground=foreground)
                    os.tcsetpgrp(0, shell_group)
            readable, _, _ = select.select([control], [], [], 0.01)
            if not readable:
                continue
            chunk = os.read(control, 65536)
            if not chunk:
                break
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                command = json.loads(line)
                action = command["action"]
                if action == "close":
                    return
                if action == "register":
                    groups.add(command["group"])
                elif action in ("fg", "bg"):
                    os.tcsetpgrp(0, wrapper if action == "fg" else shell_group)
                    os.killpg(wrapper, signal.SIGCONT)
                elif action == "signal":
                    target = -wrapper if command.get("group") else wrapper
                    os.kill(target, command["signal"])
    finally:
        # Confine cleanup to this fixture's known groups, including failed cases.
        for group in groups:
            if group != shell_group:
                try:
                    os.killpg(group, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        if not finished:
            os.waitpid(wrapper, 0)


class TerminalJob:
    def __init__(self, argv, environment, *, background=False, tostop=False):
        self.master, slave = os.openpty()
        control_read, self.control = os.pipe()
        self.events_fd, events_write = os.pipe()
        config = dict(argv=argv, control=control_read, events=events_write,
                      background=background, tostop=tostop)
        self.driver = subprocess.Popen(
            [sys.executable, str(Path(__file__).resolve()), "--driver", json.dumps(config)],
            stdin=slave, stdout=slave, stderr=slave, env=environment,
            start_new_session=True, pass_fds=(control_read, events_write))
        for fd in (slave, control_read, events_write):
            os.close(fd)
        self.output = b""
        self.event_buffer = b""
        self.events = []
        self.open_fds = {self.master, self.events_fd}
        started = self.event("started")
        self.wrapper, self.shell = started["wrapper"], started["shell"]

    def send(self, action, **values):
        os.write(self.control, (json.dumps(dict(action=action, **values)) + "\n").encode())

    def pump(self, timeout):
        readable, _, _ = select.select(list(self.open_fds), [], [], timeout)
        for fd in readable:
            try:
                chunk = os.read(fd, 65536)
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                chunk = b""
            if not chunk:
                self.open_fds.discard(fd)
            elif fd == self.master:
                self.output += chunk
            else:
                self.event_buffer += chunk
                while b"\n" in self.event_buffer:
                    line, self.event_buffer = self.event_buffer.split(b"\n", 1)
                    self.events.append(json.loads(line))

    def until(self, predicate):
        deadline = time.monotonic() + TIMEOUT
        while time.monotonic() < deadline:
            value = predicate()
            if value:
                return value
            self.pump(min(0.05, max(0, deadline - time.monotonic())))
        raise AssertionError(f"PTY timeout: events={self.events}; output={self.output!r}")

    def event(self, name):
        def take():
            for index, event in enumerate(self.events):
                if event["event"] == name:
                    return self.events.pop(index)
        return self.until(take)

    def text(self, value):
        return self.until(lambda: value in self.output)

    def ready(self):
        match = self.until(lambda: re.search(rb"READY (\d+) (\d+)\r?\n", self.output))
        pid, group = map(int, match.groups())
        self.send("register", group=group)
        return pid, group

    def input(self, value):
        os.write(self.master, value)

    def exit(self, status, *, foreground=None):
        result = self.event("exited")
        self.pump(0)
        assert result["status"] == status, (result, self.output)
        assert result["foreground"] == (foreground or self.wrapper), (result, self.output)

    def close(self):
        try:
            self.send("close")
        except BrokenPipeError:
            pass
        try:
            self.driver.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.driver.kill()
            self.driver.wait(timeout=3)
        for fd in (self.master, self.control, self.events_fd):
            os.close(fd)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


PRELUDE = """
import os, signal, sys, time
signal.alarm(15)
def ready():
    print('READY', os.getpid(), os.getpgrp(), flush=True)
"""

COUNTER = PRELUDE + """
count = 0
def interrupt(number, frame):
    global count
    count += 1
signal.signal(signal.SIGINT, interrupt)
ready()
while not count:
    time.sleep(0.01)
time.sleep(0.3)  # Leave time for an erroneous second, forwarded SIGINT.
print('INTERRUPTS', count, flush=True)
sys.exit(23)
"""

READER = PRELUDE + """
def continued(number, frame):
    print('CONTINUED', int(os.tcgetpgrp(0) == os.getpgrp()), flush=True)
signal.signal(signal.SIGCONT, continued)
ready()
print('INPUT', sys.stdin.readline().strip(), flush=True)
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default=str(ROOT / ".build-astra-signal/debug/hookfeed"))
    binary = str(Path(parser.parse_args().binary).resolve())
    assert Path(binary).is_file(), f"Build hookfeed first: {binary}"
    cases = 0
    with tempfile.TemporaryDirectory(prefix="hookfeed-terminal-") as temporary:
        folder = Path(temporary)

        def environment(name):
            return os.environ | {"HOOKFEED_STORE_PATH": str(folder / (name + ".sqlite")),
                                 "HOOKFEED_LOG_PATH": str(folder / "hook.log")}

        def wrapped(code, *arguments, flags=()):
            return [binary, "run", *flags, "--", sys.executable, "-c", code, *arguments]

        def stored(env, status, *, count=1):
            result = subprocess.run([binary, "list", "--json"], env=env, capture_output=True,
                                    check=True, timeout=TIMEOUT)
            rows = json.loads(result.stdout)
            assert len(rows) == count, rows
            if count:
                assert rows[0]["source"] == "run", rows
                assert f"Exit code: {status}\n" in rows[0]["body"], rows
                assert rows[0]["kind"] == ("completed" if status == 0 else "failed"), rows

        # Same observable signal count as direct argv, with a real terminal VINTR.
        for delivery in ("direct-command", "terminal", "wrapper-group", "wrapper-only"):
            env = environment(delivery)
            argv = ([sys.executable, "-c", COUNTER] if delivery == "direct-command"
                    else wrapped(COUNTER))
            with TerminalJob(argv, env) as job:
                pid, group = job.ready()
                assert group == job.wrapper
                if delivery == "wrapper-only":
                    # Document the system()-style contract: INT sent only to the
                    # waiting wrapper is ignored. Group INT remains effective.
                    job.send("signal", signal=signal.SIGINT)
                    time.sleep(0.1)
                    job.pump(0)
                    assert b"INTERRUPTS" not in job.output, job.output
                if delivery in ("direct-command", "terminal"):
                    job.input(b"\x03")
                else:
                    job.send("signal", signal=signal.SIGINT, group=True)
                job.exit(23)
                assert b"INTERRUPTS 1\r\n" in job.output, job.output
            if delivery != "direct-command":
                stored(env, 23)
            cases += 1

        for number in (signal.SIGTERM, signal.SIGHUP):
            env = environment(f"signal-{number}")
            with TerminalJob(wrapped(PRELUDE + "ready(); time.sleep(30)"), env) as job:
                job.ready()
                job.send("signal", signal=number)
                job.exit(128 + number)
            stored(env, 128 + number)
            cases += 1

        for number, key in ((signal.SIGINT, b"\x03"), (signal.SIGQUIT, b"\x1c")):
            env = environment(f"terminal-default-{number}")
            with TerminalJob(wrapped(PRELUDE + "ready(); time.sleep(30)"), env) as job:
                job.ready()
                job.input(key)
                job.exit(128 + number)
            stored(env, 128 + number)
            cases += 1

        env = environment("pipeline")
        # Keep the sink alive so we can inspect the interrupted producer's output.
        pipeline = "trap '' INT; " + shlex.join(wrapped(COUNTER)) + " | /bin/cat"
        with TerminalJob(["/bin/bash", "-o", "pipefail", "-c", pipeline], env) as job:
            _, group = job.ready()
            assert group == job.wrapper
            job.input(b"\x03")
            job.exit(23)
            assert b"INTERRUPTS 1\r\n" in job.output, job.output
        stored(env, 23)
        cases += 1

        # Immediate read, literal argv, inherited descriptors, and native TOSTOP.
        literal = "$(must not run); ' spaces 🦉"
        for index in range(5):
            env = environment(f"stdin-{index}")
            code = PRELUDE + """
line = sys.stdin.readline().strip()
assert all(os.isatty(fd) for fd in (0, 1))
assert not os.isatty(2)  # stderr is streamed through the bounded capture pipe.
assert os.tcgetpgrp(0) == os.getpgrp()
assert line == 'interactive input'
print('ARGV', sys.argv[1], flush=True)
print('STDERR inherited', file=sys.stderr, flush=True)
"""
            with TerminalJob(wrapped(code, literal), env, tostop=True) as job:
                job.input(b"interactive input\n")
                job.exit(0)
                assert ("ARGV " + literal).encode() in job.output, job.output
                assert b"STDERR inherited" in job.output, job.output
            stored(env, 0)
            cases += 1

        for code, flags in ((0, ()), (37, ()), (0, ("--only-failures",))):
            env = environment(f"exit-{code}-{bool(flags)}")
            with TerminalJob(wrapped(f"raise SystemExit({code})", flags=flags), env) as job:
                job.exit(code)
            stored(env, code, count=0 if flags else 1)
            cases += 1

        env = environment("spawn-failure")
        with TerminalJob([binary, "run", "--", "/path/that/does/not/exist"], env) as job:
            job.exit(127)
        stored(env, 127)
        cases += 1

        # Native Ctrl-Z/fg must stop the wrapper for its shell, then make the job
        # foreground BEFORE the child's SIGCONT handler. Stops aren't completion.
        for delivery in ("terminal", "wrapper"):
            env = environment(f"stop-{delivery}")
            with TerminalJob(wrapped(READER), env) as job:
                job.ready()
                if delivery == "terminal":
                    job.input(b"\x1a")
                else:
                    job.send("signal", signal=signal.SIGTSTP)
                stop = job.event("stopped")
                assert stop["foreground"] == job.wrapper, (stop, job.output)
                stored(env, 0, count=0)  # Stopping is not command completion.
                job.send("fg")
                job.text(b"CONTINUED 1")
                job.input(b"resumed input\n")
                job.exit(0)
                assert job.output.count(b"CONTINUED") == 1, job.output
                assert b"INPUT resumed input" in job.output, job.output
            stored(env, 0)
            cases += 1

        env = environment("background")
        with TerminalJob(wrapped(READER), env, background=True) as job:
            job.ready()
            stop = job.event("stopped")
            assert stop["foreground"] == job.shell, (stop, job.output)
            job.send("bg")
            job.text(b"CONTINUED 0")
            stop = job.event("stopped")  # Reading in the background stops again.
            assert stop["foreground"] == job.shell, (stop, job.output)
            job.send("fg")
            job.text(b"CONTINUED 1")
            job.input(b"foreground input\n")
            job.exit(0)
            assert b"INPUT foreground input" in job.output, job.output
        stored(env, 0)
        cases += 1

        env = environment("descendant-interrupt")
        code = PRELUDE + """
import subprocess
worker = subprocess.Popen([sys.executable, '-c', '''
import os, signal, sys, time
signal.alarm(15)
def terminate(number, frame):
    print('WORKER INT', flush=True)
    sys.exit(0)
signal.signal(signal.SIGINT, terminate)
print('WORKER READY', flush=True)
while True: time.sleep(0.01)
'''])
def terminate(number, frame):
    print('PARENT INT', flush=True)
    worker.wait(timeout=3)
    sys.exit(130)
signal.signal(signal.SIGINT, terminate)
ready()
while True: time.sleep(0.01)
"""
        with TerminalJob(wrapped(code), env) as job:
            job.ready()
            job.text(b"WORKER READY")
            job.input(b"\x03")
            job.exit(130)
            assert job.output.count(b"PARENT INT") == 1, job.output
            assert job.output.count(b"WORKER INT") == 1, job.output
        stored(env, 130)
        cases += 1

        env = environment("background-survival")
        code = PRELUDE + """
worker = os.fork()
if worker == 0:
    signal.alarm(15)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    print('WORKER PID', os.getpid(), flush=True)
    while True: time.sleep(0.01)
ready()
sys.stdin.readline()
sys.exit(17)
"""
        with TerminalJob(wrapped(code), env) as job:
            job.ready()
            match = job.until(lambda: re.search(rb"WORKER PID (\d+)", job.output))
            worker = int(match[1])
            job.input(b"exit\n")
            job.exit(17)
            time.sleep(0.2)
            result = subprocess.run(["ps", "-o", "stat=", "-p", str(worker)],
                                    capture_output=True, timeout=TIMEOUT)
            assert result.stdout.strip() and not result.stdout.strip().startswith(b"Z"), result.stdout
            # The fixture shell, not hookfeed, kills its own background worker at
            # context exit. Normal wrapper completion must leave it alive.
        stored(env, 17)
        cases += 1

        # Exercise an actual shell '&'/nohup launch as well as the fork above.
        for wrapped_shell in (False, True):
            env = environment(f"nohup-{wrapped_shell}")
            marker = folder / f"nohup-{wrapped_shell}.ready"
            worker_code = "import signal,time; from pathlib import Path; signal.alarm(15); " + \
                f"Path({str(marker)!r}).write_text('ready'); time.sleep(30)"
            background = shlex.join(["/usr/bin/nohup", sys.executable, "-c", worker_code])
            command = background + " </dev/null >/dev/null 2>&1 & echo WORKER PID $!"
            argv = ["/bin/sh", "-c", command]
            if wrapped_shell:
                argv = [binary, "run", "--", *argv]
            with TerminalJob(argv, env) as job:
                job.exit(0)
                match = job.until(lambda: re.search(rb"WORKER PID (\d+)", job.output))
                worker = int(match[1])
                deadline = time.monotonic() + 3
                while not marker.exists():
                    assert time.monotonic() < deadline, (worker, job.output)
                    time.sleep(0.02)
                time.sleep(0.1)
                result = subprocess.run(["ps", "-o", "stat=", "-p", str(worker)],
                                        capture_output=True, timeout=TIMEOUT)
                assert result.stdout.strip() and not result.stdout.strip().startswith(b"Z"), result.stdout
            if wrapped_shell:
                stored(env, 0)
            cases += 1

        # A supervisor's uncatchable kill of the job must still cover the child.
        env = environment("group-kill")
        with TerminalJob(wrapped(PRELUDE + "ready(); time.sleep(30)"), env) as job:
            child, group = job.ready()
            assert group == job.wrapper
            job.send("signal", signal=signal.SIGKILL, group=True)
            job.exit(-signal.SIGKILL)
            deadline = time.monotonic() + 3
            while True:
                result = subprocess.run(["ps", "-o", "stat=", "-p", str(child)],
                                        capture_output=True, timeout=TIMEOUT)
                if not result.stdout.strip() or result.stdout.strip().startswith(b"Z"):
                    break
                assert time.monotonic() < deadline, (child, result.stdout)
                time.sleep(0.02)
        stored(env, 0, count=0)  # SIGKILL cannot record a result.
        cases += 1

        # No controlling terminal, and all three stdio descriptors are pipes.
        for number in (signal.SIGINT, signal.SIGTERM):
            env = environment(f"non-tty-{number}")
            code = COUNTER if number == signal.SIGINT else PRELUDE + "ready(); time.sleep(30)"
            process = subprocess.Popen(wrapped(code), env=env, start_new_session=True,
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                readable, _, _ = select.select([process.stdout], [], [], TIMEOUT)
                assert readable, "non-TTY child did not become ready"
                ready = process.stdout.readline().decode().split()
                assert ready[0] == "READY" and int(ready[2]) == process.pid, ready
                if number == signal.SIGINT:
                    os.killpg(process.pid, number)
                else:
                    process.send_signal(number)
                stdout, stderr = process.communicate(timeout=TIMEOUT)
                status = 23 if number == signal.SIGINT else 128 + number
                assert process.returncode == status, (process.returncode, stdout, stderr)
                if number == signal.SIGINT:
                    assert stdout == b"INTERRUPTS 1\n", stdout
                assert not stderr, stderr
                stored(env, status)
            finally:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.communicate(timeout=3)
            cases += 1
    print(f"Terminal run regressions passed ({cases} cases).")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--driver":
        shell_driver(json.loads(sys.argv[2]))
    else:
        main()
