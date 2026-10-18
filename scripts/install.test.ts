import assert from "node:assert/strict";
import { execFile, spawn } from "node:child_process";
import { access, cp, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout } from "node:timers/promises";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { test, type TestContext } from "node:test";

const exec = promisify(execFile);
const repository = fileURLToPath(new URL("../", import.meta.url));
const sentinel = "#!/bin/zsh\nprint unrelated-command\n";

async function fixture(t: TestContext, isGated = false) {
  const root = await mkdtemp(join(tmpdir(), "wf-install-test-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const source = join(root, "source");
  const caller = join(root, "caller");
  const tools = join(root, "tools");
  await mkdir(join(source, "scripts"), { recursive: true });
  await mkdir(caller);
  await mkdir(tools);
  for (const name of ["install.zsh", "publish-install.swift"]) {
    await cp(join(repository, "scripts", name), join(source, "scripts", name));
  }
  await cp(join(repository, "integrations"), join(source, "integrations"), { recursive: true });
  if (isGated) await exec("/usr/bin/mkfifo", [join(root, "resume")]);
  await writeFile(join(tools, "swift"), `#!/bin/zsh
set -euo pipefail
if [[ "$1" = build ]]; then
  if [[ "$*" = *--show-bin-path* ]]; then
    print -r -- "$WF_TEST_BUILD_DIR"
  elif [[ "$WF_TEST_GATE" = 1 ]]; then
    print entered > "$WF_TEST_ROOT/entered"
    IFS= read -r token < "$WF_TEST_ROOT/resume"
  fi
  exit 0
fi
exec /usr/bin/swift "$@"
`, { mode: 0o755 });
  const build = join(root, "build");
  await mkdir(build);
  await writeFile(join(build, "wf"), "#!/bin/zsh\nprint fixture-workfree\n", { mode: 0o755 });
  const env = { ...process.env, PATH: `${tools}:${process.env.PATH}`, WF_TEST_BUILD_DIR: build, WF_TEST_GATE: isGated ? "1" : "0", WF_TEST_ROOT: root };
  return { root, source, caller, env };
}

test("relative prefixes stay anchored to the caller and preserve unrelated source commands", async (t) => {
  const f = await fixture(t);
  const wrongTarget = join(f.source, "relative-target/bin/wf");
  await mkdir(join(f.source, "relative-target/bin"), { recursive: true });
  await writeFile(wrongTarget, sentinel, { mode: 0o755 });
  await exec("/bin/zsh", [join(f.source, "scripts/install.zsh"), "--prefix", "relative-target"], { cwd: f.caller, env: f.env });
  assert.equal(await readFile(wrongTarget, "utf8"), sentinel);
  await assert.rejects(access(join(f.caller, "relative-target/share/workfree/pi")));
  assert.deepEqual(await readFile(join(f.caller, "relative-target/bin/wf")), await readFile(join(f.env.WF_TEST_BUILD_DIR, "wf")));
});

for (const target of ["command", "resources"]) {
  test(`a concurrent ${target} target is preserved and partial command publication rolls back`, async (t) => {
    const f = await fixture(t, true);
    const prefix = join(f.root, "prefix");
    const child = spawn("/bin/zsh", [join(f.source, "scripts/install.zsh"), "--prefix", prefix], { cwd: f.caller, env: f.env });
    t.after(() => { child.kill(); });
    let output = "";
    child.stdout.on("data", (chunk) => { output += chunk; });
    child.stderr.on("data", (chunk) => { output += chunk; });
    const exit = new Promise<number | null>((resolve, reject) => { child.once("error", reject); child.once("exit", resolve); });
    const deadline = Date.now() + 20_000;
    while (true) {
      try { await access(join(f.root, "entered")); break; } catch {}
      assert.ok(Date.now() < deadline, "installer must reach its gated build");
      await setTimeout(20);
    }
    const collision = target === "command" ? join(prefix, "bin/wf") : join(prefix, "share/workfree/keep.txt");
    await mkdir(target === "command" ? join(prefix, "bin") : join(prefix, "share/workfree"), { recursive: true });
    await writeFile(collision, sentinel, { mode: 0o755 });
    await writeFile(join(f.root, "resume"), "resume\n");
    assert.equal(await exit, 1, output);
    assert.equal(await readFile(collision, "utf8"), sentinel);
    if (target === "resources") await assert.rejects(access(join(prefix, "bin/wf")));
    await assert.rejects(access(join(prefix, "bin/wf-herdr-open")));
    await assert.rejects(access(join(prefix, "bin/wf-herdr-close")));
  });
}
