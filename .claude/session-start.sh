#!/bin/bash
# Claude Code SessionStart (startup|resume): install the agent hooks into .agent-hooks and the checkers they call.
# The guards in .claude/settings.json deny every tool call until this succeeds. A missing PI_CONFIG_TOKEN stops here,
# loudly, for the user (systemMessage) and for Claude (additionalContext). Local sessions keep their own setup.
cd "${CLAUDE_PROJECT_DIR:-.}" || exit 1
[ "$CLAUDE_CODE_REMOTE" = true ] || exit 0
report() {
	node -e 'const m=process.argv[1];console.log(JSON.stringify({systemMessage:m,hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:m}}))' "$1"
	echo "$1" >&2
}
if [ -z "${PI_CONFIG_TOKEN:-}" ]; then
	report "AGENT HOOKS NOT INSTALLED: PI_CONFIG_TOKEN is not set in this cloud environment. Every guarded tool call will be denied. Add PI_CONFIG_TOKEN to the environment's Environment variables at claude.ai/code and start a new session."
	exit 0
fi
log=/tmp/agent-hooks-bootstrap.log
if BUILD_CHECKERS=1 bash .cursor/cloud-bootstrap.sh install >"$log" 2>&1 && BUILD_CHECKERS=1 bash .cursor/cloud-bootstrap.sh start >>"$log" 2>&1; then
	if grep -q 'ERROR' "$log"; then report "Agent hooks installed with errors (see $log): $(grep ERROR "$log" | head -5 | tr '\n' ' ')"; else report "Agent hooks installed ($log)."; fi
else
	report "AGENT HOOKS BOOTSTRAP FAILED (see $log): $(tail -5 "$log" | tr '\n' ' ') Guarded tool calls will be denied."
fi
exit 0
