#!/bin/zsh
set -euo pipefail
path=("$HOME/.local/bin" /opt/homebrew/bin /usr/local/bin $path)
if [[ "${1:-}" = --help ]]; then
  print 'Usage: wf-herdr-open BRANCH [--repo PATH] [--base REF] [--path PATH] [--allow-cleanup] [--require-cow]'
  exit 0
fi
[[ "${HERDR_ENV:-}" = 1 ]] || { print -u2 'Run inside Herdr.'; exit 1; }
[[ $# -gt 0 ]] || { print -u2 'Specify a branch.'; exit 1; }
wf_bin=${WF_BIN:-wf}
herdr_bin=${HERDR_BIN:-${HERDR_BIN_PATH:-herdr}}
branch=$1
shift
repo=$PWD
start_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) [[ $# -ge 2 ]] || exit 2; repo=$2; shift 2 ;;
    --base|--path) [[ $# -ge 2 ]] || exit 2; start_args+=("$1" "$2"); shift 2 ;;
    --allow-cleanup|--require-cow) start_args+=("$1"); shift ;;
    *) print -u2 "Unknown option: $1"; exit 2 ;;
  esac
done
allocation=$("$wf_bin" --json start "$branch" --repo "$repo" "${start_args[@]}")
id=$(print -rn -- "$allocation" | jq -er '.id')
checkout=$(print -rn -- "$allocation" | jq -er '.path')
primary=$(print -rn -- "$allocation" | jq -er '.repository')
owner="herdr-opening:$id"
"$wf_bin" --json retain "$id" --owner "$owner" --kind workspace --label 'Herdr workspace' >/dev/null
opened=$("$herdr_bin" worktree open --cwd "$primary" --path "$checkout" --label "$branch" --focus)
workspace=$(print -rn -- "$opened" | jq -er '.result.workspace.workspace_id')
"$herdr_bin" workspace report-metadata "$workspace" --source wf --token "wf_id=$id" --token "wf_owner=$owner" >/dev/null
"$wf_bin" --json inspect "$id"
