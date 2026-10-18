import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

const exec = promisify(execFile);
const openScript = fileURLToPath(new URL("./wf-herdr-open.zsh", import.meta.url));
const closeScript = fileURLToPath(new URL("./wf-herdr-close.zsh", import.meta.url));
const eventScript = fileURLToPath(new URL("./wf-herdr-event.zsh", import.meta.url));
async function fixture(t: any) {
  const root = await mkdtemp(join(tmpdir(), "wf-herdr-test-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const log = join(root, "calls");
  const provider = join(root, "wf");
  const herdr = join(root, "herdr");
  await writeFile(provider, `#!/bin/zsh
print -r -- "wf $*" >> "$TEST_LOG"
case "$*" in
  *start*|*inspect*) print -r -- '{"id":"allocation","path":"/checkout","repository":"/tmp"}' ;;
  *) print -r -- '{"id":"allocation","phase":"retained"}' ;;
esac
`, { mode: 0o700 });
  await writeFile(herdr, `#!/bin/zsh
print -r -- "herdr $*" >> "$TEST_LOG"
if [[ "$1 $2" = 'worktree open' ]]; then
  [[ "\${TEST_OPEN_FAIL:-}" != 1 ]] || exit 1
  print -r -- '{"result":{"workspace":{"workspace_id":"w-test"}}}'
elif [[ "$1 $2" = 'workspace get' ]]; then
  if [[ "\${TEST_UNMANAGED:-}" = 1 ]]; then
    print -r -- '{"result":{"workspace":{"tokens":{}}}}'
  else
    print -r -- '{"result":{"workspace":{"tokens":{"wf_id":"allocation","wf_owner":"owner"}}}}'
  fi
else
  print -r -- '{"result":{}}'
fi
`, { mode: 0o700 });
  const env = { ...process.env, HERDR_ENV: "1", HERDR_WORKSPACE_ID: "w-test", WF_BIN: provider, HERDR_BIN: herdr, TEST_LOG: log };
  return { root, log, env, calls: async () => (await readFile(log, "utf8")).trim().split("\n") };
}

test("workspace ownership exists before Herdr exposes a new checkout", async (t) => {
  const f = await fixture(t);
  await exec("/bin/zsh", [openScript, "feature/a", "--repo", "/source", "--allow-cleanup"], { env: f.env });
  const calls = await f.calls();
  assert.match(calls[0], /start feature\/a --repo \/source --allow-cleanup/);
  assert.match(calls[1], /retain allocation --owner herdr-opening:allocation --kind workspace/);
  assert.equal(calls[2], "herdr worktree open --cwd /tmp --path /checkout --label feature/a --focus");
  assert.match(calls[3], /report-metadata w-test.*wf_id=allocation.*wf_owner=herdr-opening:allocation/);
});

test("an ambiguous Herdr open failure preserves task and workspace owners", async (t) => {
  const f = await fixture(t);
  await assert.rejects(exec("/bin/zsh", [openScript, "feature/a"], { env: { ...f.env, TEST_OPEN_FAIL: "1" } }));
  assert.equal((await f.calls()).some((line) => / release | finish /.test(line)), false);
});

test("Finish precedes close; workspace ownership releases only after successful close", async (t) => {
  const f = await fixture(t);
  await exec("/bin/zsh", [closeScript, "--finish"], { env: f.env });
  const calls = await f.calls();
  const finish = calls.findIndex((line) => line.includes(" finish "));
  const close = calls.findIndex((line) => line === "herdr workspace close w-test");
  const release = calls.findIndex((line) => line.includes(" release "));
  assert.ok(finish >= 0 && finish < close && close < release);
});

test("Close for now preserves the task; Keep does not close the workspace", async (t) => {
  const f = await fixture(t);
  await exec("/bin/zsh", [closeScript, "--close"], { env: f.env });
  assert.equal((await f.calls()).some((line) => line.includes(" finish ")), false);
  await writeFile(f.log, "");
  await exec("/bin/zsh", [closeScript, "--keep"], { env: f.env });
  const calls = await f.calls();
  assert.equal(calls.some((line) => line.includes(" keep ")), true);
  assert.equal(calls.some((line) => line.includes("workspace close") || line.includes(" release ")), false);
});

test("unmanaged workspaces can close but cannot enter automatic cleanup", async (t) => {
  const f = await fixture(t);
  const env = { ...f.env, TEST_UNMANAGED: "1" };
  await assert.rejects(exec("/bin/zsh", [closeScript, "--finish"], { env }));
  await exec("/bin/zsh", [closeScript, "--close"], { env });
  assert.equal((await f.calls()).some((line) => line.startsWith("wf ")), false);
});

test("a native close event releases only its exact workspace owner", async (t) => {
  const f = await fixture(t);
  const payload = JSON.stringify({ data: { workspace: { tokens: { wf_id: "allocation", wf_owner: "owner" } } } });
  await exec("/bin/zsh", [eventScript], { env: { ...f.env, HERDR_PLUGIN_EVENT: "workspace.closed", HERDR_PLUGIN_EVENT_JSON: payload } });
  const calls = await f.calls();
  assert.deepEqual(calls, ["wf --json inspect allocation", "wf --json release allocation --owner owner"]);
});
