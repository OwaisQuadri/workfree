#!/bin/zsh
set -euo pipefail
path=("$HOME/.local/bin" /opt/homebrew/bin /usr/local/bin $path)
wf_bin=${WF_BIN:-wf}
herdr_bin=${HERDR_BIN:-${HERDR_BIN_PATH:-herdr}}
rows=$("$herdr_bin" workspace list | jq -c '[.result.workspaces[] | select(.worktree.checkout_path | type == "string") | {id: .workspace_id, path: .worktree.checkout_path, repo: .worktree.repo_key, isLinked: (.worktree.is_linked_worktree == true)}]')
paths=(${(0)"$(print -rn -- "$rows" | jq -j 'map(.path) | unique[] | . + "\u0000"')"})
(( ${#paths} )) || exit 0
sizes=$("$wf_bin" --json measure "${paths[@]}")
reports=$(jq -nr --argjson rows "$rows" --argjson sizes "$sizes" '
  def tenths($unit): (. / $unit * 10 | round) as $t | "\($t / 10 | floor).\($t % 10)";
  def size: if . >= 1e9 then "\(tenths(1e9)) GB" elif . >= 1e6 then "\(tenths(1e6)) MB" else "\(. / 1e3 | round) KB" end;
  ($sizes | map({key: .path, value: .}) | from_entries) as $usage
  | $rows[]
  | . as $row
  | select($usage[$row.path] != null)
  | if .isLinked then
      [$row.id, "wf_size", $usage[$row.path].copied]
    else
      ([$rows[] | select(.isLinked and .repo == $row.repo and $usage[.path] != null)]
        | unique_by(.path) | map($usage[.path].usage.privateBytes)) as $copies
      | [$row.id, "wf_total",
          $usage[$row.path].full + (if ($copies | length) > 0
            then " + \($copies | add | size)"
            else "" end)]
    end
  | @tsv')
is_failed=0
print -r -- "$reports" | while IFS=$'\t' read -r workspace token value; do
  [[ -n $workspace ]] || continue
  "$herdr_bin" workspace report-metadata "$workspace" --source wf-size --token "$token=$value" >/dev/null || is_failed=1
done
(( ! is_failed ))
