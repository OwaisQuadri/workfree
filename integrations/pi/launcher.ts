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

try {
  if (!process.execve) throw new Error("The Workfree Pi launcher requires Node.js 22.19 or newer with execve support on macOS.");
  const resolveExecutable = await createExecutableResolver(
    exec,
    fileURLToPath(new URL("../../", import.meta.url)),
    join(homedir(), "Library", "Application Support", "workfree", "runtime"),
  );
  const executable = await resolveExecutable();
  process.execve(executable, [executable, ...process.argv.slice(2)], process.env);
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
}
