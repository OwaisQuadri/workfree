import assert from "node:assert/strict";
import { execFile, spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { once } from "node:events";
import { access, cp, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test, type TestContext } from "node:test";
import { promisify } from "node:util";

const execute = promisify(execFile);

async function fixture(t: TestContext) {
  const root = await mkdtemp(join(tmpdir(), "wf-launcher-test-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const source = join(root, "managed package");
  const integration = join(source, "integrations", "pi");
  const tools = join(root, "tools");
  await mkdir(integration, { recursive: true });
  await mkdir(tools);
  for (const file of ["launcher.ts", "runtime.ts", "wf.zsh"]) await cp(new URL(file, import.meta.url), join(integration, file));
  await writeFile(join(source, "package.json"), JSON.stringify({ type: "module" }));
  await execute("git", ["init", "-q", source]);
  await execute("git", ["-C", source, "add", "."]);
  await execute("git", ["-C", source, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "launcher fixture"]);
  const revision = (await execute("git", ["-C", source, "rev-parse", "HEAD"])).stdout.trim();
  await symlink(process.execPath, join(tools, "node"));
  const entry = join(root, "linked-wf");
  await symlink(join(integration, "wf.zsh"), entry);
  const env = { ...process.env, HOME: root, PATH: `${tools}:/usr/bin:/bin`, WF_BIN: entry };
  await assert.rejects(access(join(source, "node_modules")));
  await assert.rejects(execute("which", ["wf"], { env }));
  const runtime = join(root, "Library", "Application Support", "workfree", "runtime");
  const binding = join(runtime, "revisions", `${process.platform}-${process.arch}`, `${revision}.json`);
  const publish = async (bytes: Buffer) => {
    const digest = createHash("sha256").update(bytes).digest("hex");
    const target = join(runtime, digest, "wf");
    await mkdir(dirname(target), { recursive: true, mode: 0o700 });
    await writeFile(target, bytes, { mode: 0o500 });
    await mkdir(dirname(binding), { recursive: true, mode: 0o700 });
    await writeFile(binding, JSON.stringify({ revision, platform: process.platform, architecture: process.arch, digest }), { mode: 0o400 });
  };
  const launch = (args: string[]) => spawn(entry, args, { cwd: tmpdir(), env, stdio: "pipe" });
  return { root, source, tools, entry, env, binding, publish, launch };
}

const bytes = Buffer.from(`#!${process.execPath}
const fs = require("node:fs");
const args = process.argv.slice(2);
if (args[0] === "signal") process.kill(process.pid, args[1]);
else if (args[0] === "wait") { process.stdout.write("ready\\n"); process.stdin.resume(); }
else {
  process.stdout.write(JSON.stringify(args) + "\\n");
  process.stderr.write("native stderr\\n");
  process.stdin.on("data", chunk => fs.writeSync(1, chunk));
  process.stdin.on("end", () => process.exit(23));
}
`);

test("linked launcher uses its own package without peers or global wf and preserves argv, stdin, stdout, stderr, and exit status", async (t) => {
  const f = await fixture(t);
  await f.publish(bytes);
  const args = ["transport", "", "a b", "single'quote", 'double"quote', "$HOME;*", "line\nbreak", "--", "-n", "سلام"];
  const input = Buffer.from("stdin\u0000bytes\nlast line");
  const child = f.launch(args);
  const output: Buffer[] = [];
  const errors: Buffer[] = [];
  child.stdout.on("data", (chunk) => output.push(chunk));
  child.stderr.on("data", (chunk) => errors.push(chunk));
  child.stdin.end(input);
  const [code, signal] = await once(child, "close");
  assert.equal(code, 23);
  assert.equal(signal, null);
  assert.deepEqual(Buffer.concat(output), Buffer.concat([Buffer.from(`${JSON.stringify(args)}\n`), input]));
  assert.equal(Buffer.concat(errors).toString(), "native stderr\n");
});

test("launcher preserves a native terminating signal rather than converting it to an exit code", async (t) => {
  const f = await fixture(t);
  await f.publish(bytes);
  const child = f.launch(["signal", "SIGINT"]);
  child.stdin.end();
  const [code, signal] = await once(child, "close");
  assert.equal(code, null);
  assert.equal(signal, "SIGINT");
});

test("signals sent to the linked launcher reach the executed process with the same process identity", async (t) => {
  const f = await fixture(t);
  await f.publish(bytes);
  const child = f.launch(["wait"]);
  t.after(() => { if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL"); });
  const [ready] = await once(child.stdout, "data");
  assert.equal(ready.toString(), "ready\n");
  child.kill("SIGTERM");
  const [code, signal] = await once(child, "close");
  assert.equal(code, null);
  assert.equal(signal, "SIGTERM");
});

test("launcher reports bootstrap errors without falling back to WF_BIN or a standalone executable", async (t) => {
  const f = await fixture(t);
  await writeFile(join(f.tools, "swift"), '#!/bin/zsh\nprint -u2 -- "launcher compiler failure"\nexit 7\n', { mode: 0o755 });
  await assert.rejects(execute(f.entry, ["--version"], { cwd: tmpdir(), env: f.env }), (error: unknown) => {
    const result = error as { code: number; stdout: string; stderr: string };
    assert.equal(result.code, 1);
    assert.equal(result.stdout, "");
    assert.match(result.stderr, /Workfree bootstrap failed \(swift\)/);
    assert.match(result.stderr, /launcher compiler failure/);
    return true;
  });
  await assert.rejects(access(f.binding));
  assert.equal((await readFile(join(f.source, "package.json"), "utf8")), '{"type":"module"}');
});
