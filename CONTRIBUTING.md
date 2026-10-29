# Contributing

Read [the safety contract](docs/safety.md) before changing ownership or cleanup behavior.
Keep the core independent of agent and workspace applications.
Adapters must use the executable's registry rather than maintain independent ownership state.

## Checks

Requirements: macOS, Swift, Git, and Node.js for adapter tests.
Provider-specific copy-on-write checks also require `simgit` and filesystem support.
The optional Herdr adapter tests also require `jq` and Z shell.

```zsh
npm ci --ignore-scripts --no-audit --no-fund
./scripts/check.zsh
```

Pi supplies its host packages when it loads an extension.
The development install provides the peer dependencies and compiler for the adapter checks.
For adapter tests alone, `PI_PACKAGE_ROOT` can point to an existing Pi installation.
The tests never require a model call or a live personal workspace.

Integration tests must use disposable repositories and a separate state directory.
Never test deletion against an existing user checkout.
A missing required filesystem capability is a blocked test, not permission to use an ordinary checkout silently.

## Changes

Use focused changes and preserve the existing command contract.
Add direct tests for a concrete regression or safety-critical transition.
Keep Boolean names prefixed with `is`.
Do not add ordinary code comments; use clear names and small functions.
Promote warnings to errors.

Do not weaken a blocked cleanup into deletion for convenience.
New deletion authority requires explicit operator setup or an allocation grant and a negative test for missing permission. Standing policy is creation-time authority unless the operator explicitly migrates existing eligible allocations. Sweep-time backfill and model self-authorization remain forbidden. Global policy must respect repository exclusions and preserve recorded revocations during migration. Cover generation provenance, atomic revocation rollback, pending removal, repository replacement, and monotonic registry versioning when changing it. Use a verified version-2 binary through `WORKFREE_V2_EXECUTABLE` for the old-reader rejection fixture; report a missing binary as a skipped compatibility check. Startup and timer cleanup must remain dialog-free under saved authority.
Check path aliases, missing paths, retained Git registrations, and allocation replacement when changing identity checks.
Check retries, concurrent ownership, and interrupted removal when changing persistence.

A process exiting is not proof that its execution scope ended.
Do not add age-based ownership expiry or infer task completion from pull request status.

## Evidence

A passing report names the exact source state and the checks that ran on it.
Keep command output separate from expected results.
Document platform limits without claiming untested support.
Do not commit private machine paths, network identifiers, credentials, or disposable fixture logs.

Interface changes need evidence from the actual interface, not a mock screenshot or a prose reconstruction.
An independent reviewer must inspect the applicable evidence before the change is reported ready.
