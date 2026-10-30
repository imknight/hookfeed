# Cursor payload fixtures

Constructed from the common input and `stop` schemas in https://cursor.com/docs/hooks, checked 2026-10-27. These are documentation-derived fixtures, not captured real sessions. `cursor_version: docs-fixture` is a label, not a tested Cursor release. Hooks configuration version: 1. The docs are rolling and do not pin an application version.

`stop` supplies status and loop_count, not response text. No permission-wait notification is documented: beforeShellExecution/beforeMCPExecution are policy hooks for every execution, not evidence that input is needed. Aborted is informational, error is failed, and none of these statuses means needs-input.
