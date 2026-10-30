# Hook payload fixtures

Files ending `.synthetic.json` are handcrafted edge-case fixtures.

`claude-stop-captured.json` and `claude-notification-captured.json` were captured from actual Claude Code 2.1.309 sessions on 23 October 2026. Session/prompt identifiers and local paths were replaced with placeholders. The notification capture came from a real unanswered permission prompt for `/usr/bin/true`. The Stop capture came from a real completed response. These files are replayed by `scripts/test-cli.py`.

`codex-approval-captured.json` and `codex-stop-captured.json` were emitted by Codex 0.164.0 on 26 October 2026 in an isolated app-server session. A deterministic local Responses server supplied an `exec_command` call requesting escalation for `printf hookfeed-approval-capture`. Codex ran the PermissionRequest capture hook, emitted `item/commandExecution/requestApproval`, received `decline`, and later emitted Stop. The command was not executed. The model response was controlled test input; these hook payloads came from Codex, not a handwritten hook fixture.

Only the temporary CODEX_HOME capture definitions were trusted (their hashes were written to its hooks.state configuration). No real ~/.codex files or credentials were used. UUIDs, transcript path and cwd are redacted; tool input and event fields are unchanged. The actual capture session_id equalled the thread/start result's thread.id, confirming the Stop session identifier mapping. Replay tests verify attention, Stop in the same thread, retry deduplication, distinct request content and malformed/unknown events. This is not a real model-driven TUI or menu-bar acceptance test.
