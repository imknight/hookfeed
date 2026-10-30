# Gemini CLI capture provenance

`gemini-after-agent-captured.json` and `gemini-permission-captured.json` were emitted by the installed Gemini CLI 0.64.0 during an interactive session on 27 October 2026 (Malaysia time). A local HTTP server supplied deterministic Gemini API responses: a `run_shell_command` call for `printf hookfeed-gemini-permission`, followed by a text response. These are CLI-generated hook payloads, not handwritten payloads. The session ID, cwd and transcript path were redacted consistently; event fields and timestamps are unchanged.

The Notification hook delivered `needs_attention` to an isolated HookFeed inbox while the real CLI permission dialog was waiting. Selecting “Allow once” executed the harmless printf; AfterAgent then delivered `completed` to the same thread. The capture wrapper saved stdin and passed it to the worktree-built `hookfeed hook gemini-cli`. Both hooks used a 1000 ms timeout. No raw captured credentials are included.

These controlled captures do not verify delivery from a Google-backed model session; that remains unverified.
