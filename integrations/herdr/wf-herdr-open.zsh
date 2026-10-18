#!/bin/zsh
set -euo pipefail
path=("$HOME/.local/bin" /opt/homebrew/bin /usr/local/bin $path)
if [[ "${1:-}" = --help ]]; then
  print 'Usage: wf-herdr-open BRANCH [--repo PATH] [--base REF] [--path PATH] [--allow-cleanup] [--require-cow]
       wf-herdr-open --allocation ID'
  exit 0
fi
[[ "${HERDR_ENV:-}" = 1 ]] || { print -u2 'Run inside Herdr.'; exit 1; }
[[ $# -gt 0 ]] || { print -u2 'Specify a branch or --allocation ID.'; exit 1; }
wf_bin=${WF_BIN:-wf}
herdr_bin=${HERDR_BIN:-${HERDR_BIN_PATH:-herdr}}
is_existing=0
if [[ "$1" = --allocation ]]; then
  is_existing=1
  [[ $# = 2 && -n "$2" ]] || { print -u2 'Use --allocation ID without create options.'; exit 2; }
  allocation=$("$wf_bin" --json inspect "$2")
else
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
fi
id=$(print -rn -- "$allocation" | jq -er '.id')
checkout=$(print -rn -- "$allocation" | jq -er '.path')
primary=$(print -rn -- "$allocation" | jq -er '.repository')
provisional="herdr-opening:$(/usr/bin/uuidgen)"
"$wf_bin" --json retain "$id" --owner "$provisional" --kind workspace --label 'Herdr workspace' >/dev/null
if [[ "$is_existing" = 1 ]]; then
  if branch=$(git -C "$checkout" symbolic-ref --quiet --short HEAD); then
    :
  else
    revision=$(git -C "$checkout" rev-parse --short HEAD)
    branch="detached:$revision"
  fi
fi
opened=$("$herdr_bin" worktree open --cwd "$primary" --path "$checkout" --label "$branch" --focus)
workspace=$(print -rn -- "$opened" | jq -er '.result.workspace.workspace_id | strings | select(length > 0)')
snapshot=$("$herdr_bin" workspace get "$workspace")
tokens=$(print -rn -- "$snapshot" | jq -ce '.result.workspace | objects | (if .tokens == null then {} else .tokens end) | objects | select((.wf_id | . == null or type == "string") and (.wf_owner | . == null or type == "string"))')
metadata_id=$(print -rn -- "$tokens" | jq -r '.wf_id // "" | strings')
metadata_owner=$(print -rn -- "$tokens" | jq -r '.wf_owner // "" | strings')
[[ -z "$metadata_id" || "$metadata_id" = "$id" ]] || { print -u2 'Workspace belongs to another allocation; owners preserved.'; exit 1; }
if [[ "$metadata_id" = "$id" && -n "$metadata_owner" ]]; then
  owner=$metadata_owner
else
  owner="herdr-workspace:$workspace:$(/usr/bin/uuidgen)"
fi
owner_args=(--label 'Herdr workspace')
if print -rn -- "$allocation" | jq -e --arg owner "$owner" '.owners[$owner] != null' >/dev/null; then
  owner_args=()
  if print -rn -- "$allocation" | jq -e --arg owner "$owner" '.owners[$owner].label != null' >/dev/null; then
    owner_label=$(print -rn -- "$allocation" | jq -r --arg owner "$owner" '.owners[$owner].label')
    owner_args=(--label "$owner_label")
  fi
fi
"$wf_bin" --json retain "$id" --owner "$owner" --kind workspace "${owner_args[@]}" >/dev/null
"$herdr_bin" workspace report-metadata "$workspace" --source wf --token "wf_id=$id" --token "wf_owner=$owner" >/dev/null
"$wf_bin" --json release "$id" --owner "$provisional" >/dev/null
"$wf_bin" --json inspect "$id"
