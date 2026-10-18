# Workfree

Git worktrees with explicit owners. Opt-in cleanup frees a checkout after its last owner releases it and safety checks pass. The branch stays.

[![Check](https://github.com/OwaisQuadri/workfree/actions/workflows/check.yml/badge.svg)](https://github.com/OwaisQuadri/workfree/actions/workflows/check.yml)
[License](LICENSE)

## Install in Pi

Requires macOS, Swift 6 or newer, Git, and Pi.

```zsh
pi install git:https://github.com/OwaisQuadri/workfree
```

https://github.com/user-attachments/assets/edf2081a-5f2d-4141-9c48-203ec3cbdca5

The silent command-line demo shows Finish retaining a workspace owner, then the last release removing the checkout. Output is filtered with `jq`.

Start a new Pi session and ask it to create a managed worktree. Use `/wf` to inspect tasks and `/wf-finish <allocation>` when a task is done.

The package builds its own private executable on first use. No separate `wf` installation is needed. The same installed revision reuses its verified runtime. New source gets a matching runtime after you update and reload.

Workfree appears in Pi's normal package update notice. Update it with your other extensions:

```zsh
pi update --extensions
```

Start a new session after the update completes. Keep the package source unpinned if you want these notices.

See [Pi setup and migration](docs/pi.md) for details and the optional Pi-linked shell entry point.

## Optional shell and Herdr setup

Pi users can use the package-owned shell entry point so their shell and Herdr flows follow the same package updates. See [Pi setup](docs/pi.md).

For a standalone shell installation without Pi:

```zsh
git clone https://github.com/OwaisQuadri/workfree.git
cd workfree
./scripts/install.zsh
```

The standalone installer builds `wf` and installs the optional Herdr adapters. It refuses existing installation targets. Add `~/.local/bin` to your shell's `PATH` if needed. Activation is separate. See [Herdr setup](docs/herdr.md).

From a repository, create a new task with cleanup enabled:

```zsh
wf start feature/example --repo "$PWD" --allow-cleanup
```

Use the returned allocation identifier with `wf inspect`, `wf keep`, or `wf finish`. Omitting `--allow-cleanup` keeps automatic cleanup disabled.

## How ownership works

A task, workspace, execution scope, or pin can retain one allocation. These owners release independently:

- Finish the task while leaving its workspace open.
- Close a workspace without finishing its task.
- Keep an allocation pinned for later work.
- Remove the checkout only after the final owner releases it, cleanup is authorized, and safety checks pass.

Workfree works with ordinary Git. When available, the optional [simgit](https://github.com/abendrothj/simgit) provider shares initial file storage through copy-on-write. Use `--require-cow` when that is required. The selected provider is recorded per allocation and failures never silently switch providers.

Keep ordinary commits, fetches, pushes, and rebases in Git. Workfree manages checkout ownership, not Git history.

## Safety boundaries

Cleanup is disabled unless you permit it for a new allocation. Modified, staged, untracked, ignored, or uncertain checkout data blocks removal. Existing worktrees are not automatically adopted.

Ownership is cooperative. Command exit does not prove that detached children have stopped. Execution owners remain until their scope is explicitly closed. Workfree does not detect or contain arbitrary processes using a checkout.

There is no cleanup timer or daemon. Interrupted removal can be reconciled without granting new cleanup permission. Read the [safety contract](docs/safety.md) before integrating another host.

## Contribute or get help

See [CONTRIBUTING.md](CONTRIBUTING.md) for build and check commands. Report bugs and ask questions in [Issues](https://github.com/OwaisQuadri/workfree/issues).

Workfree is available under the [MIT license](LICENSE).
