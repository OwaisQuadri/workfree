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

async function fixture(isApproved = false) {
  let tool: any;
  const calls: string[][] = [];
  const rawCalls: string[][] = [];
  const entries: any[] = [];
  const failures: Error[] = [];
  const executables: string[] = [];
  const result = { code: 0, killed: false, stdout: '{"id":"allocation"}', stderr: "" };
  const commands = new Map<string, any>();
  const handlers = new Map<string, any>();
  const ctx = {
    cwd: "/repo", hasUI: true,
    sessionManager: { getSessionId: () => "conversation", getEntries: () => entries },
    ui: { confirm: async () => isApproved, notify: () => undefined },
  };
  const original = process.env.WF_BIN;
  process.env.WF_BIN = "/fixture/wf";
  try {
    await extension({
      registerTool(definition: any) { tool = definition; },
      registerCommand(name: string, definition: any) { commands.set(name, definition); },
      on(name: string, handler: any) { handlers.set(name, handler); },
      appendEntry(customType: string, data: unknown) { entries.push({ type: "custom", customType, data }); },
      async exec(command: string, args: string[]) {
        executables.push(command); rawCalls.push(args); calls.push(args.slice(8));
        if (failures.length) throw failures.shift();
        return result;
      },
    } as any);
  } finally {
    if (original === undefined) delete process.env.WF_BIN;
    else process.env.WF_BIN = original;
  }
  return { calls, rawCalls, entries, failures, executables, result, commands, handlers, ctx, run: (input: any) => tool.execute("call", input, undefined, undefined, ctx) };
}

test("start defaults to no cleanup permission and passes arguments without shell interpolation", () => {
  assert.deepEqual(argumentsFor({ action: "start", branch: "feature/a;echo unsafe" }, "/repo with spaces"), ["--json", "start", "feature/a;echo unsafe", "--repo", "/repo with spaces"]);
  assert.ok(argumentsFor({ action: "start", branch: "feature/a", isCopyOnWriteRequired: true }, "/repo").includes("--require-cow"));
});

test("automatic cleanup permission requires affirmative operator confirmation", async () => {
  const denied = await fixture();
  await assert.rejects(denied.run({ action: "start", branch: "feature/a", isCleanupAllowed: true }), /not authorized/);
  assert.deepEqual(denied.calls, []);
  const approved = await fixture(true);
  await approved.run({ action: "start", branch: "feature/a", isCleanupAllowed: true });
  assert.ok(approved.calls[0].includes("--allow-cleanup"));
  approved.ctx.hasUI = false;
  await assert.rejects(approved.run({ action: "start", branch: "feature/b", isCleanupAllowed: true }), /not authorized/);
  assert.equal(approved.calls.length, 1);
});

test("finish, workspace release, and execution closure remain separate operations", async () => {
  const f = await fixture();
  await f.run({ action: "finish", id: "allocation" });
  await f.run({ action: "release", id: "allocation", owner: "workspace" });
  await f.run({ action: "close-scope", id: "allocation", owner: "execution" });
  assert.deepEqual(f.calls, [["--json", "finish", "allocation"], ["--json", "release", "allocation", "--owner", "workspace"], ["--json", "close-scope", "allocation", "--owner", "execution"]]);
  assert.deepEqual([...f.handlers.keys()], ["session_start", "session_shutdown"]);
});

test("tools and commands share the captured override and reject killed CLI results", async () => {
  const f = await fixture(true);
  await f.run({ action: "list" });
  await f.commands.get("wf").handler("", f.ctx);
  await f.commands.get("wf-finish").handler("allocation", f.ctx);
  assert.deepEqual(f.executables, ["/fixture/wf", "/fixture/wf", "/fixture/wf"]);
  f.result.killed = true;
  await assert.rejects(f.run({ action: "list" }));
});

test("malformed task and owner operations fail before invoking the executable", () => {
  assert.throws(() => argumentsFor({ action: "start" }, "/repo"), /branch/);
  assert.throws(() => argumentsFor({ action: "finish" }, "/repo"), /allocation id/);
  assert.throws(() => argumentsFor({ action: "release", id: "allocation" }, "/repo"), /owner/);
  assert.throws(() => argumentsFor({ action: "retain", id: "allocation", owner: "reader" }, "/repo"), /kind/);
  assert.throws(() => argumentsFor({ action: "entry-exit", id: "allocation", owner: "execution", status: 1.5 }, "/repo"), /integer/);
});

test("recoverable policy requires confirmation and cannot grant itself permission through a sweep", async () => {
  const denied = await fixture();
  await assert.rejects(denied.run({ action: "authorize-cleanup", id: "allocation" }), /not authorized/);
  assert.deepEqual(denied.calls, []);
  const approved = await fixture(true);
  await approved.run({ action: "authorize-cleanup", id: "allocation", graceSeconds: 120, disposablePath: ".build" });
  assert.deepEqual(approved.calls, [["--json", "authorize-cleanup", "allocation", "--grace-seconds", "120", "--disposable-path", ".build"]]);
  approved.ctx.hasUI = false;
  await assert.rejects(approved.run({ action: "authorize-cleanup", id: "allocation" }), /not authorized/);
  await approved.run({ action: "sweep" });
  assert.deepEqual(approved.calls.at(-1), ["--json", "sweep"]);
});

test("multiple generated roots reach the CLI without changing single-path compatibility", async () => {
  const f = await fixture(true);
  await f.run({ action: "authorize-cleanup", id: "allocation", disposablePaths: [".build", "node_modules"] });
  assert.deepEqual(f.calls, [[
    "--json", "authorize-cleanup", "allocation", "--disposable-path", ".build", "--disposable-path", "node_modules",
  ]]);
  assert.throws(() => argumentsFor({ action: "sweep", disposablePaths: [".build"] }, "/repo"), /only/);
});

test("session startup evaluates saved policies and shutdown clears its sweep timer", async () => {
  const f = await fixture();
  await f.handlers.get("session_start")({}, f.ctx);
  assert.deepEqual(f.calls, [["--json", "claim"], ["--json", "sweep"]]);
  assert.deepEqual(f.rawCalls[0].slice(0, 8), [
    "--session-id", "conversation", "--session-pid", String(process.pid),
    "--session-cwd", "/repo", "--session-allocations", "[]",
  ]);
  await f.handlers.get("session_shutdown")({}, f.ctx);
});

test("startup never sweeps when conversation acquisition fails", async () => {
  const f = await fixture();
  f.result.code = 1;
  f.result.stderr = "Allocation is unavailable";
  await assert.rejects(f.handlers.get("session_start")({}, f.ctx), /unavailable/);
  assert.ok(f.calls.every((args) => !args.includes("sweep")));
});

test("acquired allocations persist outside transcript text and rebind on reload", async () => {
  const f = await fixture();
  f.entries.push({ type: "message", message: { text: "do not infer /private/other-allocation" } });
  f.result.stdout = JSON.stringify({
    id: "outside-cwd", conversationClaims: [{ sessionID: "conversation", processID: process.pid }],
  });
  await f.run({ action: "inspect", id: "outside-cwd" });
  assert.deepEqual(f.entries.at(-1), {
    type: "custom", customType: "workfree-conversation-allocations", data: ["outside-cwd"],
  });
  await f.handlers.get("session_shutdown")({}, f.ctx);
  await f.handlers.get("session_start")({}, f.ctx);
  assert.equal(f.rawCalls[1][7], '["outside-cwd"]');
  assert.deepEqual(f.calls.slice(1), [["--json", "claim"], ["--json", "sweep"]]);
  await f.handlers.get("session_shutdown")({}, f.ctx);
});

test("interrupted structured commands reconcile acquired targets before reporting failure", async () => {
  const f = await fixture();
  f.failures.push(new Error("interrupted after acquisition"));
  f.result.stdout = JSON.stringify([{
    id: "acquired-before-error", conversationClaims: [{ sessionID: "conversation", processID: process.pid }],
  }]);
  await assert.rejects(f.run({ action: "inspect", id: "acquired-before-error" }), /interrupted after acquisition/);
  assert.deepEqual(f.calls, [["--json", "inspect", "acquired-before-error"], ["--json", "claim"]]);
  assert.deepEqual(f.entries.at(-1).data, ["acquired-before-error"]);
});

test("malformed non-transcript metadata blocks cleanup instead of dropping protection", async () => {
  const f = await fixture();
  f.entries.push({ type: "custom", customType: "workfree-conversation-allocations", data: [123] });
  await assert.rejects(f.handlers.get("session_start")({}, f.ctx), /metadata/);
  assert.equal(f.calls.length, 0);
});

test("the Finish command cannot infer operator intent or override other owners", async () => {
  const denied = await fixture();
  await denied.commands.get("wf-finish").handler("allocation", denied.ctx);
  assert.equal(denied.calls.length, 0);
  const approved = await fixture(true);
  await approved.commands.get("wf-finish").handler("allocation", approved.ctx);
  assert.deepEqual(approved.calls, [["--json", "finish", "allocation"]]);
});
