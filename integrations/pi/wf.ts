import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "@earendil-works/pi-ai";
import { homedir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { createExecutableResolver } from "./runtime.ts";

const actions = ["start", "inspect", "list", "status", "retain", "release", "finish", "keep", "unkeep", "close-scope", "entry-exit", "recover", "authorize-cleanup", "revoke-cleanup", "preview", "sweep", "restore"] as const;

export function argumentsFor(input: {
  action: typeof actions[number];
  id?: string;
  branch?: string;
  repo?: string;
  owner?: string;
  kind?: "task" | "workspace" | "execution" | "pin";
  label?: string;
  status?: number;
  isCleanupAllowed?: boolean;
  isCopyOnWriteRequired?: boolean;
  since?: string;
  graceSeconds?: number;
  disposablePath?: string;
}, cwd: string): string[] {
  const args: string[] = [input.action];
  if (input.action === "start") {
    if (!input.branch) throw new Error("start requires a branch");
    args.push(input.branch, "--repo", input.repo ?? cwd);
    if (input.isCleanupAllowed) args.push("--allow-cleanup");
    if (input.isCopyOnWriteRequired) args.push("--require-cow");
  } else if (!["list", "status", "preview", "sweep"].includes(input.action)) {
    if (!input.id) throw new Error(`${input.action} requires an allocation id`);
    args.push(input.id);
  }
  if (["retain", "release", "close-scope", "entry-exit"].includes(input.action) && !input.owner) {
    throw new Error(`${input.action} requires an owner`);
  }
  if (input.owner) args.push("--owner", input.owner);
  if (input.action === "retain") {
    if (!input.kind) throw new Error("retain requires an owner kind");
    args.push("--kind", input.kind);
    if (input.label) args.push("--label", input.label);
  }
  if (input.since !== undefined) {
    if (input.action !== "status") throw new Error("since applies only to status");
    args.push("--since", input.since);
  }
  if (input.action === "entry-exit") {
    if (!Number.isInteger(input.status)) throw new Error("entry-exit requires an integer status");
    args.push("--status", String(input.status));
  }
  if (input.graceSeconds !== undefined || input.disposablePath !== undefined) {
    if (input.action !== "authorize-cleanup") throw new Error("Policy options apply only to authorize-cleanup");
    if (input.graceSeconds !== undefined) {
      if (!Number.isFinite(input.graceSeconds) || input.graceSeconds < 0 || input.graceSeconds > 86400) throw new Error("Invalid grace period");
      args.push("--grace-seconds", String(input.graceSeconds));
    }
    if (input.disposablePath !== undefined) args.push("--disposable-path", input.disposablePath);
  }
  return ["--json", ...args];
}

export default async function wf(pi: ExtensionAPI) {
  const executable = await createExecutableResolver(
    pi.exec.bind(pi),
    fileURLToPath(new URL("../../", import.meta.url)),
    join(homedir(), "Library", "Application Support", "workfree", "runtime"),
    process.env.WF_BIN,
  );
  let timer: ReturnType<typeof setInterval> | undefined;
  const sweep = async (ctx: { ui: { notify: (message: string, type: "error") => void } }) => {
    try {
      const result = await pi.exec(await executable(), ["--json", "sweep"]);
      if (result.code !== 0 || result.killed) throw new Error(result.stderr || "Cleanup sweep failed");
    } catch (error) {
      ctx.ui.notify(String(error), "error");
    }
  };
  pi.on("session_start", async (_event, ctx) => {
    if (timer) clearInterval(timer);
    await sweep(ctx);
    let isSweeping = false;
    timer = setInterval(async () => {
      if (isSweeping) return;
      isSweeping = true;
      try { await sweep(ctx); } finally { isSweeping = false; }
    }, 60_000);
    timer.unref();
  });
  pi.on("session_shutdown", () => { if (timer) clearInterval(timer); timer = undefined; });

  pi.registerTool({
    name: "wf",
    label: "Workfree",
    description: "Manage task identity, active checkout users, and recoverable cleanup. authorize-cleanup requires operator confirmation. Under that policy, task owners survive eviction; workspace, execution, and pin owners block it. Never infer scope closure from command exit. preview is read-only; sweep evaluates recorded permissions; restore recreates the preserved commit.",
    parameters: Type.Object({
      action: Type.Union(actions.map((action) => Type.Literal(action))),
      id: Type.Optional(Type.String()),
      branch: Type.Optional(Type.String()),
      repo: Type.Optional(Type.String()),
      owner: Type.Optional(Type.String()),
      kind: Type.Optional(Type.Union([Type.Literal("task"), Type.Literal("workspace"), Type.Literal("execution"), Type.Literal("pin")])),
      label: Type.Optional(Type.String()),
      status: Type.Optional(Type.Integer()),
      isCleanupAllowed: Type.Optional(Type.Boolean({ description: "Request affirmative operator permission for automatic cleanup of this new allocation. Never assume permission." })),
      isCopyOnWriteRequired: Type.Optional(Type.Boolean({ description: "Require the optional simgit copy-on-write provider for this new allocation." })),
      since: Type.Optional(Type.String({ description: "Cleanup history window for status, such as 24h, 30d, 2w, or all. Default 30d." })),
      graceSeconds: Type.Optional(Type.Number({ description: "authorize-cleanup grace period, 0 to 86400 seconds; default 60." })),
      disposablePath: Type.Optional(Type.String({ description: "authorize-cleanup only: one explicit checkout-relative generated path. Never use for secrets or useful ignored files." })),
    }, { additionalProperties: false }),
    executionMode: "sequential",
    async execute(_call, input, signal, _update, ctx) {
      if (input.isCleanupAllowed) {
        if (input.action !== "start") throw new Error("Cleanup permission applies only to start");
        if (!ctx.hasUI || !(await ctx.ui.confirm("Allow automatic cleanup?", "Remove this managed checkout only after its final owner releases it and all safety checks pass."))) {
          throw new Error("Automatic cleanup was not authorized");
        }
      }
      const args = argumentsFor(input, ctx.cwd);
      if (input.action === "authorize-cleanup") {
        if (!ctx.hasUI || !(await ctx.ui.confirm("Authorize recoverable cleanup?",
          `Allocation: ${input.id}\nGrace: ${input.graceSeconds ?? 60} seconds\nDisposable generated path: ${input.disposablePath ?? "none"}\nAllow automatic eviction after active workspace, execution, and pin owners release. Task identity and an exact Git recovery reference survive. Unsaved files block removal.`))) {
          throw new Error("Recoverable cleanup was not authorized");
        }
      }
      const result = await pi.exec(await executable(signal), args, { signal });
      if (result.code !== 0 || result.killed) throw new Error(result.stderr || result.stdout || `wf failed with exit code ${result.code}`);
      let details: unknown;
      try { details = JSON.parse(result.stdout); }
      catch { throw new Error("wf returned invalid JSON"); }
      return { content: [{ type: "text", text: result.stdout }], details };
    },
  });

  pi.registerCommand("wf", {
    description: "Show storage saved and cleanup history, or inspect one task",
    handler: async (id, ctx) => {
      const result = await pi.exec(await executable(), id.trim() ? ["inspect", id.trim()] : ["status"]);
      const isSuccess = result.code === 0 && !result.killed;
      ctx.ui.notify(isSuccess ? result.stdout : result.stderr, isSuccess ? "info" : "error");
    },
  });

  pi.registerCommand("wf-finish", {
    description: "Finish one task without releasing workspace or execution owners",
    handler: async (id, ctx) => {
      if (!id.trim()) throw new Error("Specify the allocation id");
      if (!ctx.hasUI || !(await ctx.ui.confirm("Finish task?", "Workspace, pin, and execution owners remain. A clean authorized checkout can be removed after its final release."))) return;
      const result = await pi.exec(await executable(), ["finish", id.trim()]);
      const isSuccess = result.code === 0 && !result.killed;
      ctx.ui.notify(isSuccess ? result.stdout + result.stderr : result.stderr, isSuccess ? "info" : "error");
    },
  });
}
