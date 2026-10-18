# Workfree

Explicit ownership for Git worktrees, with cleanup on the final safe release.

Workfree works with ordinary Git worktrees.
It recommends [simgit](https://github.com/abendrothj/simgit) for copy-on-write storage.
It keeps each checkout while a task, workspace, execution scope, or pin retains it.
It never decides that work is disposable because it is old.

The first version targets macOS.
It has no server, account, background daemon, or scheduled collector.

## Install

Requirements: macOS, a Swift toolchain, and Git.
From the source checkout:

```zsh
./scripts/install.zsh
export PATH="$HOME/.local/bin:$PATH"
```

The installer builds `wf` and installs the optional adapter files.
It refuses existing installation targets and does not activate Pi or Herdr.
Use `--prefix DIRECTORY` for another installation location.

For lower initial checkout storage, install the optional provider:

```zsh
brew install abendrothj/tap/simgit
```

Workfree prefers installed `simgit`; otherwise it uses native Git.
A selected-provider failure remains an error.
Use `--provider git` to select native Git explicitly.
Use `--require-cow` to refuse an ordinary checkout.

## Start and finish

From the source repository:

```zsh
wf --json start feature/example --repo . --allow-cleanup
```

Keep the returned allocation identifier.
Workfree defaults to no automatic cleanup permission when you omit `--allow-cleanup`.

```zsh
wf inspect <allocation-id>
wf keep <allocation-id>
wf unkeep <allocation-id>
wf finish <allocation-id>
```

Finish releases the task owner, not workspace or execution owners.
After the final owner releases an authorized allocation, Workfree checks its files, identity, and retained commits before removal.
It keeps branches by default.
It never discards dirty files or makes an automatic commit.

## Background work

An entry command can exit while a child still uses its checkout.
Workfree therefore does not treat command exit as scope completion.

```zsh
wf run <allocation-id> --owner build -- <command>
wf close-scope <allocation-id> --owner build
```

The second command is an explicit cooperative promise that this scope has no remaining checkout use.
Run records the entry status and retains ownership until that promise.
Only close a scope after its background work ends.
Unknown execution state retains the checkout.

A child must acquire its own owner before its parent releases ownership:

```zsh
wf retain <allocation-id> --owner child-review --kind execution
wf close-scope <allocation-id> --owner child-review
```

This is a cooperative lifecycle tool, not a process sandbox.
It cannot protect against an unrelated application that bypasses ownership.

## Herdr

The optional scripts in `integrations/herdr` provide these actions:

- Open creates a task and retains workspace ownership before opening Herdr.
- Close for now releases only workspace ownership.
- Finish and close releases the task and workspace ownership separately.
- Keep pins the checkout without closing its workspace.

A workspace-close event hook handles closure outside the helper script.
Ambiguous open failures and missed events retain ownership for inspection.
Existing unmanaged workspaces can close, but these adapters never remove their checkouts.
See [Herdr integration](docs/herdr.md) for setup and recovery.

## Pi

The optional Pi package exposes a `wf` tool and explicit inspection and Finish commands.
It does not infer task completion from agent settlement, a merged pull request, session shutdown, or a topic change.

One conversation can manage several task allocations.
Read-only children can retain the same allocation.
Independent writers need separate allocations.
A parent must retain a writer's allocation until it accepts and preserves the result.

See [Pi integration](docs/pi.md) for setup and task handoffs.

## Safety and recovery

Workfree refuses removal when permission, ownership, file state, commit preservation, or allocation identity is uncertain.
Ignored files also block cleanup.
No existing checkout becomes managed merely because you install Workfree.

```zsh
wf list
wf inspect <allocation-id>
wf recover <allocation-id>
```

Recovery does not expire owners or infer that a dead entry process means all its work ended.
See [the safety contract](docs/safety.md) for the precise boundary.

## Contribute

See [CONTRIBUTING.md](CONTRIBUTING.md) for the source checks and adapter tests.
The Swift library target is `Workscope`; the public command is `wf`.
