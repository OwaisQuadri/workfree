import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type } from "@earendil-works/pi-ai";
import { homedir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { createExecutableResolver } from "./runtime.ts";

const actions = ["claim", "start", "inspect", "list", "status", "retain", "release", "finish", "keep", "unkeep", "close-scope", "entry-exit", "recover", "authorize-cleanup", "revoke-cleanup", "preview", "sweep", "offload", "cleanup-now", "restore"] as const;

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
  isRefresh?: boolean;
  graceSeconds?: number;
  disposablePath?: string;
  disposablePaths?: string[];
  isAll?: boolean;
  minimumIdle?: string;
  checkpoint?: "local" | "remote";
  isRetiringSessionClaims?: boolean;
  excludingID?: string;
  sessionsDirectory?: string;
}, cwd: string): string[] {
  if (input.action === "authorize-cleanup") {
    throw new Error("New cleanup authority requires operator setup: wf cleanup-policy enable --global or --repo PATH for future allocations, wf cleanup-policy migrate --global for eligible existing allocations, or wf authorize-cleanup ID for one allocation. The model cannot grant permission.");
  }
  if (input.isCleanupAllowed && input.action !== "start") throw new Error("Cleanup permission applies only to start");
  const args: string[] = [input.action];
  if (input.action === "start") {
    if (!input.branch) throw new Error("start requires a branch");
    args.push(input.branch, "--repo", input.repo ?? cwd);
    if (input.isCleanupAllowed) args.push("--require-cleanup-policy");
    if (input.isCopyOnWriteRequired) args.push("--require-cow");
  } else if (input.action === "claim") {
    if (input.id) args.push(input.id);
  } else if (input.action === "offload" || input.action === "cleanup-now") {
    const selections = Number(Boolean(input.id)) + Number(Boolean(input.repo)) + Number(input.isAll === true);
    if (selections !== 1 || !input.minimumIdle) throw new Error("Choose one allocation id, repository, or all, with a minimum idle age");
    if (input.id) args.push(input.id);
    if (input.repo) args.push("--repo", input.repo);
    if (input.isAll) args.push("--all");
    args.push("--min-idle", input.minimumIdle);
    if (input.action === "offload") {
      if (!input.checkpoint) throw new Error("offload requires a local or remote checkpoint");
      args.push("--checkpoint", input.checkpoint);
    }
    if (input.isRetiringSessionClaims) args.push("--retire-session-claims");
    if (input.excludingID) args.push("--exclude-id", input.excludingID);
    if (input.sessionsDirectory) args.push("--sessions-dir", input.sessionsDirectory);
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
  if (input.isRefresh) {
    if (input.action !== "status") throw new Error("refresh applies only to status");
    args.push("--refresh");
  }
  if (input.action === "entry-exit") {
    if (!Number.isInteger(input.status)) throw new Error("entry-exit requires an integer status");
    args.push("--status", String(input.status));
  }
  if (!["offload", "cleanup-now"].includes(input.action) &&
    (input.isAll !== undefined || input.minimumIdle !== undefined || input.checkpoint !== undefined || input.isRetiringSessionClaims !== undefined || input.excludingID !== undefined || input.sessionsDirectory !== undefined)) {
    throw new Error("One-off options apply only to offload and cleanup-now");
  }
  if (input.graceSeconds !== undefined || input.disposablePath !== undefined || input.disposablePaths !== undefined) {
    throw new Error("Policy options require an explicit operator CLI grant with wf authorize-cleanup ID; they cannot create model authority.");
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
  const metadataType = "workfree-conversation-allocations";
  const allocationIDs = (ctx: ExtensionContext): string[] => {
    let ids = new Set<string>();
    for (const entry of ctx.sessionManager.getEntries()) {
      if (entry.type !== "custom" || entry.customType !== metadataType) continue;
      if (!Array.isArray(entry.data) || !entry.data.every((id) => typeof id === "string")) {
        throw new Error("Invalid Workfree conversation metadata; cleanup is blocked");
      }
      ids = new Set(entry.data);
    }
    return [...ids];
  };
  let shutdown: AbortController | undefined;
  let isCollecting = false;
  const shutdownSignals = new WeakSet<AbortSignal>();
  const execute = async (ctx: ExtensionContext, args: string[], signal?: AbortSignal) => {
    const ids = allocationIDs(ctx);
    const sessionID = ctx.sessionManager.getSessionId();
    const contextArgs = [
      "--session-id", sessionID, "--session-pid", String(process.pid),
      "--session-cwd", ctx.cwd, "--session-allocations", JSON.stringify(ids),
    ];
    const binary = await executable(signal);
    const result = await pi.exec(binary, [...contextArgs, ...args], { signal }).catch((error: unknown) => ({
      code: 1, killed: false, stdout: "", stderr: String(error),
    }));
    let details: unknown;
    let failure: Error | undefined;
    if (args.length === 1 && args[0] === "status") details = result.stdout;
    else {
      try { details = JSON.parse(result.stdout); }
      catch { failure = new Error("wf returned invalid JSON"); }
    }
    if (result.code !== 0 || result.killed) failure = new Error(result.stderr || result.stdout || `wf failed with exit code ${result.code}`);
    let acquiredDetails = details;
    if (failure && signal?.aborted && shutdownSignals.has(signal)) throw failure;
    if (failure) {
      const claims = await pi.exec(binary, [...contextArgs, "--json", "claim"]);
      if (claims.code !== 0 || claims.killed) throw new Error(`${failure.message}; conversation metadata reconciliation failed: ${claims.stderr}`);
      acquiredDetails = JSON.parse(claims.stdout);
    }
    const records = Array.isArray(acquiredDetails) ? acquiredDetails : [acquiredDetails];
    const acquired = records.flatMap((record) => {
      if (!record || typeof record !== "object" || typeof record.id !== "string") return [];
      if (!Array.isArray(record.conversationClaims) || !record.conversationClaims.some(
        (claim: { sessionID?: string; processID?: number }) => claim.sessionID === sessionID && claim.processID === process.pid,
      )) return [];
      return [record.id as string];
    });
    const nextIDs = new Set([...ids, ...acquired]);
    if (args.includes("--retire-session-claims") && !failure) {
      for (const record of records) {
        if (record && typeof record === "object" && typeof record.id === "string" &&
          Array.isArray(record.conversationClaims) && !record.conversationClaims.some(
            (claim: { sessionID?: string }) => claim.sessionID === sessionID,
          )) nextIDs.delete(record.id);
      }
    }
    if (nextIDs.size !== ids.length || ids.some((id) => !nextIDs.has(id))) {
      pi.appendEntry(metadataType, [...nextIDs]);
    }
    if (failure) throw failure;
    return { result, details };
  };
  let timer: ReturnType<typeof setInterval> | undefined;
  const stop = () => {
    if (timer) clearInterval(timer);
    timer = undefined;
    shutdown?.abort();
    shutdown = undefined;
  };
  const sweep = async (ctx: ExtensionContext) => {
    const signal = shutdown?.signal;
    try { await execute(ctx, ["--json", "sweep"], signal); }
    catch (error) { if (!signal?.aborted) ctx.ui.notify(String(error), "error"); }
  };
  pi.on("session_start", async (_event, ctx) => {
    stop();
    shutdown = new AbortController();
    shutdownSignals.add(shutdown.signal);
    await execute(ctx, ["--json", "claim"]);
    let isSweeping = false;
    const sweepOnce = async () => {
      if (isSweeping || isCollecting) return;
      isSweeping = true;
      try { await sweep(ctx); } finally { isSweeping = false; }
    };
    void sweepOnce();
    timer = setInterval(sweepOnce, 60_000);
    timer.unref();
  });
  pi.on("session_shutdown", stop);

  pi.registerTool({
    name: "wf",
    label: "Workfree",
    description: "Claim allocations before raw shell use or child dispatch. Structured operations acquire durable conversation protection automatically. Shutdown and idle do not release it. Explicit offload or cleanup-now with isRetiringSessionClaims can retire this conversation's claims only after a positive idle age and a recoverable checkpoint; other conversations still block removal. Arbitrary transcript paths are not inferred. Manage task identity, active checkout users, and recoverable cleanup. Normal start inherits saved global or repository cleanup authority unless the repository is excluded. Without it, start retains an unauthorized checkout. New authority requires operator CLI setup with wf cleanup-policy enable --global or --repo PATH; authorize-cleanup cannot grant model authority. Under that policy, task owners survive eviction; workspace, execution, and pin owners block it. Never infer scope closure from command exit. preview is read-only; sweep evaluates recorded permissions; restore recreates the preserved commit.",
    parameters: Type.Object({
      action: Type.Union(actions.map((action) => Type.Literal(action))),
      id: Type.Optional(Type.String()),
      branch: Type.Optional(Type.String()),
      repo: Type.Optional(Type.String()),
      owner: Type.Optional(Type.String()),
      kind: Type.Optional(Type.Union([Type.Literal("task"), Type.Literal("workspace"), Type.Literal("execution"), Type.Literal("pin")])),
      label: Type.Optional(Type.String()),
      status: Type.Optional(Type.Integer()),
      isCleanupAllowed: Type.Optional(Type.Boolean({ description: "Require already-recorded standing cleanup authority for start. This cannot grant permission. Normal start inherits saved policy without this flag." })),
      isCopyOnWriteRequired: Type.Optional(Type.Boolean({ description: "Require the optional simgit copy-on-write provider for this new allocation." })),
      since: Type.Optional(Type.String({ description: "Cleanup history window for status, such as 24h, 30d, 2w, or all. Default 30d." })),
      isRefresh: Type.Optional(Type.Boolean({ description: "Refresh measured storage before returning status. This scans live worktrees and can take minutes." })),
      graceSeconds: Type.Optional(Type.Number({ description: "Operator CLI grant only. The model cannot set cleanup policy." })),
      disposablePath: Type.Optional(Type.String({ description: "Operator CLI grant only. The model cannot approve disposable paths." })),
      disposablePaths: Type.Optional(Type.Array(Type.String(), { description: "Operator CLI grant only. Standing repository policy never grants disposable paths." })),
      isAll: Type.Optional(Type.Boolean({ description: "Select all allocations for one-off offload or cleanup." })),
      minimumIdle: Type.Optional(Type.String({ description: "Required minimum inactivity, for example 24h." })),
      checkpoint: Type.Optional(Type.Union([Type.Literal("local"), Type.Literal("remote")])),
      isRetiringSessionClaims: Type.Optional(Type.Boolean({ description: "Explicitly retire this conversation's claims only for idle allocations with recoverable checkpoints." })),
      excludingID: Type.Optional(Type.String({ description: "Do not consider this active allocation in an all or repository run." })),
      sessionsDirectory: Type.Optional(Type.String({ description: "Transcript directory to verify conversation activity." })),
    }, { additionalProperties: false }),
    executionMode: "sequential",
    async execute(_call, input, signal, _update, ctx) {
      const args = argumentsFor(input, ctx.cwd);
      if (input.isRetiringSessionClaims) isCollecting = true;
      try {
        const { result, details } = await execute(ctx, args, signal);
        return { content: [{ type: "text", text: result.stdout }], details };
      } finally {
        isCollecting = false;
      }
    },
  });

  pi.registerCommand("wf", {
    description: "Show storage saved and cleanup history, or inspect one task",
    handler: async (id, ctx) => {
      const { result } = await execute(ctx, id.trim() ? ["--json", "inspect", id.trim()] : ["status"]);
      const isSuccess = result.code === 0 && !result.killed;
      ctx.ui.notify(isSuccess ? result.stdout : result.stderr, isSuccess ? "info" : "error");
    },
  });

  pi.registerCommand("wf-finish", {
    description: "Finish one task without releasing workspace or execution owners",
    handler: async (id, ctx) => {
      if (!id.trim()) throw new Error("Specify the allocation id");
      if (!ctx.hasUI || !(await ctx.ui.confirm("Finish task?", "Workspace, pin, and execution owners remain. A clean authorized checkout can be removed after its final release."))) return;
      const { result } = await execute(ctx, ["--json", "finish", id.trim()]);
      const isSuccess = result.code === 0 && !result.killed;
      ctx.ui.notify(isSuccess ? result.stdout + result.stderr : result.stderr, isSuccess ? "info" : "error");
    },
  });
}
