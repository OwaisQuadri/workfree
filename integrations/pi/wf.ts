import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "@earendil-works/pi-ai";
import { homedir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { createExecutableResolver } from "./runtime.ts";

const actions = ["start", "inspect", "list", "retain", "release", "finish", "keep", "unkeep", "close-scope", "entry-exit", "recover"] as const;

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
}, cwd: string): string[] {
  const args: string[] = [input.action];
  if (input.action === "start") {
    if (!input.branch) throw new Error("start requires a branch");
    args.push(input.branch, "--repo", input.repo ?? cwd);
    if (input.isCleanupAllowed) args.push("--allow-cleanup");
    if (input.isCopyOnWriteRequired) args.push("--require-cow");
  } else if (input.action !== "list") {
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
  if (input.action === "entry-exit") {
    if (!Number.isInteger(input.status)) throw new Error("entry-exit requires an integer status");
    args.push("--status", String(input.status));
  }
  return ["--json", ...args];
}

export default function wf(pi: ExtensionAPI) {
  const executable = createExecutableResolver(
    pi.exec.bind(pi),
    fileURLToPath(new URL("../../", import.meta.url)),
    join(homedir(), "Library", "Application Support", "workfree", "runtime"),
    process.env.WF_BIN,
  );
  pi.registerTool({
    name: "wf",
    label: "Workfree",
    description: "Manage explicit task and checkout ownership. Task completion, window closure, and execution closure are separate. Never infer scope closure from command exit or merge status. Start defaults to retaining the checkout without automatic cleanup permission.",
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
      const result = await pi.exec(await executable(signal), args, { signal });
      if (result.code !== 0) throw new Error(result.stderr || result.stdout || `wf exited ${result.code}`);
      let details: unknown;
      try { details = JSON.parse(result.stdout); }
      catch { throw new Error("wf returned invalid JSON"); }
      return { content: [{ type: "text", text: result.stdout }], details };
    },
  });

  pi.registerCommand("wf", {
    description: "Inspect managed tasks and cleanup blockers",
    handler: async (id, ctx) => {
      const result = await pi.exec(await executable(), id.trim() ? ["inspect", id.trim()] : ["list"]);
      ctx.ui.notify(result.code === 0 ? result.stdout : result.stderr, result.code === 0 ? "info" : "error");
    },
  });

  pi.registerCommand("wf-finish", {
    description: "Finish one task without releasing workspace or execution owners",
    handler: async (id, ctx) => {
      if (!id.trim()) throw new Error("Specify the allocation id");
      if (!ctx.hasUI || !(await ctx.ui.confirm("Finish task?", "Workspace, pin, and execution owners remain. A clean authorized checkout can be removed after its final release."))) return;
      const result = await pi.exec(await executable(), ["finish", id.trim()]);
      ctx.ui.notify(result.code === 0 ? result.stdout : result.stderr, result.code === 0 ? "info" : "error");
    },
  });
}
