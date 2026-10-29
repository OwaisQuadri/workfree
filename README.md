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

From a repository, create a new task:

```zsh
wf start feature/example --repo "$PWD"
```

Use the returned allocation identifier with `wf inspect`, `wf keep`, or `wf finish`. New tasks inherit saved repository authority if enabled below. Without that authority, cleanup stays disabled unless the operator explicitly grants it. The legacy shell-only `--allow-cleanup` flag remains available for final-owner cleanup.

## Recoverable cleanup

Enable dialog-free automatic cleanup across repositories, with an exclusion list:

```zsh
wf cleanup-policy enable --global
wf cleanup-policy exclude --repo /path/to/excluded-repository
wf cleanup-policy show --global
wf cleanup-policy migrate --global
```

Global setup is explicit and applies to future Workfree allocations in every repository except exclusions. Migration grants the saved policy to existing eligible managed allocations. It does not remove checkouts. It skips explicit grants, recorded revocations, restored or removed allocations, pending removals, and excluded repositories. Identity verification must pass for every selected allocation or the migration rolls back. Existing unmanaged worktrees remain unmanaged.

Use `wf cleanup-policy include --repo PATH` to remove an exclusion for future starts. Use `wf cleanup-policy revoke --global` to stop global inheritance and clear its derived allocation grants. Repository-specific and explicit allocation grants remain independent. Exclusions prevent standing-policy inheritance and migration, including repository-specific policies, and clear existing derived grants for that repository. They do not cancel explicit allocation grants.

For repository-specific setup instead:

```zsh
wf cleanup-policy show --repo "$PWD"
wf cleanup-policy enable --repo "$PWD"
wf start feature/example --repo "$PWD"
```

Repository-specific setup records authority in the private registry for the repository's canonical Git common directory, device, and inode. Only new allocations inherit it without explicit migration. Repository replacement at the same path does not inherit repository-specific authority. Global authority covers new repositories too. Exclusions use canonical primary-repository paths, so they survive replacement at the same path. A repository-specific policy takes precedence over the global policy.

Normal Pi starts inherit the saved policy without a dialog. Without a policy, normal starts remain valid but unauthorized for cleanup. The default grace period is 60 seconds. Standing policy grants no disposable paths, so ignored files remain protected.

Revoke repository authority with:

```zsh
wf cleanup-policy revoke --repo "$PWD"
```

Revocation atomically stops future inheritance and clears derived allocation grants and their grace periods. Independent explicit allocation grants, owners, and recovery records survive. Pending derived removal blocks revocation without partial changes. Re-enabling creates a new generation and never re-enrolls old allocations. Repeating enable with the same grace period keeps the current generation; revoke before changing it.

Grant a policy directly to one verified managed allocation:

```zsh
wf authorize-cleanup <allocation> --grace-seconds 60
wf preview
wf sweep
wf restore <allocation>
wf revoke-cleanup <allocation>
```

The grant covers that allocation, including later restored checkouts. It does not grant permission for other allocations.
Under this policy, task owners survive checkout removal. Workspace, execution, and pin owners still block removal, as do live or uncertain conversation claims.
The first eligible event starts the grace period. Acquiring an owner resets it.
Owner releases and later sweeps evaluate eligibility again.
New authority requires an explicit operator CLI setup or allocation grant. The model-facing tool cannot grant permission and returns concrete setup instructions instead of asking for confirmation. Direct shell grants record the operator's instruction without a second prompt. Explicit allocation grants replace inherited provenance; allocation revocation never re-enrolls under a standing policy.

Each removal preserves the exact commit under `refs/workfree/recovery/` in the surviving local repository.
Restore recreates that commit on a fresh branch using the recorded provider. It refuses an occupied destination.
This protects against checkout removal, not loss of the surviving repository or disk.
Recovery references have no automatic expiry.

Use `--disposable-path <relative-path>` only for an explicitly disposable generated directory. Repeat it for several approved generated roots, for example `--disposable-path .build --disposable-path node_modules`. Disposable paths require a direct operator allocation grant, not a model request or standing repository policy.
The rule permits ignored output under that path, not tracked or untracked changes.
Aliases, tracked contents, and paths outside the checkout fail validation.
Inspect the last 32 cleanup attempts and recovery record with `wf inspect`.
Legacy `--allow-cleanup` allocations keep their final-owner contract until an explicit policy grant. Standing policy uses recoverable cleanup, not that legacy flag. The model's legacy `isCleanupAllowed` input now only requires an existing standing policy; it cannot create permission.

The first repository policy advances the registry format to version 3. Global setup or an exclusion advances it to version 4. The format never downgrades after revocation. Older binaries fail closed and must be updated. Update and reload Pi and any shell or workspace integrations before enabling policy. Source edits alone do not change an already loaded runtime. See [Pi runtime updates](docs/pi.md#update).

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

Cleanup is disabled unless you explicitly grant allocation permission or a new allocation inherits recorded operator repository authority. Modified, staged, untracked, or uncertain checkout data blocks removal. Ignored files also block removal unless an explicit policy names their generated path as disposable. Existing worktrees are not automatically adopted.

Ownership is cooperative. Command exit does not prove that detached children have stopped. Execution owners remain until their scope is explicitly closed. Workfree does not detect or contain arbitrary processes using a checkout.

The Pi adapter protects its managed cwd and explicitly acquired allocations before its first startup sweep, then evaluates recorded cleanup permissions every 60 seconds. Durable conversation claims use the Pi host's PID, kernel start identity, and boot identity. Live or uncertain identity blocks deletion between turns, across reload, and during session replacement; no inactivity timeout releases protection. A child's exit cannot clear a parent's claim. Proven-dead claims are pruned without releasing legacy owners.

Use the structured `wf` tool's `claim` action before raw shell use of another allocation or child dispatch. Acquired IDs persist in non-transcript Pi metadata for reopen. Existing conversations need explicit backfill or reload; arbitrary paths in messages are not discovered. See [conversation protection](docs/pi.md#conversation-protection).

Shell-only users can schedule `wf sweep` with their existing scheduler. No daemon or scheduler is installed. Interrupted removal can be reconciled without granting new cleanup permission. Read the [safety contract](docs/safety.md) before integrating another host.

## Contribute or get help

See [CONTRIBUTING.md](CONTRIBUTING.md) for build and check commands. Report bugs and ask questions in [Issues](https://github.com/OwaisQuadri/workfree/issues).

Workfree is available under the [MIT license](LICENSE).
