import { createHash, randomUUID } from "node:crypto";
import { constants } from "node:fs";
import { access, link, lstat, mkdir, readFile, unlink, writeFile } from "node:fs/promises";
import { dirname, isAbsolute, join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export function createExecutableResolver(
  exec: ExtensionAPI["exec"],
  packageRoot: string,
  runtimeRoot: string,
  override?: string,
): (signal?: AbortSignal) => Promise<string> {
  let pending: Promise<string> | undefined;
  return (signal) => {
    if (override) return Promise.resolve(override);
    pending ??= buildExecutable(exec, packageRoot, runtimeRoot, signal).catch((error) => {
      pending = undefined;
      throw error;
    });
    return pending;
  };
}

async function buildExecutable(
  exec: ExtensionAPI["exec"],
  packageRoot: string,
  runtimeRoot: string,
  signal?: AbortSignal,
): Promise<string> {
  if (process.platform !== "darwin") throw new Error("Workfree currently requires macOS.");
  const args = ["build", "--package-path", packageRoot, "-c", "release"];
  const build = await exec("swift", [...args, "-Xswiftc", "-warnings-as-errors"], { signal });
  if (build.code !== 0) {
    throw new Error(`Cannot build Workfree. Swift and Git must be installed.\n${build.stderr || build.stdout}`);
  }
  const output = await exec("swift", [...args, "--show-bin-path"], { signal });
  if (output.code !== 0 || !isAbsolute(output.stdout.trim()) || output.stdout.trim().includes("\n")) {
    throw new Error("Swift did not return a build directory.");
  }
  const built = join(output.stdout.trim(), "wf");
  await access(built, constants.X_OK);
  const bytes = await readFile(built);
  const digest = createHash("sha256").update(bytes).digest("hex");
  const target = join(runtimeRoot, digest, "wf");
  await mkdir(dirname(target), { recursive: true, mode: 0o700 });
  const staging = join(dirname(target), `.wf-${randomUUID()}`);
  await writeFile(staging, bytes, { flag: "wx", mode: 0o700 });
  try {
    try { await link(staging, target); }
    catch (error) { if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error; }
  } finally {
    await unlink(staging);
  }
  const metadata = await lstat(target);
  if (!metadata.isFile() || metadata.uid !== process.getuid?.() || (metadata.mode & 0o077) !== 0 || (metadata.mode & 0o100) === 0) {
    throw new Error("The private Workfree executable has an unsafe identity or permissions.");
  }
  const installedDigest = createHash("sha256").update(await readFile(target)).digest("hex");
  if (installedDigest !== digest) throw new Error("The private Workfree executable does not match the build.");
  return target;
}
