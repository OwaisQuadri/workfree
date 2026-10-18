#!/bin/zsh
set -euo pipefail
path=("$HOME/.local/bin" /opt/homebrew/bin /usr/local/bin $path)
[[ "${HERDR_PLUGIN_EVENT:-}" = workspace.closed ]] || exit 0
payload=${HERDR_PLUGIN_EVENT_JSON:-}
[[ -n "$payload" ]] || { print -u2 'The close event has no payload.'; exit 1; }
id=$(print -rn -- "$payload" | jq -er '.data.workspace.tokens.wf_id // "" | strings | select(index("\u0000") == null) | . + "."')
id=${id%.}
owner=$(print -rn -- "$payload" | jq -er '.data.workspace.tokens.wf_owner // "" | strings | select(index("\u0000") == null) | . + "."')
owner=${owner%.}
[[ -n "$id" && -n "$owner" ]] || exit 0
wf_bin=${WF_BIN:-wf}
allocation=$("$wf_bin" --json inspect "$id")
repo=$(print -rn -- "$allocation" | jq -er '.repository | strings | select(index("\u0000") == null) | . + "."')
repo=${repo%.}
cd "$repo"
"$wf_bin" --json release "$id" --owner "$owner"
