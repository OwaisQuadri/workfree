# Pi integration

The package exposes a `wf` tool, `/wf`, and `/wf-finish`.
The Swift executable owns allocation and cleanup decisions. The adapter has no separate ownership counter.

## Install

Use macOS 13 or newer with Git and Swift 6 or newer available to Pi. Install Xcode or its Command Line Tools before using Workfree.

```zsh
pi install git:https://github.com/OwaisQuadri/workfree
```

Start a new Pi session or reload extensions. No global `wf` or shell installation is required.
The root Git package owns the Pi integration. Shell and Herdr installation are optional and do not activate Pi.

At session startup, Workfree prepares the executable for its first sweep.
Workfree reuses the validated executable for the Git revision captured when the extension loaded, or compiles that revision if none is bound.
Compilation uses a private temporary source snapshot and scratch directory, not Pi's managed checkout.
The completed executable lives at `~/Library/Application Support/workfree/runtime/<sha256>/wf` with private, read-only executable permissions.
First use can take time and fails if the required tools are unavailable. A later use retries a failed build without choosing a global or older executable.
Concurrent uses in one loaded extension share the build. Cancelling a tool stops that caller waiting but does not cancel compilation or publication.
A private, immutable revision binding records the product digest for the current platform and architecture. Later extension loads and shell invocations validate that binding and executable without rebuilding.
Concurrent first builds use independent workspaces. The first binding published wins, even if the builds produce different bytes. Both valid products can remain, but later loads reuse the winner.
Corrupt bindings, unsafe permissions, and missing or changed products fail without repair or fallback.

For a one-session trial from a committed source checkout:

```zsh
pi --extension ./integrations/pi/wf.ts
```

Uncommitted Swift edits are not build inputs. Reload after committing changes to capture the new revision.
`WF_BIN` is an explicit operator override captured at extension load. It bypasses Git preparation and compilation and runs the supplied path or command unchanged.
The default path never searches for `wf` on `PATH`.

## Update

Pi's native **Package Updates Available** notification covers this unpinned Git package.

```zsh
pi update --extensions
```

Complete the update, then reload extensions or start a new session.
The next first use selects the updated revision's product, building it if needed. Already loaded instances remain bound to their captured revision and resolved executable until reload.
Published executables and revision bindings survive Pi's checkout cleaning. Reloading the same revision does not build another product. Old immutable artifacts are not automatically removed.
Do not append `@main` or another ref to the install command. Pi treats explicit refs as pinned and excludes them from update notifications.
Bare `pi update` updates Pi itself, not extension packages.

## Link an optional shell entry

The package includes `integrations/pi/wf.zsh` for a shell or Herdr entry that follows Pi's managed Git checkout instead of a fixed standalone binary.
It requires Node.js 22.19 or newer on `PATH`, in addition to the macOS, Git, and Swift prerequisites above. It needs neither a global `wf` nor installed Pi peer packages at runtime.

Use `pi list` to find the managed Workfree checkout. Create a personal symlink to that checkout's `integrations/pi/wf.zsh` at your chosen shell entry point.
If that entry already exists, inspect it before replacing it. No link or global installation is created by the package.
Configure Herdr to invoke that same linked entry rather than an older standalone executable.

The entry resolves the package from its own location, including through a symlink. It shares the Pi extension's revision bindings and immutable products.
Each invocation captures the managed checkout's current revision. Complete `pi update --extensions` before invoking it to use the updated source.
The launcher passes arguments and standard streams unchanged and preserves the native process's exit status or terminating signal.
It ignores `WF_BIN`, so a shell entry pointing back to this launcher cannot recurse through the override. It does not update packages or change Pi settings.

For users without Pi, the ordinary Swift build and `scripts/install.zsh` standalone installer remain available. That installer copies a fixed executable and does not make it follow Pi updates.

## Migrate the old local package

If you previously activated the shell installer's flat Pi package, remove that declaration with Pi's normal package management:

```zsh
pi remove "$HOME/.local/share/workfree/pi"
pi install git:https://github.com/OwaisQuadri/workfree
```

Use `pi list` to find a different old path. If it was installed with `--local`, remove it with `pi remove --local <old-path>` in that project.
Reload extensions or start a new session after migration. Do not keep both local and Git declarations.
The installer no longer copies a Pi package. Existing shell commands and Herdr resources can stay installed.

## Task boundaries

A conversation is not one task.
Starting Pi in a home directory does not allocate a worktree.
An explanation or read-only question need not create one.
A repository task can explicitly start an allocation and retain it until completion.

The model-facing tool can create, inspect, retain, release, finish, pin, and reconcile allocations, and report storage status.
Creating an automatically removable allocation requires affirmative operator confirmation.
In a non-interactive mode, the adapter refuses that permission request rather than assuming approval.
The default start has no automatic cleanup permission.

The tool also exposes `authorize-cleanup`, `revoke-cleanup`, `preview`, `sweep`, and `restore`.
A recoverable policy requires affirmative confirmation, including its grace period and optional disposable path.
Task owners can survive eviction under that policy.
Execution, workspace, and pin owners still block removal.
The adapter sweeps recorded grants at session startup and every 60 seconds.
Session shutdown stops the timer without releasing owners.
No scheduler is installed outside Pi.

`/wf` shows storage saved, cleanup history, and each live allocation with its identifier and any blocker.
`/wf <allocation-id>` inspects one.
`/wf-finish <allocation-id>` asks before finishing its default task.
Finish does not release workspace, execution, or pin owners.

## Multiple tasks without subagents

Assign each repository task its own allocation identity.
Switching topics does not finish the previous task.
A retry reuses the existing assignment.
Several readers can retain one allocation with separate task owners.
Independent writers need separate checkouts.

Complete each task explicitly after its result is preserved.
Other allocations in the conversation remain unchanged.
Agent settlement, a merged pull request, and session shutdown do not trigger automatic completion.

## Subagents

This adapter does not intercept or replace a third-party subagent dispatcher.
The parent must acquire ownership before it dispatches work.

For a reader, retain an owner on the existing allocation.
For an independent writer, start a separate allocation and pass its returned path as the child's working directory.
Do not ask the child to create a second checkout for the same assignment.

The parent retains ownership until it inspects and accepts the result.
A child finishing does not authorize deleting an unreviewed result.
For an execution owner, entry exit records status; explicit cooperative scope closure releases ownership.
Only close that scope after its background work ends.

Task identifiers and owner tokens must remain outside conversational memory as well as in tool results.
The executable's registry is authoritative after compaction or session recovery.
Use inspection to recover state rather than reconstructing it from branch names.

## Failure behavior

Executable errors become failed Pi tool results.
Malformed executable output also fails the tool.
The adapter does not clear ownership to make an error disappear.
It does not infer that a stopped Pi process ended all descendant work.
Inspect unresolved scopes and reconcile them explicitly.
