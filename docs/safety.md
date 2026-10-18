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

## Removal

Automatic cleanup requires an affirmative grant for that allocation.
The default is no grant.
Existing worktrees remain unmanaged.

Before removal, require zero owners, matching allocation identity, a non-primary checkout, no valuable file changes, and retained commit references.
Modified, staged, untracked, and ignored files block cleanup.
Workfree does not infer that ignored files are disposable.

The allocation identity is not merely a path or branch name.
A replacement checkout at the same path must not satisfy an old removal request.
Git registration checks compare normalized paths, including aliases and paths that no longer exist.
A missing directory with a remaining registration is not a completed removal.

Workfree calls `simgit remove` without destructive flags.
It never deletes branches automatically, discards dirty files, or commits work to satisfy cleanup.

## Persistence and failure

The registry serializes ownership changes and removal.
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

The Pi adapter exposes explicit ownership operations.
It does not reinterpret session shutdown, agent settlement, or topic changes as task completion.
It does not automatically wrap third-party subagent dispatch.
The caller must acquire the assigned owner before dispatch and preserve parent ownership until result acceptance.

## Limits

The first release trusts clients running under the same user account.
It is not an authorization boundary against a hostile process with access to the registry or Git administrative files.
It does not isolate network access, credentials, or files outside the checkout.
It does not make independent mutable build outputs safe to share.

Copy-on-write saves initial file storage, not every later build output or installed dependency.
Do not equate logical directory size with reclaimed physical storage.

## Worktree provider

Native Git is sufficient for ownership and safe cleanup.
When available, the optional `simgit` provider can reduce initial checkout storage through copy-on-write.
Record the provider on the allocation and use it for removal.
A failed selected provider is an error, not permission to switch providers silently.
`--require-cow` forbids an ordinary Git checkout.
