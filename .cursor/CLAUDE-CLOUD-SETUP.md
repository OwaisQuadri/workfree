# Claude Code (cloud) setup for agent-hooks
- Environment variable: `PI_CONFIG_TOKEN` (read-only fine-grained PAT; runtime only).
- Setup script (token-free): `bash .cursor/cloud-bootstrap.sh install`
- Runtime: SessionStart hook in `.claude/settings.json` running `bash .cursor/cloud-bootstrap.sh start`.
  It fails loudly without `PI_CONFIG_TOKEN`, and repeat runs are cheap (unchanged repos are skipped).
- Guards installed by the first `start` apply from the next session (or after `/hooks` reload).
