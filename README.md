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

For an older allocation blocked only by a changed device number, run `wf repair-identity <allocation>`. Repair verifies its original directory, inode, marker, and Git registration, then records the current persistent volume identifier without changing marker bytes or granting cleanup authority. This is an explicit binding to the current volume; old records cannot prove their historical volume identifier. Missing checkouts remain blocked. If the repository at the same common directory was replaced, `wf repair-identity <allocation> --accept-replaced-repository` explicitly rebinds a registered linked checkout with its recorded marker to the current repository identity. It does not prove that the replaced repository has the same history, grant cleanup, or close active owners. Inspect the checkout and preserve any work before migration. Use `wf cleanup-policy migrate --global --allocation <allocation>` to migrate one verified allocation without changing other records.

Use `wf cleanup-policy include --repo PATH` to remove an exclusion for future starts. Use `wf cleanup-policy revoke --global` to stop global inheritance and clear its derived allocation grants. Repository-specific and explicit allocation grants remain independent. Exclusions prevent standing-policy inheritance and migration, including repository-specific policies, and clear existing derived grants for that repository. They do not cancel explicit allocation grants.

For repository-specific setup instead:

```zsh
wf cleanup-policy show --repo "$PWD"
wf cleanup-policy enable --repo "$PWD"
wf start feature/example --repo "$PWD"
```

Repository-specific setup records authority in the private registry for the repository's canonical Git common directory, persistent volume identifier, and inode. Only new allocations inherit it without explicit migration. Repository replacement at the same path does not inherit repository-specific authority. Global authority covers new repositories too. Exclusions use canonical primary-repository paths, so they survive replacement at the same path. A repository-specific policy takes precedence over the global policy.

Normal Pi starts inherit the saved policy without a dialog. Without a policy, normal starts remain valid but unauthorized for cleanup. Inherited allocations wait at least 24 hours after the last blocking owner or conversation leaves, even though policy setup still records a default grace value of 60 seconds. Explicit per-allocation grants use their configured grace value. Standing policy grants no disposable paths, so ignored files remain protected.

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

Policy offload snapshots tracked and untracked contents in a flagged commit on `origin` under `workfree/offload/<allocation>`. Removal waits for a verified push, then advances the checkout's branch and index to that commit without overwriting working files. The provider refuses removal if new changes appear. A failed removal can leave that checkout at the checkpoint; the prior staged and working states remain in the remote history. Missing or failed remotes retain the checkout. Ignored files remain blocked unless explicitly disposable. The primary checkout remains in place.
Each removal also preserves the exact commit under `refs/workfree/recovery/` in the surviving local repository.
Restore recreates that commit on a fresh branch using the recorded provider. It refuses an occupied destination.
The local recovery reference protects legacy cleanup against checkout removal, not loss of the surviving repository or disk.
Recovery references have no automatic expiry.

Use `--disposable-path <relative-path>` only for an explicitly disposable generated directory. Repeat it for several approved generated roots, for example `--disposable-path .build --disposable-path node_modules`. Disposable paths require a direct operator allocation grant, not a model request or standing repository policy.
The rule permits ignored output under that path, not tracked or untracked changes.
Aliases, tracked contents, and paths outside the checkout fail validation.
Inspect the last 32 cleanup attempts and recovery record with `wf inspect`.
Legacy `--allow-cleanup` allocations keep their final-owner contract until an explicit policy grant. Standing policy uses recoverable cleanup, not that legacy flag. The model's legacy `isCleanupAllowed` input now only requires an existing standing policy; it cannot create permission.

The first repository policy advances the registry format to version 3. Global setup or an exclusion advances it to version 4. The format never downgrades after revocation. Older binaries fail closed and must be updated. Update and reload Pi and any shell or workspace integrations before enabling policy. Source edits alone do not change an already loaded runtime. See [Pi runtime updates](docs/pi.md#update).

## One-off offload and cleanup

For a reviewed group of managed worktrees, choose a minimum idle age and checkpoint destination explicitly. Preview first:

```zsh
wf --json offload-preview --repo "$PWD" --min-idle 2w
wf --json offload --repo "$PWD" --min-idle 2w --checkpoint remote
wf --json cleanup-now --repo "$PWD" --min-idle 2w
```

Use an allocation identifier instead of `--repo "$PWD"` to target one checkout. Use `--checkpoint local` to keep the checkpoint only in the surviving local Git repository. `remote` pushes and verifies an allocation-specific branch on `origin` before any cleanup. Both modes preserve staged and working contents as separate commits, move the checkout to the checkpoint without overwriting files, and keep a local recovery reference. Offload does **not** remove the checkout. `cleanup-now` is a separate command that removes only worktrees with a verified manual checkpoint and no changes since it. Restore with `wf restore <allocation>`. The primary checkout remains. Offload records the earlier file activity, so it does not restart the chosen idle age. A later file change starts a new idle period.

`--min-idle 0h` requests an immediate one-off pass. Other ages use hours, days, or weeks, such as `24h`, `3d`, or `2w`. The preview checks the latest file modification in each checkout and the latest direct user or assistant transcript message that names its path or allocation identifier. It also checks recorded owners and conversation claims. Use `--sessions-dir PATH` to point to a different Pi session directory. Missing or unreadable history blocks age-based offload; it never silently substitutes a guess. Active workspace, execution, pin, or conversation use blocks both steps. One-off commands do not enroll unmanaged worktrees, change standing cleanup policy, or bypass a failed identity check. `cleanup-now` reports which checkpoints it removed; review its preview before you confirm removal.

## Storage saved

`wf status` and Pi's `/wf` show the last measured copy-on-write (CoW) savings without scanning every worktree:

```text
Workfree

  5.0 GB   saved with CoW · oldest measurement 10m ago
  1.2 GB   reclaimed by cleanup · last 30 days
  ~700.0 MB   pending cleanup · 3 worktrees

  Next eligible: ~400.0 MB · 2 worktrees · 2:40 PM

  34 worktrees · 36.6 GB available on this disk
```

Run `wf status --refresh` to scan worktrees and update the saved measurements. Until the first refresh, savings and pending size say `not measured`. If some worktrees have no measurement, the report shows how many are measured. The oldest measurement age makes stale figures visible. The available-space figure refers to the disk that holds Workfree's registry, not every worktree disk.

CoW savings are the full allocated bytes minus private bytes in measured worktrees. Build outputs and untracked files are private. Reclaimed bytes are estimates recorded when cleanup removed worktrees. Pending cleanup counts only authorized worktrees with a recorded grace period and no live owner. It is an estimate, not permission to remove a worktree: the final file and identity checks can still block cleanup. The next-eligible amount groups pending worktrees scheduled within one minute of the earliest one. Eligibility does not mean a sweep will run at that time.

`--since 24h`, `--since 2w`, or `--since all` changes the cleanup history window; the default is 30 days. `wf status --detailed` keeps the previous per-repository report and performs a live scan. `--json status` returns the compact overview; use `--json status --detailed` for the prior detailed data. Any `wf` command that removes a checkout prints the reclaimed size. `/wf-finish` in Pi shows it too.

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
