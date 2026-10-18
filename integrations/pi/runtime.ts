import { createHash, randomUUID } from "node:crypto";
import { constants } from "node:fs";
import { access, link, lstat, mkdir, mkdtemp, open, readFile, realpath, rm, unlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export async function createExecutableResolver(
  exec: ExtensionAPI["exec"],
  packageRoot: string,
  runtimeRoot: string,
  override?: string,
): Promise<(signal?: AbortSignal) => Promise<string>> {
  if (override) return async (signal) => { signal?.throwIfAborted(); return override; };
  if (process.platform !== "darwin") throw new Error("Workfree currently requires macOS.");
  const root = await realpath(packageRoot);
  const gitRoot = singleLine(await run(exec, "git", ["-C", root, "rev-parse", "--show-toplevel"]));
  if (await realpath(gitRoot) !== root) throw new Error("Workfree must be loaded from its Git package root.");
  const revision = singleLine(await run(exec, "git", ["-C", root, "rev-parse", "--verify", "HEAD^{commit}"]));
  if (!/^(?:[a-f0-9]{40}|[a-f0-9]{64})$/.test(revision)) throw new Error("Git did not return a full Workfree commit identity.");
  const products = resolve(runtimeRoot);
  let pending: Promise<string> | undefined;
  return (signal) => {
    if (signal?.aborted) return Promise.reject(signal.reason);
    pending ??= resolveExecutable(exec, root, revision, products).catch((error) => {
      pending = undefined;
      throw error;
    });
    return waitForExecutable(pending, signal);
  };
}

async function run(exec: ExtensionAPI["exec"], command: string, args: string[]): Promise<string> {
  const result = await exec(command, args);
  if (result.code !== 0 || result.killed) {
    throw new Error(`Workfree bootstrap failed (${command}). Git and Swift 6 or newer must be installed.\n${result.stderr || result.stdout}`);
  }
  return result.stdout;
}

function singleLine(output: string): string {
  const value = output.endsWith("\n") ? output.slice(0, -1) : output;
  if (!value || /[\r\n\0]/.test(value)) throw new Error("Workfree bootstrap received malformed subprocess output.");
  return value;
}

function waitForExecutable(pending: Promise<string>, signal?: AbortSignal): Promise<string> {
  if (!signal) return pending;
  return new Promise((resolve, reject) => {
    const abort = () => { signal.removeEventListener("abort", abort); reject(signal.reason); };
    signal.addEventListener("abort", abort, { once: true });
    pending.then(
      (path) => { signal.removeEventListener("abort", abort); resolve(path); },
      (error) => { signal.removeEventListener("abort", abort); reject(error); },
    );
    if (signal.aborted) abort();
  });
}

async function resolveExecutable(exec: ExtensionAPI["exec"], packageRoot: string, revision: string, runtimeRoot: string): Promise<string> {
  const existing = await readRevisionBinding(runtimeRoot, revision);
  if (existing) return existing;
  const product = await buildExecutable(exec, packageRoot, revision, runtimeRoot);
  return publishRevisionBinding(runtimeRoot, revision, basename(dirname(product)));
}

async function buildExecutable(
  exec: ExtensionAPI["exec"],
  packageRoot: string,
  revision: string,
  runtimeRoot: string,
): Promise<string> {
  const temporary = await mkdtemp(join(tmpdir(), "workfree-build-"));
  try {
    const workspace = await realpath(temporary);
    const archive = join(workspace, "source.tar");
    const source = join(workspace, "source");
    await mkdir(source, { mode: 0o700 });
    await run(exec, "git", ["-C", packageRoot, "archive", "--format=tar", `--output=${archive}`, revision]);
    await run(exec, "tar", ["-xf", archive, "-C", source]);
    const args = ["build", "--package-path", source, "--scratch-path", join(workspace, "scratch"), "-c", "release"];
    await run(exec, "swift", [...args, "-Xswiftc", "-warnings-as-errors"]);
    const binDirectory = singleLine(await run(exec, "swift", [...args, "--show-bin-path"]));
    if (!isAbsolute(binDirectory)) throw new Error("Swift did not return an absolute build directory.");
    const built = join(binDirectory, "wf");
    const metadata = await lstat(built);
    const location = relative(workspace, await realpath(built));
    if (!metadata.isFile() || location === ".." || location.startsWith(`..${sep}`) || isAbsolute(location)) {
      throw new Error("Swift executable is not a regular file inside the private build workspace.");
    }
    await access(built, constants.X_OK);
    return await publishExecutable(await readFile(built), resolve(runtimeRoot));
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
}

async function privateDirectory(path: string): Promise<void> {
  try { await mkdir(path, { mode: 0o700 }); }
  catch (error) { if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error; }
  await validatePrivateDirectory(path);
}

async function validatePrivateDirectory(path: string): Promise<void> {
  const metadata = await lstat(path);
  if (!metadata.isDirectory() || metadata.uid !== process.getuid?.() || (metadata.mode & 0o7777) !== 0o700) {
    throw new Error(`Unsafe Workfree runtime directory: ${path}`);
  }
}

async function publishExecutable(bytes: Buffer, runtimeRoot: string): Promise<string> {
  const digest = createHash("sha256").update(bytes).digest("hex");
  await mkdir(dirname(runtimeRoot), { recursive: true, mode: 0o700 });
  await privateDirectory(runtimeRoot);
  const directory = join(runtimeRoot, digest);
  await privateDirectory(directory);
  const target = join(directory, "wf");
  const staging = join(directory, `.wf-${randomUUID()}`);
  let file: Awaited<ReturnType<typeof open>> | undefined;
  try {
    file = await open(staging, "wx", 0o600);
    try {
      await file.writeFile(bytes);
      await file.chmod(0o500);
    } finally {
      await file.close();
    }
    try { await link(staging, target); }
    catch (error) { if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error; }
    return await validateExecutable(runtimeRoot, digest);
  } finally {
    if (file) await unlink(staging);
  }
}

async function validateExecutable(runtimeRoot: string, digest: string): Promise<string> {
  const directory = join(runtimeRoot, digest);
  await validatePrivateDirectory(directory);
  const target = join(directory, "wf");
  const metadata = await lstat(target);
  if (!metadata.isFile() || metadata.uid !== process.getuid?.() || (metadata.mode & 0o7777) !== 0o500) {
    throw new Error("The private Workfree executable has an unsafe identity or permissions.");
  }
  const installedDigest = createHash("sha256").update(await readFile(target)).digest("hex");
  if (installedDigest !== digest) throw new Error("The private Workfree executable does not match its digest.");
  return target;
}

function revisionDirectory(runtimeRoot: string): string {
  return join(runtimeRoot, "revisions", `${process.platform}-${process.arch}`);
}

async function readRevisionBinding(runtimeRoot: string, revision: string): Promise<string | undefined> {
  const directory = revisionDirectory(runtimeRoot);
  const target = join(directory, `${revision}.json`);
  for (const path of [runtimeRoot, dirname(directory), directory]) {
    try { await validatePrivateDirectory(path); }
    catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
      throw error;
    }
  }
  let metadata: Awaited<ReturnType<typeof lstat>>;
  try { metadata = await lstat(target); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
    throw error;
  }
  if (!metadata.isFile() || metadata.uid !== process.getuid?.() || (metadata.mode & 0o7777) !== 0o400) {
    throw new Error(`Unsafe Workfree revision binding: ${target}`);
  }
  const binding: unknown = JSON.parse(await readFile(target, "utf8"));
  if (typeof binding !== "object" || binding === null ||
      Object.keys(binding).sort().join(",") !== "architecture,digest,platform,revision" ||
      !("revision" in binding) || binding.revision !== revision ||
      !("platform" in binding) || binding.platform !== process.platform ||
      !("architecture" in binding) || binding.architecture !== process.arch ||
      !("digest" in binding) || typeof binding.digest !== "string" || !/^[a-f0-9]{64}$/.test(binding.digest)) {
    throw new Error(`Invalid Workfree revision binding: ${target}`);
  }
  return validateExecutable(runtimeRoot, binding.digest);
}

async function publishRevisionBinding(runtimeRoot: string, revision: string, digest: string): Promise<string> {
  await validatePrivateDirectory(runtimeRoot);
  const directory = revisionDirectory(runtimeRoot);
  await privateDirectory(dirname(directory));
  await privateDirectory(directory);
  const target = join(directory, `${revision}.json`);
  const staging = join(directory, `.revision-${randomUUID()}`);
  let file: Awaited<ReturnType<typeof open>> | undefined;
  try {
    file = await open(staging, "wx", 0o600);
    try {
      await file.writeFile(JSON.stringify({ revision, platform: process.platform, architecture: process.arch, digest }));
      await file.chmod(0o400);
    } finally {
      await file.close();
    }
    try { await link(staging, target); }
    catch (error) { if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error; }
    const product = await readRevisionBinding(runtimeRoot, revision);
    if (!product) throw new Error("Workfree revision binding disappeared during publication.");
    return product;
  } finally {
    if (file) await unlink(staging);
  }
}
