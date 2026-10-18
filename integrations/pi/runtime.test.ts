import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { getEventListeners } from "node:events";
import { access, chmod, lstat, mkdir, mkdtemp, readFile, readdir, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test, type TestContext } from "node:test";
import { setTimeout } from "node:timers/promises";
import { promisify } from "node:util";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { createExecutableResolver } from "./runtime.ts";

const execute = promisify(execFile);
const bytes = Buffer.from("#!/bin/zsh\nprint revision-A\n");
const digest = createHash("sha256").update(bytes).digest("hex");

async function fixture(t: TestContext) {
  const root = await mkdtemp(join(tmpdir(), "wf-runtime-test-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const source = join(root, "package");
  const runtime = join(root, "state", "runtime");
  await mkdir(source);
  await execute("git", ["init", "-q", source]);
  await writeFile(join(source, "behavior"), bytes);
  const commit = async () => {
    await execute("git", ["-C", source, "add", "."]);
    await execute("git", ["-C", source, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture"]);
  };
  await commit();
  const revision = (await execute("git", ["-C", source, "rev-parse", "HEAD"])).stdout.trim();
  const binding = join(runtime, "revisions", `${process.platform}-${process.arch}`, `${revision}.json`);
  const calls: string[] = [];
  const workspaces: string[] = [];
  const attempts: string[] = [];
  const failures: Pick<Awaited<ReturnType<ExtensionAPI["exec"]>>, "code" | "killed">[] = [];
  const controls: {
    beforeBuild?: () => Promise<void>;
    binOutput?: (directory: string) => string;
    afterBuild?: (binary: string) => Promise<void>;
  } = {};
  const exec: ExtensionAPI["exec"] = async (command, args, options) => {
    assert.equal(options?.signal, undefined, "a caller must not own shared compilation cancellation");
    calls.push(command);
    if (command !== "swift") {
      if (command === "git" && args.includes("archive")) attempts.push(dirname(args.find((arg) => arg.startsWith("--output="))!.slice(9)));
      try {
        const result = await execute(command, args);
        return { ...result, code: 0, killed: false };
      } catch (error) {
        const result = error as { stdout: string; stderr: string };
        return { stdout: result.stdout, stderr: result.stderr, code: 1, killed: false };
      }
    }
    const scratch = args[args.indexOf("--scratch-path") + 1];
    const directory = join(scratch, "release");
    if (args.includes("--show-bin-path")) return { stdout: controls.binOutput?.(directory) ?? `${directory}\n`, stderr: "", code: 0, killed: false };
    assert.ok(args.includes("-warnings-as-errors"));
    workspaces.push(dirname(scratch));
    await controls.beforeBuild?.();
    const failure = failures.shift();
    if (failure) return { stdout: "", stderr: "fixture build failed", ...failure };
    const snapshot = args[args.indexOf("--package-path") + 1];
    await mkdir(directory, { recursive: true });
    const binary = join(directory, "wf");
    await writeFile(binary, await readFile(join(snapshot, "behavior")), { mode: 0o755 });
    await controls.afterBuild?.(binary);
    return { stdout: "", stderr: "", code: 0, killed: false };
  };
  const resolver = () => createExecutableResolver(exec, source, runtime);
  const assertClean = async () => {
    for (const workspace of attempts) await assert.rejects(access(workspace));
  };
  return { root, source, runtime, binding, calls, workspaces, controls, failures, commit, resolver, assertClean, target: join(runtime, digest, "wf") };
}

function gate() {
  let release!: () => void;
  const promise = new Promise<void>((resolve) => { release = resolve; });
  return { promise, release };
}

test("WF_BIN bypasses Git and build preparation without selecting an implicit global executable", async () => {
  const resolver = await createExecutableResolver((async () => { throw new Error("unexpected subprocess"); }) as ExtensionAPI["exec"], "/missing", "/missing", "operator-wf");
  assert.equal(await resolver(), "operator-wf");
});

test("registration captures identity without building and rejects a nested non-package root", async (t) => {
  const f = await fixture(t);
  await f.resolver();
  assert.deepEqual(f.calls, ["git", "git"]);
  const nested = join(f.source, "nested");
  await mkdir(nested);
  await assert.rejects(createExecutableResolver(async (command, args) => {
    const result = await execute(command, args);
    return { ...result, code: 0, killed: false };
  }, nested, f.runtime), /Git package root/);
});

test("coalesced first uses survive one cancelled waiter and remove abort listeners", async (t) => {
  const f = await fixture(t);
  const entered = gate();
  const resume = gate();
  f.controls.beforeBuild = async () => { entered.release(); await resume.promise; };
  const resolver = await f.resolver();
  const alreadyCancelled = new AbortController();
  alreadyCancelled.abort();
  await assert.rejects(resolver(alreadyCancelled.signal), { name: "AbortError" });
  assert.equal(f.workspaces.length, 0);
  const cancelled = new AbortController();
  const waiting = new AbortController();
  const first = resolver(cancelled.signal);
  const rejected = assert.rejects(first, { name: "AbortError" });
  const second = resolver(waiting.signal);
  await entered.promise;
  cancelled.abort();
  await rejected;
  assert.equal(getEventListeners(cancelled.signal, "abort").length, 0);
  resume.release();
  const path = await second;
  assert.equal(await resolver(), path);
  assert.equal(f.workspaces.length, 1);
  assert.equal(getEventListeners(waiting.signal, "abort").length, 0);
  await f.assertClean();
});

for (const failure of [{ code: 1, killed: false }, { code: 0, killed: true }]) {
  test(`a ${failure.killed ? "killed" : "failed"} Swift build rejects without fallback and retries on later use`, async (t) => {
    const f = await fixture(t);
    f.failures.push(failure);
    const resolver = await f.resolver();
    const waiting = new AbortController();
    await assert.rejects(resolver(waiting.signal), /bootstrap failed \(swift\)/);
    assert.equal(getEventListeners(waiting.signal, "abort").length, 0);
    await f.assertClean();
    assert.equal(await resolver(), f.target);
    assert.equal(f.workspaces.length, 2);
    assert.ok(f.calls.every((command) => ["git", "tar", "swift"].includes(command)));
    await f.assertClean();
  });
}

test("independent publishers isolate scratch output and expose only complete identical executable bytes", async (t) => {
  const f = await fixture(t);
  const entered = gate();
  const resume = gate();
  let arrivals = 0;
  f.controls.beforeBuild = async () => { if (++arrivals === 2) entered.release(); await resume.promise; };
  const first = await f.resolver();
  const second = await f.resolver();
  const attempts = Promise.all([first(), second()]);
  await entered.promise;
  assert.equal(new Set(f.workspaces).size, 2);
  assert.ok(f.workspaces.every((workspace) => !workspace.startsWith(f.source)));
  let isFinished = false;
  const observer = (async () => {
    while (!isFinished) {
      try { assert.deepEqual(await readFile(f.target), bytes); }
      catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; }
      await setTimeout(1);
    }
  })();
  resume.release();
  try { assert.deepEqual(await attempts, [f.target, f.target]); }
  finally { isFinished = true; await observer; }
  assert.deepEqual(await readFile(f.target), bytes);
  assert.equal((await lstat(f.target)).mode & 0o777, 0o500);
  assert.deepEqual(await readdir(dirname(f.target)), ["wf"]);
  await f.assertClean();
});

test("a failed attempt removes only its own workspace while another resolver is still building", async (t) => {
  const f = await fixture(t);
  const firstEntered = gate();
  const entered = gate();
  const resume = gate();
  let arrivals = 0;
  f.controls.beforeBuild = async () => {
    if (++arrivals === 1) { firstEntered.release(); await entered.promise; }
    else { entered.release(); await resume.promise; }
  };
  f.failures.push({ code: 1, killed: false });
  const first = await f.resolver();
  const second = await f.resolver();
  const rejected = assert.rejects(first(), /bootstrap failed/);
  await firstEntered.promise;
  const remaining = second();
  await rejected;
  await assert.rejects(access(f.workspaces[0]));
  await access(f.workspaces[1]);
  resume.release();
  assert.equal(await remaining, f.target);
  await f.assertClean();
});

for (const collision of ["corrupt", "writable", "symlink", "directory", "unsafe-runtime", "symlink-runtime", "unsafe-digest", "symlink-digest"] as const) {
  test(`a ${collision} publication collision is preserved without repair or fallback`, async (t) => {
    const f = await fixture(t);
    await mkdir(dirname(f.runtime), { recursive: true });
    const unrelated = join(f.root, "unrelated");
    await writeFile(unrelated, "preserve");
    if (collision === "symlink-runtime") await symlink(f.root, f.runtime);
    else {
      await mkdir(f.runtime, { mode: collision === "unsafe-runtime" ? 0o755 : 0o700 });
      if (collision === "symlink-digest") await symlink(f.root, dirname(f.target));
      else {
        await mkdir(dirname(f.target), { mode: collision === "unsafe-digest" ? 0o755 : 0o700 });
        if (collision === "symlink") await symlink(unrelated, f.target);
        else if (collision === "directory") await mkdir(f.target);
        else await writeFile(f.target, collision === "writable" ? bytes : "corrupt", { mode: collision === "writable" ? 0o700 : 0o500 });
      }
    }
    const protectedPath = collision.includes("runtime") ? f.runtime : collision.includes("digest") ? dirname(f.target) : f.target;
    const before = await lstat(protectedPath);
    const resolver = await f.resolver();
    await assert.rejects(resolver(), /[Uu]nsafe|does not match/);
    const after = await lstat(protectedPath);
    assert.equal(after.ino, before.ino);
    assert.equal(after.mode, before.mode);
    assert.equal(await readFile(unrelated, "utf8"), "preserve");
    if (collision === "corrupt") assert.equal(await readFile(f.target, "utf8"), "corrupt");
    if (collision === "writable") assert.deepEqual(await readFile(f.target), bytes);
    if (!collision.includes("runtime") && !collision.includes("digest")) assert.deepEqual(await readdir(dirname(f.target)), ["wf"]);
    await f.assertClean();
  });
}

test("existing registry directories need not adopt runtime permissions", async (t) => {
  const f = await fixture(t);
  await mkdir(dirname(f.runtime), { mode: 0o755 });
  const resolver = await f.resolver();
  await resolver();
  assert.equal((await lstat(dirname(f.runtime))).mode & 0o777, 0o755);
});

for (const malformed of ["multiline", "outside", "symlink", "not-executable"] as const) {
  test(`Swift ${malformed} output cannot escape workspace validation and leaves no runtime`, async (t) => {
    const f = await fixture(t);
    if (malformed === "multiline") f.controls.binOutput = (path) => `${path}\n\n`;
    if (malformed === "outside") {
      await writeFile(join(f.root, "wf"), bytes, { mode: 0o755 });
      f.controls.binOutput = () => f.root;
    }
    if (malformed === "symlink") f.controls.afterBuild = async (binary) => {
      await rm(binary);
      await symlink(join(f.root, "outside"), binary);
      await writeFile(join(f.root, "outside"), bytes, { mode: 0o755 });
    };
    if (malformed === "not-executable") f.controls.afterBuild = (binary) => chmod(binary, 0o600);
    const resolver = await f.resolver();
    await assert.rejects(resolver());
    await assert.rejects(access(f.runtime));
    await f.assertClean();
  });
}

test("repeated same-revision loads reuse one immutable product without rebuilding or disk growth", async (t) => {
  const f = await fixture(t);
  const path = await (await f.resolver())();
  const entries = await readdir(f.runtime);
  f.controls.beforeBuild = async () => { throw new Error("same revision rebuilt"); };
  for (let load = 0; load < 3; load++) assert.equal(await (await f.resolver())(), path);
  assert.equal(f.workspaces.length, 1);
  assert.deepEqual(await readdir(f.runtime), entries);
});

test("checkout advancement cannot rebind unresolved A and reloaded B does not replace resolved A", async (t) => {
  const f = await fixture(t);
  const unresolvedA = await f.resolver();
  const resolvedA = await f.resolver();
  const pathA = await resolvedA();
  await writeFile(join(f.source, "behavior"), "#!/bin/zsh\nprint revision-B\n");
  await f.commit();
  assert.equal(await unresolvedA(), pathA);
  assert.equal(f.workspaces.length, 1);
  const reloadedB = await f.resolver();
  const pathB = await reloadedB();
  assert.notEqual(pathB, pathA);
  assert.equal((await execute(pathA)).stdout.trim(), "revision-A");
  assert.equal((await execute(pathB)).stdout.trim(), "revision-B");
  assert.equal(await resolvedA(), pathA);
  assert.equal(await (await f.resolver())(), pathB);
  assert.equal(f.workspaces.length, 2);
  await f.assertClean();
});

test("missing captured Git objects fail instead of substituting current HEAD", async (t) => {
  const f = await fixture(t);
  const resolver = await f.resolver();
  await rm(join(f.source, ".git", "objects"), { recursive: true });
  await mkdir(join(f.source, ".git", "objects"));
  await assert.rejects(resolver(), /bootstrap failed \(git\)/);
  assert.equal(f.workspaces.length, 0);
  assert.ok(!f.calls.includes("swift"));
  await f.assertClean();
});

test("concurrent revision binding publishers converge even when valid builds have different digests", async (t) => {
  const f = await fixture(t);
  const entered = gate();
  const resume = gate();
  let arrivals = 0;
  f.controls.beforeBuild = async () => { if (++arrivals === 2) entered.release(); await resume.promise; };
  f.controls.afterBuild = async (binary) => {
    await writeFile(binary, `#!/bin/zsh\nprint build-${f.workspaces.indexOf(dirname(dirname(dirname(binary))))}\n`);
  };
  const first = await f.resolver();
  const second = await f.resolver();
  const pending = Promise.all([first(), second()]);
  await entered.promise;
  resume.release();
  const [pathA, pathB] = await pending;
  assert.equal(pathA, pathB);
  assert.equal(new Set(f.workspaces).size, 2);
  const products = (await readdir(f.runtime)).filter((name) => /^[a-f0-9]{64}$/.test(name));
  assert.equal(products.length, 2, "independent builds really produced distinct valid bytes");
  for (const product of products) {
    const path = join(f.runtime, product, "wf");
    assert.equal(createHash("sha256").update(await readFile(path)).digest("hex"), product);
  }
  f.controls.beforeBuild = async () => { throw new Error("published revision rebuilt"); };
  assert.equal(await (await f.resolver())(), pathA);
  assert.equal((await lstat(f.binding)).mode & 0o777, 0o400);
  assert.deepEqual(await readdir(dirname(f.binding)), [f.binding.split("/").at(-1)]);
  await f.assertClean();
});

test("a completed build publishes reusable bindings after every original waiter cancels", async (t) => {
  const f = await fixture(t);
  const entered = gate();
  const resume = gate();
  f.controls.beforeBuild = async () => { entered.release(); await resume.promise; };
  const resolver = await f.resolver();
  const controller = new AbortController();
  const rejected = assert.rejects(resolver(controller.signal), { name: "AbortError" });
  await entered.promise;
  controller.abort();
  await rejected;
  resume.release();
  const product = await resolver();
  assert.equal(await (await f.resolver())(), product);
  assert.equal(f.workspaces.length, 1);
});

for (const corruption of ["json", "revision", "platform", "architecture", "digest", "extra-field", "writable", "symlink", "directory", "unsafe-parent", "missing-product", "corrupt-product", "writable-product"] as const) {
  test(`a ${corruption} revision binding fails closed without rebuilding, replacing, or repairing data`, async (t) => {
    const f = await fixture(t);
    await (await f.resolver())();
    const binding = JSON.parse(await readFile(f.binding, "utf8"));
    if (["json", "revision", "platform", "architecture", "digest", "extra-field"].includes(corruption)) {
      if (corruption === "revision") binding.revision = "0".repeat(40);
      if (corruption === "platform") binding.platform = "other";
      if (corruption === "architecture") binding.architecture = "other";
      if (corruption === "digest") binding.digest = "../escape";
      if (corruption === "extra-field") binding.isUnrelated = true;
      await chmod(f.binding, 0o600);
      await writeFile(f.binding, corruption === "json" ? "not JSON" : JSON.stringify(binding));
      await chmod(f.binding, 0o400);
    }
    if (corruption === "writable") await chmod(f.binding, 0o600);
    if (corruption === "symlink" || corruption === "directory") {
      await rm(f.binding);
      if (corruption === "symlink") await symlink(f.target, f.binding);
      else await mkdir(f.binding);
    }
    if (corruption === "unsafe-parent") await chmod(dirname(f.binding), 0o755);
    if (corruption === "missing-product") await rm(f.target);
    if (corruption === "corrupt-product") {
      await chmod(f.target, 0o700);
      await writeFile(f.target, "corrupt");
      await chmod(f.target, 0o500);
    }
    if (corruption === "writable-product") await chmod(f.target, 0o700);
    const before = await lstat(f.binding);
    const contents = before.isFile() ? await readFile(f.binding) : undefined;
    await assert.rejects((await f.resolver())());
    assert.equal(f.workspaces.length, 1);
    assert.equal((await lstat(f.binding)).ino, before.ino);
    assert.equal((await lstat(f.binding)).mode, before.mode);
    if (contents) assert.deepEqual(await readFile(f.binding), contents);
    if (corruption === "corrupt-product") assert.equal(await readFile(f.target, "utf8"), "corrupt");
  });
}

test("a corrupt binding that appears during compilation is preserved and rejects publication", async (t) => {
  const f = await fixture(t);
  const entered = gate();
  const resume = gate();
  f.controls.beforeBuild = async () => { entered.release(); await resume.promise; };
  const resolver = await f.resolver();
  const rejected = assert.rejects(resolver(), /JSON/);
  await entered.promise;
  await mkdir(dirname(f.binding), { recursive: true, mode: 0o700 });
  await writeFile(f.binding, "preserve", { mode: 0o400 });
  resume.release();
  await rejected;
  assert.equal(await readFile(f.binding, "utf8"), "preserve");
  assert.deepEqual(await readdir(dirname(f.binding)), [f.binding.split("/").at(-1)]);
  await f.assertClean();
});
