# Workfree

Git worktrees with explicit owners and opt-in cleanup. Recoverable cleanup can evict an inactive checkout while its task stays unfinished. A Git reference preserves the exact commit.

[![Check](https://github.com/OwaisQuadri/workfree/actions/workflows/check.yml/badge.svg)](https://github.com/OwaisQuadri/workfree/actions/workflows/check.yml)
[License](LICENSE)

## Install

Requires macOS, Swift 6 or newer, and Git.

```zsh
curl -fsSL https://raw.githubusercontent.com/OwaisQuadri/workfree/main/scripts/bootstrap.zsh | zsh
```

This builds `wf` and the optional Herdr adapters into `~/.local/bin`. Add that directory to your shell's `PATH` if needed. Pass installer options after `zsh -s --`, for example `| zsh -s -- --prefix DIRECTORY`.

## Recommended: use with Pi

Workfree works on its own. With [Pi](https://pi.dev), agents create and release worktrees for you. Install the Pi package instead of, or as well as, the standalone command:

```zsh
pi install git:https://github.com/OwaisQuadri/workfree
```

https://github.com/user-attachments/assets/edf2081a-5f2d-4141-9c48-203ec3cbdca5

The silent command-line demo shows Finish retaining a workspace owner, then the last release removing the checkout. Output is filtered with `jq`.

Start a new Pi session and ask it to create a managed worktree. Use `/wf` to see each task, its allocation identifier, and storage saved. Use `/wf-finish <allocation>` when a task is done.

The package builds its own private executable on first use. No separate `wf` installation is needed. The same installed revision reuses its verified runtime. New source gets a matching runtime after you update and reload.

Workfree appears in Pi's normal package update notice. Update it with your other extensions:

```zsh
pi update --extensions
```

Start a new session after the update completes. Keep the package source unpinned if you want these notices.

See [Pi setup and migration](docs/pi.md) for details and the optional Pi-linked shell entry point.

## Optional shell and Herdr setup

Pi users can use the package-owned shell entry point so their shell and Herdr flows follow the same package updates. See [Pi setup](docs/pi.md).

To install from a source checkout instead of the [curl command](#install):

```zsh
git clone https://github.com/OwaisQuadri/workfree.git
cd workfree
./scripts/install.zsh
```

Both routes run the same installer. It refuses existing installation targets. Activation is separate. See [Herdr setup](docs/herdr.md).

From a repository, create a new task with cleanup enabled:

```zsh
wf start feature/example --repo "$PWD" --allow-cleanup
```

Use the returned allocation identifier with `wf inspect`, `wf keep`, or `wf finish`. Omitting `--allow-cleanup` keeps automatic cleanup disabled.

## Recoverable cleanup

Grant a policy to one verified managed allocation:

```zsh
wf authorize-cleanup <allocation> --grace-seconds 60
wf preview
wf sweep
wf restore <allocation>
wf revoke-cleanup <allocation>
```

The grant covers that allocation, including later restored checkouts. It does not grant permission for other allocations.
Under this policy, task owners survive checkout removal. Workspace, execution, and pin owners still block removal.
The first eligible event starts the grace period. Acquiring an owner resets it.
Owner releases and later sweeps evaluate eligibility again.
The Pi adapter asks for confirmation before a policy grant.
A direct shell grant records the operator's instruction without a second prompt.

Each removal preserves the exact commit under `refs/workfree/recovery/` in the surviving local repository.
Restore recreates that commit on a fresh branch using the recorded provider. It refuses an occupied destination.
This protects against checkout removal, not loss of the surviving repository or disk.
Recovery references have no automatic expiry.

Use `--disposable-path <relative-path>` only for an explicitly disposable generated directory.
The rule permits ignored output under that path, not tracked or untracked changes.
Aliases, tracked contents, and paths outside the checkout fail validation.
Inspect the last 32 cleanup attempts and recovery record with `wf inspect`.
Legacy `--allow-cleanup` allocations keep their final-owner contract until an explicit policy grant.

## Storage saved

`wf status` shows what copy-on-write storage and cleanup save you:

```text
Live worktrees: 3 · full checkouts would use 3.1 GB · actually using 2.0 GB · saved 1.1 GB
Native checkouts: 1 use 684.6 MB. With simgit, they would use about 120.0 MB (estimate).
Auto-cleanup, last 30 days: 1 worktree removed · 412.0 MB reclaimed (estimated private bytes)

/path/to/repo  1.2 GB + 2.0 GB
  feature/a  5497abb5-a8e9-4f0d-b860-b7ae83eb7ca5  886.4 MB
  fix/b  c1922b5d-15bc-4987-a213-e3a3368f38df  444.8 MB
  fix/c  fa1733c0-6aca-4fde-8b5f-39f9fd3a2026  684.6 MB  blocked: Changed, staged, untracked, or ignored files remain
```

- Full size counts every allocated block. Actual use counts only the blocks that a worktree does not share with an APFS clone.
- Build outputs and other untracked files are always private, so they reduce the saving.
- Each repository line shows the full size of its base checkout plus the private bytes of its worktrees.
- Native Git worktrees also show an estimate of their size with simgit.
- Allocations whose checkout no longer exists appear under "Missing checkouts" with their identifier and phase. `wf recover` completes an interrupted removal.
- `--since 24h`, `--since 2w`, or `--since all` changes the cleanup window. The default is 30 days.
- Any `wf` command that removes a checkout prints the reclaimed size. `/wf-finish` in Pi shows it too.
- In Pi, `/wf` shows the same report.

Cleanup history starts with this version. The report walks every live worktree, so it takes seconds for large checkouts.

## How ownership works

A task, workspace, execution scope, or pin can retain one allocation. These owners release independently:

- Finish the task while leaving its workspace open.
- Close a workspace without finishing its task.
- Keep an allocation pinned for later work.
- Remove the checkout only after the final owner releases it, cleanup is authorized, and safety checks pass.

Workfree works with ordinary Git. When available, the optional [simgit](https://github.com/abendrothj/simgit) provider shares initial file storage through copy-on-write. Use `--require-cow` when that is required. The selected provider is recorded per allocation and failures never silently switch providers.

Keep ordinary commits, fetches, pushes, and rebases in Git. Workfree manages checkout ownership, not Git history.

## Safety boundaries

Cleanup is disabled unless you permit it for an allocation. Modified, staged, untracked, or uncertain checkout data blocks removal. Ignored files also block removal unless an explicit policy names their generated path as disposable. Existing worktrees are not automatically adopted.

Ownership is cooperative. Command exit does not prove that detached children have stopped. Execution owners remain until their scope is explicitly closed. Workfree does not detect or contain arbitrary processes using a checkout.

The Pi adapter evaluates recorded cleanup permissions at session startup and every 60 seconds while the session runs. Shell-only users can schedule `wf sweep` with their existing scheduler. No daemon or scheduler is installed. Interrupted removal can be reconciled without granting new cleanup permission. Read the [safety contract](docs/safety.md) before integrating another host.

## Contribute or get help

See [CONTRIBUTING.md](CONTRIBUTING.md) for build and check commands. Report bugs and ask questions in [Issues](https://github.com/OwaisQuadri/workfree/issues).

Workfree is available under the [MIT license](LICENSE).
