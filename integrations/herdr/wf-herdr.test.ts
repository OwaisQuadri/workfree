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
if [[ "$2" = retain ]]; then
  [[ "\${TEST_RETAIN_FAIL:-}" != "$5" && "\${TEST_RETAIN_FAIL:-}" != all ]] || exit 1
  if [[ -f "$TEST_LOG.retired" ]] && grep -Fx -- "$5" "$TEST_LOG.retired" >/dev/null; then exit 1; fi
elif [[ "$2" = release ]]; then
  print -r -- "$5" >> "$TEST_LOG.retired"
fi
case "$2" in
  start|inspect)
    if [[ -n "\${TEST_ALLOCATION:-}" ]]; then
      print -r -- "$TEST_ALLOCATION"
    else
      printf '{"id":"allocation","path":"%s","repository":"/tmp"}\\n' "\${TEST_CHECKOUT:-/checkout}"
    fi ;;
  *) print -r -- '{"id":"allocation","phase":"retained"}' ;;
esac
`, { mode: 0o700 });
  await writeFile(herdr, `#!/bin/zsh
print -r -- "herdr $*" >> "$TEST_LOG"
metadata_file=\${TEST_METADATA:-$TEST_LOG.metadata}
if [[ "$1 $2" = 'worktree open' ]]; then
  [[ "\${TEST_OPEN_FAIL:-}" != 1 ]] || exit 1
  [[ "\${TEST_OPEN_UNCERTAIN:-}" != 1 ]] || { print '{}'; exit 0; }
  printf '{"result":{"workspace":{"workspace_id":"%s"}}}\\n' "\${TEST_WORKSPACE:-w-test}"
elif [[ "$1 $2" = 'workspace get' ]]; then
  [[ "\${TEST_METADATA_GET_FAIL:-}" != 1 ]] || exit 1
  if [[ -f "$metadata_file" ]]; then
    cat "$metadata_file"
  elif [[ "\${TEST_CONFLICT:-}" = 1 ]]; then
    print -r -- '{"result":{"workspace":{"tokens":{"wf_id":"other","wf_owner":"other-owner"}}}}'
  elif [[ "\${TEST_UNMANAGED:-}" = 1 ]]; then
    print -r -- '{"result":{"workspace":{}}}'
  else
    print -r -- '{"result":{"workspace":{"tokens":{"wf_id":"allocation","wf_owner":"owner"}}}}'
  fi
elif [[ "$1 $2" = 'workspace report-metadata' ]]; then
  [[ "\${TEST_METADATA_WRITE_FAIL:-}" != 1 ]] || exit 1
  printf '{"result":{"workspace":{"tokens":{"wf_id":"%s","wf_owner":"%s"}}}}\\n' "\${7#wf_id=}" "\${9#wf_owner=}" > "$metadata_file"
elif [[ "$1 $2" = 'workspace close' ]]; then
  rm -f "$metadata_file"
else
  print -r -- '{"result":{}}'
fi
`, { mode: 0o700 });
  const env = { ...process.env, HERDR_ENV: "1", HERDR_WORKSPACE_ID: "w-test", WF_BIN: provider, HERDR_BIN: herdr, TEST_LOG: log };
  return { root, log, env, calls: async () => (await readFile(log, "utf8")).trim().split("\n") };
}

test("workspace ownership exists before Herdr exposes a new checkout", async (t) => {
  const f = await fixture(t);
  await exec("/bin/zsh", [openScript, "feature/a", "--repo", "/source", "--allow-cleanup"], { env: { ...f.env, TEST_UNMANAGED: "1" } });
  const calls = await f.calls();
  assert.match(calls[0], /start feature\/a --repo \/source --allow-cleanup/);
  assert.match(calls[1], /retain allocation --owner herdr-opening:[A-F0-9-]{36} --kind workspace/);
  assert.equal(calls[2], "herdr worktree open --cwd /tmp --path /checkout --label feature/a --focus");
  assert.equal(calls[3], "herdr workspace get w-test");
  const owner = activeWorkspaceOwners(calls)[0];
  assert.match(owner, /^herdr-workspace:w-test:[A-F0-9-]{36}$/);
  assert.ok(calls[4].includes(`retain allocation --owner ${owner} --kind workspace`));
  assert.ok(calls[5].includes(`report-metadata w-test --source wf --token wf_id=allocation --token wf_owner=${owner}`));
  assert.equal(calls[6], calls[1].replace(/retain/, "release").replace(/ --kind workspace.*$/, ""));
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

async function checkout(f: Awaited<ReturnType<typeof fixture>>) {
  const directory = join(f.root, "checkout");
  await exec("git", ["init", "-b", "feature/actual", directory]);
  return { ...f.env, TEST_CHECKOUT: directory };
}

function activeWorkspaceOwners(calls: string[]) {
  const owners = new Set<string>();
  for (const call of calls) {
    const retained = / retain allocation --owner (\S+)/.exec(call);
    const released = / release allocation --owner (\S+)/.exec(call);
    if (retained) owners.add(retained[1]);
    if (released) owners.delete(released[1]);
  }
  return [...owners];
}

test("reopening inspects the allocation and actual branch without creating a task or changing permission", async (t) => {
  const f = await fixture(t);
  const env = await checkout(f);
  await exec("/bin/zsh", [openScript, "--allocation", "allocation"], { env });
  const calls = await f.calls();
  assert.equal(calls[0], "wf --json inspect allocation");
  assert.ok(calls.some((call) => call.includes("--label feature/actual --focus")));
  assert.equal(calls.some((call) => / start |allow-cleanup|require-cow| finish /.test(call)), false);
  for (const option of ["--repo", "--base", "--path", "--allow-cleanup", "--require-cow"]) {
    await assert.rejects(exec("/bin/zsh", [openScript, "--allocation", "allocation", option, "value"], { env }));
  }
  assert.deepEqual(await f.calls(), calls);
  await exec("git", ["-C", env.TEST_CHECKOUT, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "fixture"]);
  await exec("git", ["-C", env.TEST_CHECKOUT, "checkout", "--detach"]);
  await exec("/bin/zsh", [openScript, "--allocation", "allocation"], { env });
  assert.ok((await f.calls()).some((call) => /--label detached:[a-f0-9]+ --focus/.test(call)));
});

test("focusing a managed workspace keeps its existing owner, including legacy opening tokens", async (t) => {
  const f = await fixture(t);
  const env = await checkout(f);
  const owner = "herdr-opening:allocation";
  const allocation = { id: "allocation", path: env.TEST_CHECKOUT, repository: "/tmp", owners: { [owner]: { kind: "workspace", label: "" } } };
  await writeFile(`${f.log}.metadata`, JSON.stringify({ result: { workspace: { tokens: { wf_id: "allocation", wf_owner: owner } } } }));
  for (let attempt = 0; attempt < 2; attempt++) {
    await exec("/bin/zsh", [openScript, "--allocation", "allocation"], { env: { ...env, TEST_ALLOCATION: JSON.stringify(allocation) } });
  }
  assert.ok((await f.calls()).some((call) => call.endsWith(`--owner ${owner} --kind workspace --label `)));
  assert.deepEqual(activeWorkspaceOwners(await f.calls()), [owner]);
  assert.ok((await readFile(`${f.log}.metadata`, "utf8")).includes(owner));
});

test("focusing another allocation's workspace never overwrites metadata or releases protection", async (t) => {
  const f = await fixture(t);
  const env = { ...await checkout(f), TEST_CONFLICT: "1" };
  await assert.rejects(exec("/bin/zsh", [openScript, "--allocation", "allocation"], { env }));
  const calls = await f.calls();
  assert.equal(calls.some((call) => /report-metadata| release | finish /.test(call)), false);
  assert.equal(activeWorkspaceOwners(calls).length, 1);
});

test("sequential close and reopen uses fresh owners instead of retired opening tokens", async (t) => {
  const f = await fixture(t);
  const env = { ...await checkout(f), TEST_UNMANAGED: "1" };
  await exec("/bin/zsh", [openScript, "--allocation", "allocation"], { env });
  await exec("/bin/zsh", [openScript, "--allocation", "allocation"], { env });
  const firstOwner = activeWorkspaceOwners(await f.calls());
  assert.equal(firstOwner.length, 1);
  await exec("/bin/zsh", [closeScript, "--close"], { env });
  await exec("/bin/zsh", [openScript, "--allocation", "allocation"], { env: { ...env, TEST_WORKSPACE: "w-reopened" } });
  const calls = await f.calls();
  const owners = activeWorkspaceOwners(calls);
  assert.equal(owners.length, 1);
  assert.match(owners[0], /^herdr-workspace:w-reopened:[A-F0-9-]{36}$/);
  assert.notEqual(owners[0], firstOwner[0]);
  const provisional = calls.filter((call) => / retain .*herdr-opening:/.test(call));
  assert.equal(new Set(provisional).size, 3);
  assert.equal(calls.some((call) => / start | finish /.test(call)), false);
});

test("failed initial retain never opens a path; failed final retain preserves provisional protection", async (t) => {
  const f = await fixture(t);
  const env = await checkout(f);
  await assert.rejects(exec("/bin/zsh", [openScript, "--allocation", "allocation"], { env: { ...env, TEST_RETAIN_FAIL: "all" } }));
  assert.equal((await f.calls()).some((call) => call.startsWith("herdr ")), false);
  await writeFile(f.log, "");
  await assert.rejects(exec("/bin/zsh", [openScript, "--allocation", "allocation"], { env: { ...env, TEST_RETAIN_FAIL: "owner" } }));
  assert.equal((await f.calls()).some((call) => /report-metadata| release | finish /.test(call)), false);
});

test("uncertain open and metadata failures never release protective owners or finish the task", async (t) => {
  const f = await fixture(t);
  const env = await checkout(f);
  for (const failure of ["TEST_OPEN_UNCERTAIN", "TEST_METADATA_GET_FAIL", "TEST_METADATA_WRITE_FAIL"]) {
    await writeFile(f.log, "");
    await assert.rejects(exec("/bin/zsh", [openScript, "--allocation", "allocation"], { env: { ...env, [failure]: "1" } }));
    const calls = await f.calls();
    assert.match(calls[1], /retain allocation --owner herdr-opening:/);
    assert.equal(calls.some((call) => / release | finish /.test(call)), false);
  }
});

test("independent servers and reused workspace IDs cannot release another lifetime's owner", async (t) => {
  const f = await fixture(t);
  const env = { ...await checkout(f), TEST_UNMANAGED: "1" };
  const first = { ...env, TEST_METADATA: join(f.root, "server-one") };
  const second = { ...env, TEST_METADATA: join(f.root, "server-two") };
  await exec("/bin/zsh", [openScript, "--allocation", "allocation"], { env: first });
  const firstOwner = activeWorkspaceOwners(await f.calls())[0];
  await exec("/bin/zsh", [openScript, "--allocation", "allocation"], { env: second });
  assert.equal(activeWorkspaceOwners(await f.calls()).length, 2);
  await exec("/bin/zsh", [closeScript, "--close"], { env: second });
  assert.deepEqual(activeWorkspaceOwners(await f.calls()), [firstOwner]);
  await rm(first.TEST_METADATA);
  await exec("/bin/zsh", [openScript, "--allocation", "allocation"], { env: first });
  const owners = activeWorkspaceOwners(await f.calls());
  assert.equal(owners.length, 2);
  assert.ok(owners.includes(firstOwner));
  await exec("/bin/zsh", [closeScript, "--close"], { env: first });
  assert.deepEqual(activeWorkspaceOwners(await f.calls()), [firstOwner]);
});
