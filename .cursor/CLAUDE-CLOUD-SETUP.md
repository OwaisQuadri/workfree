# Claude Code (cloud) setup for agent-hooks
- `.claude/settings.json` (committed) holds every guard plus a SessionStart hook (`startup|resume`) that runs
  `.claude/session-start.sh`: `cloud-bootstrap.sh install` then `start`, only when `CLAUDE_CODE_REMOTE=true`.
- Environment variable on the cloud environment (claude.ai/code, environment settings, Environment variables):
  `PI_CONFIG_TOKEN=<read-only fine-grained PAT>`. Not a network secret: the agent proxy never adds secrets to GitHub
  requests. Optional: `PRIVACY_IDENTIFIERS_TEXT` (one private identifier per line); without it the file starts empty.
- Without the token the hook reports "AGENT HOOKS NOT INSTALLED" to you and to Claude, and the guards stay closed.
- Guards fail closed: PreToolUse and UserPromptSubmit entries set `"onFailure": "block"` and end in `|| exit 2`, so until
  `.agent-hooks/` exists every tool call and prompt is blocked. Bootstrap log: `/tmp/agent-hooks-bootstrap.log`.
- One repository per session: Claude cloud does not load repo hooks in multi-repo sessions or project threads.
- No setup script is needed; one would only speed things up (the environment is cached after setup, not after hooks).
- Cursor (local and cloud) imports `.claude/settings.json` as third-party hooks. Every guard entry there starts with `[ -n "$CURSOR_VERSION$CURSOR_PROJECT_DIR" ] && exit 0` so Cursor skips them (it runs the same guards from `.cursor/hooks.json`, which fail open until `.agent-hooks/` exists); otherwise the fail-closed `|| exit 2` UserPromptSubmit guard blocks a Cursor cloud agent's first prompt.
