#!/usr/bin/env python3
"""Black-box CLI/hook tests with synthetic fixtures and sanitized real Claude captures.
No user config is changed.

Build: swift build --scratch-path .build-cli --product hookfeed
Run:   python3 scripts/test-cli.py [--binary /absolute/path/to/hookfeed]
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "Tests/HookFeedCLITests/Fixtures"
DEFAULT_BINARY = next((ROOT / p for p in (".build-cli/debug/hookfeed", ".build-cli/out/Products/Debug/hookfeed", ".build/debug/hookfeed", ".build/out/Products/Debug/hookfeed") if (ROOT / p).is_file()), ROOT / ".build-cli/debug/hookfeed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default=os.environ.get("HOOKFEED_CLI", str(DEFAULT_BINARY)))
    binary = str(Path(parser.parse_args().binary).resolve())
    assert Path(binary).is_file(), f"Build hookfeed first: {binary}"
    checks = 0
    with tempfile.TemporaryDirectory(prefix="hookfeed-cli-") as temporary:
        folder = Path(temporary)
        environment = {key: value for key, value in os.environ.items() if key not in {"HOOKFEED_URL", "HOOKFEED_TOKEN", "HOOKFEED_BOT"}} | {"HOME": temporary, "CFFIXED_USER_HOME": temporary, "HOOKFEED_STORE_PATH": str(folder / "inbox.sqlite"), "HOOKFEED_LOG_PATH": str(folder / "hook.log")}

        def invoke(*arguments, status=0, stdin=None, env=None, timeout=10):
            nonlocal checks
            result = subprocess.run([binary, *arguments], input=stdin, capture_output=True, env=env or environment, timeout=timeout)
            assert result.returncode == status, (arguments, result.returncode, result.stderr.decode(errors="replace"))
            checks += 1
            return result

        def rows():
            return json.loads(invoke("list", "--limit", "100", "--json").stdout)

        def count():
            with sqlite3.connect(environment["HOOKFEED_STORE_PATH"]) as database:
                return database.execute("SELECT COUNT(*) FROM messages").fetchone()[0]

        for status, kind in [("completed", "completed"), ("error", "failed"), ("aborted", "info")]:
            payload = (ROOT / "Tests/HookFeedCoreTests/Fixtures" / f"cursor-stop-{status}.json").read_bytes()
            result = invoke("hook", "cursor", stdin=payload)
            assert not result.stdout and not result.stderr
            message = rows()[0]
            assert message["source"] == "cursor" and message["kind"] == kind
            assert message["thread_key"] == "cursor:cursor-conversation-1"
        with sqlite3.connect(environment["HOOKFEED_STORE_PATH"]) as database:
            database.execute("DELETE FROM messages")

        assert b"0.1.0" in invoke("--version").stdout
        assert b"send" in invoke("--help").stdout
        prompts = json.loads((FIXTURES / "setup-prompts.json").read_text())
        for agent in ("hermes", "mcp", "claude-code", "codex", "openclaw", "antigravity", "gemini-cli", "cursor"):
            expected = prompts[agent].replace("/Applications/HookFeed.app/Contents/Helpers/hookfeed", binary)
            assert invoke("prompt", agent).stdout.decode() == expected + "\n"
            rules = invoke("prompt", agent, "--rules-only").stdout.decode()
            assert 'kind "completed"' in rules and "Back up" not in rules
            if agent in ("hermes", "cursor", "openclaw"):
                assert f'Set source to "{agent}".' in rules
            else:
                assert "Set source" not in rules
        assert 'source "hermes"' in invoke("prompt", "hermes").stdout.decode()
        assert b"claude-code, codex, hermes, openclaw, antigravity, gemini-cli, cursor, mcp" in invoke("prompt", "bogus", status=2).stderr
        link = folder / "hookfeed link"
        link.symlink_to(binary)
        linked = subprocess.run([str(link), "prompt", "hermes"], capture_output=True, check=True, env=environment)
        assert linked.stdout == invoke("prompt", "hermes").stdout
        assert rows() == []
        bot_env = environment | {"HOOKFEED_BOT": "EnvBot"}
        invoke("send", "Hi", "--bot", "Charname", "--source", "grokbot", "--project", "A", "--json", env=bot_env)
        assert rows()[0]["bot"] == "Charname"
        assert "● info · grokbot · Charname · A · Hi [" in invoke("list").stdout.decode()
        invoke("send", "Environment bot", env=bot_env)
        assert rows()[0]["bot"] == "EnvBot"
        invoke("send", "No bot", "--bot", "  ", env=bot_env)
        assert rows()[0].get("bot") is None
        invoke("send", "Bad bot", "--bot", "x" * 81, status=2)
        invoke("run", "--", "true", env=environment | {"HOOKFEED_BOT": "Bot"})
        assert rows()[0]["bot"] == "Bot"
        invoke("run", "--bot", "Explicit", "--", "true", env=bot_env)
        assert rows()[0]["bot"] == "Explicit"
        invoke("send", "Café query", "--project", "Query", "--source", "query-source", "--bot", "QueryBot")
        invoke("send", "Newer unrelated", "--project", "Other")
        for filters in [("--project", "Query"), ("--source", "query-source"), ("--bot", "QueryBot"), ("--search", "CAFE"),
                        ("--project", "Query", "--source", "query-source", "--bot", "QueryBot", "--search", "cafe", "--unread")]:
            matches = json.loads(invoke("list", *filters, "--limit", "1", "--json").stdout)
            assert [message["title"] for message in matches] == ["Café query"] and matches[0].get("read_at") is None
        assert json.loads(invoke("list", "--project", "' OR 1=1 --", "--json").stdout) == []
        text = 'First line 🦉\n"quoted"; apostrophe\'s; $(never executed)\nCafe\u0301'
        body_file = folder / "body with spaces.txt"
        body_file.write_text(text)
        flags = ["--source", "script", "--project", "MailScope", "--kind", "needs_attention", "--url", "https://example.com/review", "--workdir", ".", "--thread", "script:session-1", "--session-id", "session-1", "--key", "retry-1", "--json"]
        receipt = json.loads(invoke("send", "  Review 🦉  ", "--body-file", str(body_file), *flags).stdout)
        assert receipt["status"] == "stored" and receipt["duplicate"] is False
        retry = json.loads(invoke("send", "Review 🦉", "--body", text, *flags).stdout)
        assert retry["id"] == receipt["id"] and retry["duplicate"] is True
        invoke("send", "Different", *flags, status=2)
        stored = rows()[0]
        assert stored["title"] == "Review 🦉" and stored["body"] == text.replace("e\u0301", "é")
        assert stored["thread_key"] == "script:session-1" and stored["session_id"] == "session-1"
        assert stored["workdir"] == os.getcwd() and stored["kind"] == "needs_attention"
        assert stored["received_at"].endswith("Z") and stored.get("read_at") is None
        assert json.loads(invoke("list", "--unread", "--json").stdout) == rows()
        assert rows()[0].get("read_at") is None
        for arguments in [
            ["send", ""], ["send", " "], ["send", "x" * 201], ["send", "x", "--source", ""],
            ["send", "x", "--kind", "unknown"], ["send", "x", "--url", "file:///tmp/example"],
            ["send", "x", "--body", "a", "--body-file", "-"],
            ["send", "x", "--body-file", str(folder / "missing")],
            ["list", "--limit", "101"], ["list", "--limit", "0"], ["list", "--limit", "oops"],
            ["send"], ["unknown"], ["run", "--"],
        ]:
            result = invoke(*arguments, status=2)
            assert result.stdout == b"" and result.stderr
        invoke("send", "stdin", "--body-file", "-", "--json", stdin=text.encode())
        invoke("send", "max bytes", "--body-file", "-", stdin=b"x" * 32768)
        invoke("send", "too big", "--body-file", "-", stdin=b"x" * 32769, status=2)
        invoke("send", "invalid UTF8", "--body-file", "-", stdin=b"\xff\xfe", status=2)
        invoke("send", "directory", "--body-file", str(folder), status=2)
        fifo = folder / "body.fifo"
        os.mkfifo(fifo)
        invoke("send", "FIFO", "--body-file", str(fifo), status=2, timeout=2)

        def fixture(name):
            return (FIXTURES / (name + ".synthetic.json")).read_bytes()

        for agent, name in [("claude-code", "claude-stop"), ("codex", "codex-stop")]:
            payload = json.loads(fixture(name)) | {"session_id": "bot-test-" + agent}
            invoke("hook", agent, stdin=json.dumps(payload).encode(), env=bot_env)
            assert rows()[0]["bot"] == "EnvBot"
            payload["session_id"] += "-explicit"
            invoke("hook", agent, "--bot", "HookBot", stdin=json.dumps(payload).encode(), env=bot_env)
            assert rows()[0]["bot"] == "HookBot"
            before = count()
            payload["session_id"] += "-invalid"
            failed = invoke("hook", agent, stdin=json.dumps(payload).encode(), env=environment | {"HOOKFEED_BOT": "x" * 81})
            assert failed.stdout == b"" and b"bot" in failed.stderr and count() == before

        antigravity = json.loads((ROOT / "Tests/HookFeedCoreTests/Fixtures/antigravity-stop-captured.json").read_text())
        result = invoke("hook", "antigravity", stdin=json.dumps(antigravity).encode())
        assert result.stdout == b"" and result.stderr == b""
        delivered = rows()[0]
        assert delivered["title"] == "Antigravity run finished" and delivered["kind"] == "completed"
        assert delivered["thread_key"] == "antigravity:antigravity-captured-session"
        previous = count()
        invoke("hook", "antigravity", stdin=json.dumps(antigravity | {"fullyIdle": False}).encode())
        assert count() == previous
        invoke("hook", "antigravity", stdin=json.dumps(antigravity | {"error": "Acceptance failure", "terminationReason": "error"}).encode())
        assert rows()[0]["kind"] == "failed"

        hook_cases = [
            (["claude-code"], fixture("claude-stop"), "completed", "claude-code:synthetic-claude-session"),
            (["claude-code"], fixture("claude-permission"), "needs_attention", "claude-code:synthetic-claude-session"),
            (["codex"], fixture("codex-stop"), "completed", "codex:synthetic-codex-session"),
            (["codex", fixture("codex-notify").decode()], None, "completed", "codex:synthetic-legacy-session"),
        ]
        for arguments, payload, kind, thread in hook_cases:
            result = invoke("hook", *arguments, stdin=payload)
            assert result.stdout == b"" and result.stderr == b""
            newest = rows()[0]
            assert newest["kind"] == kind and newest["thread_key"] == thread
            assert newest["session_id"] == thread.split(":", 1)[1]
        assert rows()[0]["workdir"] == os.getcwd()  # legacy notify without cwd
        for filename, kind in [("claude-stop-captured.json", "completed"), ("claude-notification-captured.json", "needs_attention")]:
            result = invoke("hook", "claude-code", stdin=(FIXTURES / filename).read_bytes())
            assert result.stdout == b"" and result.stderr == b""
            assert rows()[0]["kind"] == kind
        previous = count()
        invoke("hook", "codex", stdin=fixture("codex-stop"))
        assert count() == previous  # same Codex turn is an idempotent retry
        continued = json.loads(fixture("codex-stop")) | {"stop_hook_active": True, "last_assistant_message": "Continued turn finished."}
        invoke("hook", "codex", stdin=json.dumps(continued).encode())
        assert count() == previous + 1
        assert rows()[0]["body"] == "Continued turn finished."
        invoke("hook", "codex", stdin=json.dumps(continued).encode())
        assert count() == previous + 1  # retry of the continued event is deduplicated too
        previous = count()
        invoke("hook", "claude-code", stdin=fixture("claude-idle"))
        assert count() == previous
        invoke("hook", "claude-code", "--include-idle", "--project", "Override", stdin=fixture("claude-idle"))
        assert rows()[0]["kind"] == "info" and rows()[0]["project"] == "Override"
        for notification_type in ("elicitation_dialog", "agent_needs_input"):
            payload = json.loads(fixture("claude-permission")) | {"notification_type": notification_type}
            invoke("hook", "claude-code", stdin=json.dumps(payload).encode())
            assert rows()[0]["kind"] == "needs_attention"
        long = json.loads(fixture("claude-stop")) | {"last_assistant_message": "🦉" * 20000}
        invoke("hook", "claude-code", stdin=json.dumps(long).encode())
        assert len(rows()[0]["body"].encode()) == 32768 and len(rows()[0]["title"]) == 120
        approval = json.loads((FIXTURES / "codex-approval-captured.json").read_text())
        before = count()
        for _ in range(2):
            result = invoke("hook", "codex", stdin=json.dumps(approval).encode())
            assert result.stdout == b"" and result.stderr == b""
        assert count() == before + 1
        attention = rows()[0]
        assert attention["kind"] == "needs_attention" and attention["source"] == "codex"
        assert attention["title"] == "Approval needed: printf hookfeed-approval-capture"
        assert attention["project"] == "project" and attention["workdir"] == approval["cwd"]
        assert attention["thread_key"] == "codex:" + approval["session_id"]
        assert "Allow the harmless HookFeed approval capture?" in attention["body"]
        invoke("hook", "codex", stdin=(FIXTURES / "codex-stop-captured.json").read_bytes())
        assert rows()[0]["kind"] == "completed" and rows()[0]["thread_key"] == attention["thread_key"]
        assert count() == before + 2
        changed = approval | {"tool_name": "apply_patch", "tool_input": {"command": "different request"}}
        invoke("hook", "codex", stdin=json.dumps(changed).encode())
        assert count() == before + 3
        for update in [{"tool_name": 3}, {"tool_name": ""}, {"tool_input": None}, {"turn_id": None},
                       {"hook_event_name": "Notification"}, {"hook_event_name": "Unknown"}]:
            invalid = invoke("hook", "codex", stdin=json.dumps(approval | update).encode())
            assert invalid.stdout == b"" and invalid.stderr and count() == before + 3

        previous = count()
        for payload in [b"", b"{", b"[]", b"null", b"x" * (1024 * 1024 + 1), b'{"hook_event_name":"Unknown"}', b'{"session_id":3}']:
            result = invoke("hook", "claude-code", stdin=payload)
            assert result.stdout == b"" and result.stderr
        for arguments in [("unknown",), ("codex", "--bad-option"), ("claude-code", "--project"), ("--help",)]:
            result = invoke("hook", *arguments)
            assert result.stdout == b""
        assert count() == previous and (folder / "hook.log").read_text()
        # Open stdin with no EOF: the adapter must give up instead of hanging the agent.
        started = time.monotonic()
        stalled = subprocess.Popen([binary, "hook", "claude-code"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment)
        stalled.wait(timeout=2)
        assert stalled.returncode == 0 and time.monotonic() - started < 0.6
        assert stalled.stdout.read() == b""
        stalled.stdin.close()

        # A brief read transaction must not silently drop a hook. The hook's
        # process watchdog still bounds genuinely blocked storage below 500 ms.
        with sqlite3.connect(environment["HOOKFEED_STORE_PATH"]) as reader:
            reader.execute("BEGIN")
            reader.execute("SELECT COUNT(*) FROM messages").fetchone()
            payload = json.loads(fixture("claude-stop")) | {"last_assistant_message": "Stored after a brief reader."}
            with ThreadPoolExecutor(max_workers=1) as pool:
                pending = pool.submit(invoke, "hook", "claude-code", stdin=json.dumps(payload).encode())
                time.sleep(0.15)
                reader.commit()
                result = pending.result(timeout=2)
            assert result.stdout == b"" and result.stderr == b""
        assert rows()[0]["body"] == "Stored after a brief reader."

        spool = folder / "spool"
        spool.mkdir(mode=0o700, exist_ok=True)
        with sqlite3.connect(environment["HOOKFEED_STORE_PATH"]) as locked:
            locked.execute("BEGIN EXCLUSIVE")
            started = time.monotonic()
            result = invoke("hook", "claude-code", stdin=fixture("claude-stop"))
            assert time.monotonic() - started < 0.45 and result.stdout == b"" and result.stderr == b""
            queued = list(spool.glob("*.json"))
            assert len(queued) == 1
            queued[0].unlink()
            for unwritable in (True, False):
                if unwritable:
                    spool.chmod(0o500)
                else:
                    for index in range(10000):
                        (spool / f"{index}.json").touch()
                log = folder / ("unwritable.log" if unwritable else "full.log")
                try:
                    result = invoke("hook", "claude-code", stdin=fixture("claude-stop"), env=environment | {"HOOKFEED_LOG_PATH": str(log)})
                    assert result.stdout == b"" and len(log.read_text().splitlines()) == 1
                finally:
                    spool.chmod(0o700)
                    for file in spool.glob("*.json"):
                        file.unlink()
            locked.rollback()

        with sqlite3.connect(environment["HOOKFEED_STORE_PATH"]) as locked:
            locked.execute("BEGIN IMMEDIATE")
            for _ in range(2):
                invoke("hook", "claude-code", stdin=fixture("claude-stop"))
            locked.rollback()
        assert invoke("drain").stdout == b"Moved 2 queued updates into the inbox.\n"
        assert invoke("drain").stdout == b"Moved 0 queued updates into the inbox.\n"

        output = invoke("run", "--title", "Wrapped test", "--", sys.executable, "-c", 'import sys; print(sys.stdin.read()); print(sys.argv[1]); print("error output", file=sys.stderr)', "$(not shell)", stdin=b"inherited stdin")
        assert output.stdout == b"inherited stdin\n$(not shell)\n" and output.stderr == b"error output\n"
        assert rows()[0]["source"] == "run" and rows()[0]["title"] == "Wrapped test"
        assert "Exit code: 0" in rows()[0]["body"] and "Duration:" in rows()[0]["body"]
        invoke("run", "--", "/usr/bin/false", status=1)
        assert rows()[0]["kind"] == "failed"
        previous = count()
        invoke("run", "--only-failures", "--", "/usr/bin/true")
        assert count() == previous
        invoke("run", "--only-failures", "--", "/usr/bin/false", status=1)
        assert count() == previous + 1
        blocked = folder / "blocked"
        blocked.write_text("not a directory")
        broken = environment | {"HOOKFEED_STORE_PATH": str(blocked / "inbox.sqlite")}
        assert invoke("send", "broken", status=1, env=broken).stdout == b""
        assert invoke("list", status=1, env=broken).stdout == b""
        for status in [0, 1, 2, 64, 127]:
            result = invoke("run", "--", sys.executable, "-c", f"raise SystemExit({status})", status=status, env=broken)
            assert result.stderr and result.stdout == b""
        invoke("run", "--", "/path/that/does/not/exist", status=127, env=broken)
        nonexecutable = folder / "not-executable"
        nonexecutable.write_text("not executable")
        invoke("run", "--", str(nonexecutable), status=126, env=broken)
        invoke("run", "--", sys.executable, "-c", "import os,signal; os.kill(os.getpid(), signal.SIGTERM)", status=143, env=broken)
        wrapper = subprocess.Popen([binary, "run", "--", sys.executable, "-c", 'import time; print("ready", flush=True); time.sleep(30)'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=broken)
        assert wrapper.stdout.readline() == b"ready\n"
        wrapper.send_signal(signal.SIGTERM)
        wrapper.communicate(timeout=3)
        assert wrapper.returncode == 143
        for agent in ["claude-code", "codex"]:
            started = time.monotonic()
            result = invoke("hook", agent, stdin=fixture("claude-stop" if agent == "claude-code" else "codex-stop"), env=broken)
            assert result.stdout == b"" and result.stderr and time.monotonic() - started < 0.6
        with sqlite3.connect(environment["HOOKFEED_STORE_PATH"]) as lock:
            lock.execute("BEGIN IMMEDIATE")
            started = time.monotonic()
            result = invoke("hook", "claude-code", stdin=fixture("claude-stop"))
            assert result.stdout == b"" and result.stderr == b"" and time.monotonic() - started < 0.6
            assert len(list(spool.glob("*.json"))) == 1
            for file in spool.glob("*.json"):
                file.unlink()
            lock.rollback()

        # Stream the full stderr, but retain only the bounded tail on failure.
        lines = "".join(f"error {n}\n" for n in range(30))
        code = "import sys; sys.stdout.write('stdout stays live\\n'); sys.stderr.write(" + repr(lines) + "); sys.exit(7)"
        result = invoke("run", "--", sys.executable, "-c", code, status=7)
        assert result.stdout == b"stdout stays live\n" and result.stderr == lines.encode()
        recorded = rows()[0]
        assert recorded["origin"] == "hookfeed.run"
        tail = recorded["body"].split("Stderr (last 20 lines, up to 8 KiB):\n", 1)[1].split("\n\nCommand: ", 1)[0]
        assert tail == "\n".join(f"error {n}" for n in range(10, 30))
        invoke("run", "--", sys.executable, "-c", "import sys; sys.stderr.write('🐱' * 10000); sys.exit(8)", status=8)
        assert len(rows()[0]["body"].encode()) <= 32768
        assert "�" not in rows()[0]["body"]
        spoof = json.loads(invoke("send", "spoof", "--source", "run", "--body", "Command: 'false'", "--json").stdout)
        assert "origin" not in next(row for row in rows() if row["id"] == spoof["id"])

        # Independent processes contend on an entirely fresh store, then on one key.
        concurrent = environment | {"HOOKFEED_STORE_PATH": str(folder / "concurrent.sqlite")}
        def send_index(index):
            return json.loads(invoke("send", f"parallel-{index}", "--json", env=concurrent).stdout)
        with ThreadPoolExecutor(max_workers=50) as pool:
            receipts = list(pool.map(send_index, range(50)))
        assert len({receipt["id"] for receipt in receipts}) == 50
        assert len(json.loads(invoke("list", "--limit", "100", "--json", env=concurrent).stdout)) == 50
        def retry_index(_):
            return json.loads(invoke("send", "same", "--key", "shared", "--json", env=concurrent).stdout)
        with ThreadPoolExecutor(max_workers=50) as pool:
            retries = list(pool.map(retry_index, range(50)))
        assert len({receipt["id"] for receipt in retries}) == 1
        assert sum(not receipt["duplicate"] for receipt in retries) == 1
    print(f"CLI/hook checks passed ({checks} subprocess assertions; synthetic fixtures and sanitized real Claude captures).")


if __name__ == "__main__":
    main()
