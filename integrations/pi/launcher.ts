import { execFile } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { createExecutableResolver } from "./runtime.ts";

const exec: ExtensionAPI["exec"] = (command, args) => new Promise((resolve) => {
  execFile(command, args, { encoding: "utf8" }, (error, stdout, stderr) => {
    resolve({
      stdout,
      stderr: stderr || error?.message || "",
      code: error ? typeof error.code === "number" ? error.code : 1 : 0,
      killed: Boolean(error?.killed || error?.signal),
    });
  });
});

const valueOptions = new Set([
  "--state-dir", "--repo", "--base", "--path", "--owner", "--kind", "--label",
  "--status", "--provider", "--since", "--grace-seconds", "--disposable-path",
  "--min-idle", "--checkpoint", "--sessions-dir", "--exclude-id",
  "--session-id", "--session-pid", "--session-cwd", "--session-allocations", "--allocation",
]);

function parseNativeOptions(args: string[]) {
  const flags = new Set<string>();
  const positional: string[] = [];
  for (let index = 0; index < args.length && args[index] !== "--"; index += 1) {
    const argument = args[index];
    if (!argument.startsWith("--")) positional.push(argument);
    else {
      flags.add(argument);
      if (valueOptions.has(argument)) index += 1;
    }
  }
  return { action: positional[0], flags };
}

const args = process.argv.slice(2);
const native = parseNativeOptions(args);
if (
  process.env.PI_SESSION_ID
  && (native.action === "offload" || native.action === "cleanup-now")
  && native.flags.has("--retire-session-claims")
  && !native.flags.has("--session-id")
) {
  console.error("Inside Pi, retire conversation claims with the native wf tool and isRetiringSessionClaims. It passes this conversation's identity; the shell form cannot.");
  process.exit(2);
}

try {
  if (!process.execve) throw new Error("The Workfree Pi launcher requires Node.js 22.19 or newer with execve support on macOS.");
  const resolveExecutable = await createExecutableResolver(
    exec,
    fileURLToPath(new URL("../../", import.meta.url)),
    join(homedir(), "Library", "Application Support", "workfree", "runtime"),
  );
  const executable = await resolveExecutable();
  process.execve(executable, [executable, ...args], process.env);
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
}
