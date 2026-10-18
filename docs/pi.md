# Pi integration

The optional package exposes a `wf` tool, `/wf`, and `/wf-finish`.
It delegates ownership and cleanup decisions to the same executable as the shell and Herdr adapters.
It has no separate ownership counter.

## Activate

Install Workfree first, then explicitly load the adapter:

```zsh
pi install "$HOME/.local/share/workfree/pi"
```

Start a new Pi session to load it.
For a one-session trial from the source checkout:

```zsh
pi --extension ./integrations/pi/wf.ts
```

The adapter resolves `wf` through the process environment.
`WF_BIN` can select an explicit executable path.
The package does not install or replace that executable automatically.

## Task boundaries

A conversation is not one task.
Starting Pi in a home directory does not allocate a worktree.
An explanation or read-only question need not create one.
A repository task can explicitly start an allocation and retain it until completion.

The model-facing tool can create, inspect, retain, release, finish, pin, and reconcile allocations.
Creating an automatically removable allocation requires affirmative operator confirmation.
In a non-interactive mode, the adapter refuses that permission request rather than assuming approval.
The default start has no automatic cleanup permission.

`/wf` lists allocations.
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
