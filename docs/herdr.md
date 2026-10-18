# Herdr integration

The optional adapter uses Herdr's worktree opening, workspace metadata, and close-event hooks.
It does not replace Git or use Herdr's force-removal route.
It requires `jq` and a Herdr version compatible with the included plugin manifest.
The interactive close menu also uses `fzf` when available; explicit actions do not require it.

## Activate with Pi

First follow [Pi installation and the optional shell entry](pi.md).
Link the shell command `wf` to that package-owned entry so Herdr uses the same updated runtime.
Use `pi list` to find the managed checkout, then set `package_root` to that directory:

```zsh
herdr plugin link "$package_root/integrations/herdr" --enabled
```

The adapter scripts are already in that checkout.
Use their full paths or create personal links for `wf-herdr-open` and `wf-herdr-close`.
Inspect existing entries before replacing them.
This route does not require the standalone installer.
Reload Herdr's plugin configuration after package updates that change its manifest.

## Activate without Pi

Install Workfree and the adapter files through `scripts/install.zsh`.
Activation is separate from installation:

```zsh
herdr plugin link "$HOME/.local/share/workfree/herdr" --enabled
```

Run creation from an existing Herdr pane:

```zsh
wf-herdr-open feature/example --repo "$PWD" --allow-cleanup
```

Omit `--allow-cleanup` when the checkout must remain after its owners release it.
This creates a new allocation; it does not adopt existing worktrees.

Reopen a registered allocation after Close for now with its existing ID:

```zsh
wf-herdr-open --allocation ID
```

This mode inspects and retains the allocation without starting another task or changing cleanup permission.
It rejects creation options and labels the workspace with the checkout's current branch, or `detached:REV` for a detached HEAD.
Route managed closed-checkout picker choices through this mode, not plain `herdr worktree open`.
Leave unmanaged choices and focusing already-open workspaces unchanged.

You can assign these commands to your existing Herdr shortcuts:

- Creation: `wf-herdr-open` with the selected branch and repository.
- Closing: `wf-herdr-close` for an interactive menu.

Popup commands use Herdr's active workspace context when no pane identity is present. Ordinary pane commands use their own workspace identity.
The adapter does not change your keybindings or remove existing scripts during installation.

## Actions

```zsh
wf-herdr-close --close
wf-herdr-close --finish
wf-herdr-close --keep
```

Close for now closes the workspace and releases only workspace ownership.
Finish and close releases the task, closes the workspace, then releases workspace ownership.
Keep adds a pin and leaves the workspace open.

The plugin exposes the same actions in Herdr.
Its close-event hook also handles ordinary workspace closure.
A duplicate release is harmless.
If closing the workspace kills the popup before its final command, the server-side close-event hook can release that workspace owner.

## Your review flow

1. Open a managed checkout with the helper.
2. Work and open a pull request.
3. Review and merge on the web.
4. Ask follow-up questions in the existing workspace.
5. Choose Finish and close when that task is done.

Merging does not release an owner.
Follow-up questions therefore keep access to the checkout.
The final safe release can remove the checkout while the branch and committed result remain.
Any other owner or file-state blocker keeps it.

## Failures

Before every open, the helper retains a fresh provisional workspace owner.
After opening, it reads workspace metadata and reuses an existing owner for this allocation, including older `herdr-opening:ID` owners.
Otherwise it retains an owner combining the returned workspace ID with a fresh lifetime UUID.
Workspace IDs can repeat across servers or restarts; the UUID keeps those owners distinct.
It records the exact allocation and owner in metadata, then releases only this call's provisional owner.
Sequential opens of an already-open workspace reuse that mapping without accumulating owners.

Conflicting allocation metadata is rejected without overwriting it.
Concurrent first opens can both observe missing metadata and leave an extra owner because metadata writes are not compare-and-set.
Inspect ambiguous concurrent opens before releasing any unknown owner.

An ambiguous open, failed retain, or failed metadata operation preserves existing owners rather than guessing that no window exists.
Inspect the allocation and actual workspace before releasing such an owner.
The helper never finishes a task on failure or infers cleanup from a shell exiting.

A close event without managed metadata releases nothing.
An unmanaged workspace can close, but these helpers do not delete its checkout.
A server restart or missed event can leave ownership retained.
This version does not claim automatic replay of missed events.

Use `wf inspect` to see the exact retaining owner.
Release it only after confirming that the corresponding workspace no longer uses the checkout.
Do not use Herdr's force-removal route as a substitute for resolving ownership.
