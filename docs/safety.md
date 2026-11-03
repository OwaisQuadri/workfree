# Safety contract

Workfree manages cooperative ownership, not operating-system access to files.
Its guarantee applies to clients that acquire ownership before using a managed checkout and release ownership only after their use ends.
An unrelated editor, shell, or background process can bypass that contract.
Do not promise universal process containment.

## Separate lifetimes

A task, workspace, execution scope, and pin have separate owners.
Finish releases only task ownership.
Closing a workspace releases only that workspace's ownership.
A pin lasts until explicit removal.

An execution scope includes its background work.
Entry-process exit records status without releasing ownership.
Explicit scope closure promises that no remaining work in that scope needs the checkout.
A child acquires ownership before its parent releases ownership.
An unknown or crashed scope retains ownership until explicit reconciliation.

A conversation can contain several tasks.
An agent ending a turn or a pull request being merged does not finish those tasks.
Durable conversation claims are separate from all legacy owners. They identify a session and its host process using a PID, kernel start identity, and boot identity, never a PID alone. A matching live process, inaccessible process metadata, or identity ambiguity blocks every removal path. Only positively proven process termination makes a claim nonblocking; no heartbeat or elapsed-time rule expires it. Sweeps discard proven-dead claims rather than retaining unbounded dead session history. They never automatically retire legacy owners.

## Removal

Automatic cleanup requires an explicit allocation grant, creation-time inheritance from operator-enabled standing policy, or explicit operator migration.
The default is no grant until setup. Global policy covers future managed allocations across repositories except excluded canonical primary-repository paths. Repository-specific policy takes precedence and binds the common directory, persistent volume identifier, and inode. Repository replacement cannot inherit repository-specific authority, but remains covered by global authority unless excluded. Exclusions survive replacement at the same path. Unmanaged worktrees remain unmanaged.

`wf cleanup-policy enable|show|revoke --global` controls global authority. `exclude|include --repo PATH` edits the exclusion list. Exclusion atomically clears derived grants for that repository but preserves explicit allocation grants. Inclusion affects future starts only. `migrate --global` explicitly enrolls existing retained or blocked allocations with verified identity and no policy. Recorded revocations, pending removals, restored allocations, and exclusions prevent migration. Migration is atomic and resets eligibility; it does not remove checkouts. Sweep and reload never perform migration.

`wf cleanup-policy show|enable|revoke --repo PATH` is operator setup, not a model tool action. Standing policy records a default 60-second grace value, but inherited allocations wait at least 24 hours after eligibility before offload. Explicit allocation grants retain their configured grace period. Standing policy grants no disposable paths. Normal Pi start under saved authority needs no dialog. Without it, normal start is retained without cleanup authority. Model requests for new authority fail with operator CLI instructions, never synthesized consent.

Repository revocation atomically removes the standing grant and all derived allocation grants and eligibility. Independent explicit grants, owners, and recovery records remain. Any pending derived removal blocks the entire revocation. Explicit allocation grants clear inherited provenance; allocation revocation clears both forms of authority. A new policy generation applies only to future creations unless the operator explicitly migrates eligible managed allocations. Sweep, restore, and reload never re-enroll an allocation. Revocations record a durable refusal of later standing-policy migration. Global revocation preserves independent repository and explicit grants. Pending derived removal blocks global revocation and exclusion without partial changes.

Legacy cleanup requires zero owners.
An explicit recoverable policy lets task owners survive eviction.
Workspace, execution, and pin owners must still release before removal.
Age, command exit, and a saved commit do not prove that those users stopped.

Removal requires matching allocation identity, a non-primary checkout, no unpreserved changes, and an exact recovery reference.
Workfree creates the recovery reference in the surviving local repository before recording removal intent.
Under a recoverable policy, Workfree writes staged contents to an ancestor commit and tracked and untracked working-tree contents to a final checkpoint commit without changing the checkout's index or branch during snapshot creation. Restore checks out the final working-tree state; the staged snapshot remains in its commit history, not in the restored index. Workfree pushes the final commit to an allocation-specific `workfree/offload/` branch on `origin` and verifies the remote commit before removal. It then advances the checkout to that commit without overwriting working files. Removal refuses a checkout that becomes dirty after this step. A failed removal can leave the branch and index at the checkpoint; both prior states remain in the remote commits. A missing remote or failed push retains the checkout. Legacy cleanup without a recoverable policy still requires unchanged tracked and untracked files.
Ignored files block cleanup unless an explicit policy names their generated path as disposable.
Tracked contents, aliases, and paths outside the checkout cannot qualify as disposable output.
Git operations in progress also block cleanup.

The explicit one-off `offload` command requires an allocation identifier or repository path, a minimum idle age, and a local or remote checkpoint destination. It considers the latest checkout file modification and the latest direct user or assistant Pi transcript message that names the allocation path or identifier. A missing or unreadable session directory blocks age-based offload. A zero-hour age skips history only because the operator requested no age restriction. It still requires exact identity, no active workspace, execution, pin, or conversation use, and a preservable file state. Offload creates separate staged and working commits and a verified local recovery reference, then advances the checkout to the checkpoint; it never removes the checkout. Remote mode verifies an allocation-specific branch on `origin`. Local mode has no protection against loss of the surviving repository. The later `cleanup-now` command rechecks identity, use, clean files, and the recovery reference and removes only a checkout with a manual checkpoint. The primary checkout, unmanaged worktrees, and blocked allocations remain. Automatic sweeps never remove a manual checkpoint until the explicit cleanup step succeeds.

The allocation identity is not merely a path or branch name.
A replacement checkout at the same path must not satisfy an old removal request.
Git registration checks compare normalized paths, including aliases and paths that no longer exist.
A missing directory with a remaining registration is not a completed removal.
Explicit repository-replacement repair requires the same common directory, the recorded linked-worktree administration path, Git registration, and the recorded allocation marker. It replaces the marker before saving the new identity; an interruption leaves normal access blocked until the explicit repair is retried. Replacement repair clears allocation cleanup authority and leaves repository-specific policy tied to the old identity. It does not prove historical repository content. Workspace, execution, pin, and blocking conversation owners still prevent offload; task owners do not block policy offload.

Legacy cleanup and policy offload call the provider's removal command without dirty-removal flags. Workfree never deletes branches automatically. It does not change the checkout's index to create the checkpoint, but it advances the branch and index to the published checkpoint before removal.

## Persistence and failure

The registry serializes ownership changes and removal.
The first saved conversation claim advances registry format 1 to 2 in the same SQLite transaction as the claim, while holding the registry lock. The first standing repository policy advances it to 3 atomically with policy persistence, before any allocation can inherit authority. Global policy or an exclusion advances the registry to version 4 atomically with its persistence. Stable volume identities and explicit legacy identity repair advance the registry to version 5 in the same transaction as persistence. Version-4 binaries reject version 5 before mutation. New binaries read all five versions without granting authority to old records. Version-3 binaries reject version 4 before cleanup or mutation. Pre-claim binaries reject version 2; version-2 binaries reject version 3 before cleanup or owner mutation. Conversation saves, claim pruning, and policy revocation never downgrade the format. Activation requires updated CLI and adapter code; older loaded sessions stop safely and must reload before operating. Merely updating package source does not cover already-open assignments.
A client cannot acquire a checkout while deletion is in progress.
State records removal intent before the filesystem operation.
Recovery must inspect the actual directory and Git registration before it records completion.

Corrupt or unreadable ownership state must block mutation.
A manager crash must not silently release durable task or execution ownership.
Elapsed time cannot prove an owner is dead or a task is complete.

Process-kill tests verify particular interruption points.
They do not prove behavior under every storage failure or establish power-loss durability by themselves.

## Host adapters

Workspace ownership must exist before the adapter exposes a checkout to Herdr.
The close-event adapter releases only the owner recorded on that workspace.
Ambiguous opens, failed metadata registration, and missing close events retain ownership.
Reconcile those records explicitly after checking the actual workspace state.
Do not expire them on a timer.

The Pi adapter acquires the managed cwd and persisted explicit allocation IDs before its first startup sweep, then evaluates recorded permissions every 60 seconds. Acquisition and all destructive paths serialize under the same registry lock, including removal recovery and explicit owner release. Named structured operations bind before operating; creation and restoration acquire before exposing the checkout. An unavailable target is rejected. No lock is held while waiting for a conversation to end.
Owner release events also evaluate cleanup.
A grace period delays eligible policy cleanup. Background sweeps defer file and storage scans during that period. An explicit preview checks files immediately. Workfree checks them again before removal.
New acquisition resets the grace period under the same registry lock as removal.
A timer never grants permission or expires ownership.
Shell-only integrations must arrange their own `wf sweep` schedule.

The Pi adapter exposes explicit ownership operations.
It does not reinterpret session shutdown, agent settlement, or topic changes as task completion or conversation closure. Claims survive idle turns, extension reload, and session replacement. Replacement acquires new protection without releasing predecessor claims. Parent and child claims remain independent; terminating one cannot release another.
It does not automatically wrap third-party subagent dispatch.
The caller must claim every assigned allocation before dispatch and preserve parent ownership until result acceptance. The adapter persists acquired allocation IDs as non-transcript Pi metadata, including structured targets outside its cwd. It does not infer arbitrary paths from messages. Already-open sessions require explicit backfill or reload. Raw shell access outside the managed cwd requires an explicit claim before use; it is not automatically detected.

## Limits

The first release trusts clients running under the same user account.
It is not an authorization boundary against a hostile process with access to the registry or Git administrative files.
It does not isolate network access, credentials, or files outside the checkout.
It does not make independent mutable build outputs safe to share.

Copy-on-write saves initial file storage, not every later build output or installed dependency.
Do not equate logical directory size with reclaimed physical storage.
Cleanup reports estimated private bytes, not a measured change in filesystem free space.
Restoring a checkout does not erase earlier removal history.
Recovery references do not expire automatically.
A local recovery reference does not protect against loss of the repository or disk.

## Worktree provider

Native Git is sufficient for ownership and safe cleanup.
When available, the optional `simgit` provider can reduce initial checkout storage through copy-on-write.
Record the provider on the allocation and use it for removal.
A failed selected provider is an error, not permission to switch providers silently.
`--require-cow` forbids an ordinary Git checkout.
