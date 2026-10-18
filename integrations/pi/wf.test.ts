import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { join } from "node:path";
import { test } from "node:test";
import { pathToFileURL } from "node:url";

if (process.env.PI_PACKAGE_ROOT) {
  registerHooks({ resolve(specifier, context, next) {
    if (specifier === "@earendil-works/pi-ai") {
      return { url: pathToFileURL(join(process.env.PI_PACKAGE_ROOT!, "node_modules/@earendil-works/pi-ai/dist/index.js")).href, shortCircuit: true };
    }
    return next(specifier, context);
  } });
}
const { default: extension, argumentsFor } = await import("./wf.ts");

function fixture(isApproved = false) {
  let tool: any;
  const calls: string[][] = [];
  const commands = new Map<string, any>();
  const handlers = new Map<string, any>();
  const ctx = { cwd: "/repo", hasUI: true, ui: { confirm: async () => isApproved, notify: () => undefined } };
  const original = process.env.WF_BIN;
  process.env.WF_BIN = "/fixture/wf";
  try {
    extension({
      registerTool(definition: any) { tool = definition; },
      registerCommand(name: string, definition: any) { commands.set(name, definition); },
      on(name: string, handler: any) { handlers.set(name, handler); },
      async exec(_command: string, args: string[]) { calls.push(args); return { code: 0, stdout: '{"id":"allocation"}', stderr: "" }; },
    } as any);
  } finally {
    if (original === undefined) delete process.env.WF_BIN;
    else process.env.WF_BIN = original;
  }
  return { calls, commands, handlers, ctx, run: (input: any) => tool.execute("call", input, undefined, undefined, ctx) };
}

test("start defaults to no cleanup permission and passes arguments without shell interpolation", () => {
  assert.deepEqual(argumentsFor({ action: "start", branch: "feature/a;echo unsafe" }, "/repo with spaces"), ["--json", "start", "feature/a;echo unsafe", "--repo", "/repo with spaces"]);
  assert.ok(argumentsFor({ action: "start", branch: "feature/a", isCopyOnWriteRequired: true }, "/repo").includes("--require-cow"));
});

test("automatic cleanup permission requires affirmative operator confirmation", async () => {
  const denied = fixture();
  await assert.rejects(denied.run({ action: "start", branch: "feature/a", isCleanupAllowed: true }), /not authorized/);
  assert.deepEqual(denied.calls, []);
  const approved = fixture(true);
  await approved.run({ action: "start", branch: "feature/a", isCleanupAllowed: true });
  assert.ok(approved.calls[0].includes("--allow-cleanup"));
  approved.ctx.hasUI = false;
  await assert.rejects(approved.run({ action: "start", branch: "feature/b", isCleanupAllowed: true }), /not authorized/);
  assert.equal(approved.calls.length, 1);
});

test("finish, workspace release, and execution closure remain separate operations", async () => {
  const f = fixture();
  await f.run({ action: "finish", id: "allocation" });
  await f.run({ action: "release", id: "allocation", owner: "workspace" });
  await f.run({ action: "close-scope", id: "allocation", owner: "execution" });
  assert.deepEqual(f.calls, [["--json", "finish", "allocation"], ["--json", "release", "allocation", "--owner", "workspace"], ["--json", "close-scope", "allocation", "--owner", "execution"]]);
  assert.equal(f.handlers.size, 0);
});

test("malformed task and owner operations fail before invoking the executable", () => {
  assert.throws(() => argumentsFor({ action: "start" }, "/repo"), /branch/);
  assert.throws(() => argumentsFor({ action: "finish" }, "/repo"), /allocation id/);
  assert.throws(() => argumentsFor({ action: "release", id: "allocation" }, "/repo"), /owner/);
  assert.throws(() => argumentsFor({ action: "retain", id: "allocation", owner: "reader" }, "/repo"), /kind/);
  assert.throws(() => argumentsFor({ action: "entry-exit", id: "allocation", owner: "execution", status: 1.5 }, "/repo"), /integer/);
});

test("the Finish command cannot infer operator intent or override other owners", async () => {
  const denied = fixture();
  await denied.commands.get("wf-finish").handler("allocation", denied.ctx);
  assert.equal(denied.calls.length, 0);
  const approved = fixture(true);
  await approved.commands.get("wf-finish").handler("allocation", approved.ctx);
  assert.deepEqual(approved.calls, [["finish", "allocation"]]);
});
