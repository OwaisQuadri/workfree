#!/bin/zsh
set -euo pipefail
path=("$HOME/.local/bin" /opt/homebrew/bin /usr/local/bin $path)
if [[ "${1:-}" = --help ]]; then
  print 'Usage: wf-herdr-close [--close | --finish | --keep]'
  exit 0
fi
[[ "${HERDR_ENV:-}" = 1 ]] || { print -u2 'Run inside Herdr.'; exit 1; }
wf_bin=${WF_BIN:-wf}
herdr_bin=${HERDR_BIN:-${HERDR_BIN_PATH:-herdr}}
workspace=${HERDR_WORKSPACE_ID:-}
[[ -n "$workspace" ]] || { print -u2 'The current workspace is unavailable.'; exit 1; }
mode=${1:-}
if [[ -z "$mode" ]]; then
  if command -v fzf >/dev/null; then
    mode=$(printf '%s\n' 'Close for now' 'Finish and close' 'Keep' | fzf --prompt='> ' --height=100% --no-sort) || exit 0
    case "$mode" in
      'Close for now') mode=--close ;;
      'Finish and close') mode=--finish ;;
      'Keep') mode=--keep ;;
    esac
  else
    print -u2 'Specify --close, --finish, or --keep.'
    exit 2
  fi
fi
case "$mode" in --close|--finish|--keep) ;; *) print -u2 'Unknown action.'; exit 2 ;; esac
snapshot=$("$herdr_bin" workspace get "$workspace")
id=$(print -rn -- "$snapshot" | jq -er '.result.workspace.tokens.wf_id // "" | strings | select(index("\u0000") == null) | . + "."')
id=${id%.}
owner=$(print -rn -- "$snapshot" | jq -er '.result.workspace.tokens.wf_owner // "" | strings | select(index("\u0000") == null) | . + "."')
owner=${owner%.}
if [[ -z "$id" || -z "$owner" ]]; then
  [[ "$mode" = --close ]] || { print -u2 'This workspace is unmanaged. Use --close; no checkout will be removed.'; exit 1; }
  "$herdr_bin" workspace close "$workspace"
  exit 0
fi
allocation=$("$wf_bin" --json inspect "$id")
repo=$(print -rn -- "$allocation" | jq -er '.repository | strings | select(index("\u0000") == null) | . + "."')
repo=${repo%.}
cd "$repo"
case "$mode" in
  --keep) "$wf_bin" --json keep "$id"; exit 0 ;;
  --finish) "$wf_bin" --json finish "$id" ;;
esac
"$herdr_bin" workspace close "$workspace"
"$wf_bin" --json release "$id" --owner "$owner"
