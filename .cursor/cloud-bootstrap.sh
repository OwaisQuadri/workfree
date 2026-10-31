#!/usr/bin/env bash
# Cloud bootstrap for agent-hooks, in two phases:
#   bootstrap.sh install  token-free (Cursor `install` / Claude setup script): toolchain checks only; safe without secrets.
#   bootstrap.sh start    needs runtime secret PI_CONFIG_TOKEN (Cursor `start` / Claude SessionStart): clones pi-config,
#                         agents-config, the pi fork, extensions, checker repos; installs skills, hooks, MCP, pi, checkers.
# Idempotent: start skips any component whose upstream commit is unchanged (stamps in $BOOTSTRAP_CACHE), so repeat starts
# cost a few `git ls-remote` calls. Fails loudly: any error stops the script with a message.
set -euo pipefail
set +x
trap 'echo "cloud-bootstrap: FAILED at line $LINENO" >&2' ERR
MODE=${1:-start}

PROJECT=$(pwd)
PI_CONFIG_REPO=${PI_CONFIG_REPO:-OwaisQuadri/pi-config}
# agent-hooks/ lives only on agent-hooks/cloud until that branch is merged into main.
PI_CONFIG_REF=${PI_CONFIG_REF:-agent-hooks/cloud}
AGENTS_CONFIG_REPO=${AGENTS_CONFIG_REPO:-OwaisQuadri/agents-config}
# 1 = build command-guard, edit-time-check and affected-tests for Linux from source (needs Swift 6.4, clang, zsh, tree-sitter 0.27.1).
BUILD_CHECKERS=${BUILD_CHECKERS:-0}
TREE_SITTER_CLI_VERSION=${TREE_SITTER_CLI_VERSION:-0.27.1}
CHECKERS_REF=${CHECKERS_REF:-linux-build}  # Linux port branch until merged to main
HOOKS_SOURCE=${AGENT_HOOKS_SOURCE:-pi-config}
HOOKS_SUBDIR=${AGENT_HOOKS_SUBDIR:-agent-hooks}
HOOKS_REPO=${AGENT_HOOKS_REPO:-}
WORK=${BOOTSTRAP_CACHE:-$HOME/.cache/cloud-bootstrap}
CHECKERS_OUT=${CHECKERS_OUT:-$WORK/checkers-out}
INSTALL_PI=${INSTALL_PI:-1}
PI_REPO=${PI_REPO:-OwaisQuadri/pi}
PI_EXTENSIONS=${PI_EXTENSIONS:-OwaisQuadri/pi-ask-user OwaisQuadri/pi-limit-resume}
PI_PUBLIC_PACKAGES=${PI_PUBLIC_PACKAGES:-git:github.com/nicobailon/pi-subagents git:github.com/nicobailon/pi-web-access}
# MCP hard allowlist. Pillars (linear-pillars) stays separate; gmail, cua-driver, rea are excluded.
MCP_ALLOW=${MCP_ALLOW:-huggingface slack}

die() { echo "cloud-bootstrap: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "$1 missing${2:+ ($2)}"; }

# ---- token-free checks (both phases) ----
need git; need node
node -e 'const [a,b]=process.versions.node.split(".").map(Number);process.exit(a>22||(a===22&&b>=19)?0:1)' || die "node $(node -v) is too old; need >= 22.19 (pi and the hooks)"
[ "$INSTALL_PI" = 1 ] && need npm "needed for pi"
if [ "$BUILD_CHECKERS" = 1 ]; then
	need swift "BUILD_CHECKERS=1 needs a Swift 6.4 Linux toolchain"; swift --version 2>&1 | grep -q 'Swift version 6.4' || die "need Swift 6.4"
	need clang; need zsh; need rg; command -v fd >/dev/null || need fdfind
	ls "${TREE_SITTER_PREFIX:-/usr/local}"/lib/libtree-sitter.so* >/dev/null 2>&1 || die "tree-sitter 0.27.1 not found under ${TREE_SITTER_PREFIX:-/usr/local}"
	# tree-sitter CLI (edit-time-check tests run `tree-sitter generate`). Public npm package, token-free; skipped when present.
	export PATH="$HOME/.local/bin:$PATH"
	if [ "$(tree-sitter --version 2>/dev/null | cut -d' ' -f2)" != "$TREE_SITTER_CLI_VERSION" ]; then
		need npm "needed for the tree-sitter CLI"
		npm install --silent --global --prefix "$HOME/.local" "tree-sitter-cli@$TREE_SITTER_CLI_VERSION" || die "tree-sitter-cli $TREE_SITTER_CLI_VERSION install failed"
		[ "$(tree-sitter --version 2>/dev/null | cut -d' ' -f2)" = "$TREE_SITTER_CLI_VERSION" ] || die "tree-sitter CLI $TREE_SITTER_CLI_VERSION not on PATH after install"
	fi
fi
case "$MODE" in
	install) echo "cloud-bootstrap: install checks passed (token-free; run 'start' at runtime)"; exit 0 ;;
	start) ;;
	*) die "usage: bootstrap.sh install|start" ;;
esac

# ---- runtime phase: needs the token ----
[ -n "${PI_CONFIG_TOKEN:-}" ] || die "PI_CONFIG_TOKEN is not set. It is a RUNTIME secret: run 'bootstrap.sh start' from the agent session (Cursor start, Claude SessionStart), not from install/build."
mkdir -p "$WORK"

# The bootstrap's own git ignores global and system config: Cursor VMs set global url.*.insteadOf rules that
# inject credentials into URLs. The VM's config stays untouched; only these commands skip it.
bgit() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git "$@"; }
# The token travels only in env-scoped git config for each command: never argv, URL, or .git/config.
authed_git() {
	local header
	header="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$PI_CONFIG_TOKEN" | base64 | tr -d '\n')"
	GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="http.https://github.com/.extraheader" GIT_CONFIG_VALUE_0="$header" bgit "$@"
}

# fetch repo dest [ref]: shallow clone, reused when the remote commit is unchanged. Sets CHANGED=1 when new.
fetch() {
	local ref=${3:-main} want
	want=$(authed_git ls-remote "https://github.com/$1.git" "refs/heads/$ref" | cut -f1)
	[ -n "$want" ] || die "ls-remote of $1@$ref failed (check token scope)"
	if [ "$(bgit -C "$2" rev-parse HEAD 2>/dev/null || true)" = "$want" ]; then CHANGED=0; return; fi
	rm -rf "$2"; mkdir -p "$(dirname "$2")"
	authed_git clone --quiet --depth 1 --branch "$ref" "https://github.com/$1.git" "$2" || die "clone of $1 failed (check token scope)"
	[ -z "$(bgit -C "$2" config --get-regexp 'extraheader' || true)" ] || die "token leaked into git config"
	case "$(bgit -C "$2" remote get-url origin)" in *@*) die "credential in remote URL";; esac
	CHANGED=1
}
# stamp name: true when the step already ran for these inputs; mark name records them.
stamp() { [ -f "$WORK/.stamp-$1" ] && [ "$(cat "$WORK/.stamp-$1")" = "$2" ]; }
mark() { printf '%s' "$2" > "$WORK/.stamp-$1"; }
rev() { bgit -C "$1" rev-parse HEAD; }

fetch "$PI_CONFIG_REPO" "$WORK/pi-config" "$PI_CONFIG_REF"
fetch "$AGENTS_CONFIG_REPO" "$WORK/agents-config"

# Skills: replace o-stack copies wholesale so removed skills disappear on rerun.
SKILLS="$WORK/pi-config/skills/o-stack"
[ -d "$SKILLS" ] || die "skills/o-stack missing in $PI_CONFIG_REPO"
# agents-config/skills holds shared skills (its .system dir is Codex-only and skipped).
SHARED="$WORK/agents-config/skills"
for dest in .cursor/skills .claude/skills; do
	mkdir -p "$dest"
	for skill in "$SKILLS"/* "$SHARED"/*; do
		[ -f "$skill/SKILL.md" ] || continue
		name=$(basename "$skill"); rm -rf "${dest:?}/$name"; cp -R "$skill" "$dest/$name"
	done
done

# Hook scripts end up at .agent-hooks, which the hook config references.
case "$HOOKS_SOURCE" in
	vendored) [ -f .agent-hooks/lib/hook.mjs ] || die ".agent-hooks is not vendored in this project" ;;
	pi-config) [ -d "$WORK/pi-config/$HOOKS_SUBDIR" ] || die "$HOOKS_SUBDIR missing in pi-config"
		rm -rf .agent-hooks; cp -R "$WORK/pi-config/$HOOKS_SUBDIR" .agent-hooks ;;
	repo) [ -n "$HOOKS_REPO" ] || die "AGENT_HOOKS_REPO not set"
		fetch "$HOOKS_REPO" "$WORK/agent-hooks"; rm -rf .agent-hooks; cp -R "$WORK/agent-hooks" .agent-hooks; rm -rf .agent-hooks/.git ;;
	*) die "unknown AGENT_HOOKS_SOURCE=$HOOKS_SOURCE" ;;
esac

# Linux checkers from the linux-build branches, built once per commit, then placed where the hooks look
# (.agent-hooks/vendor/pi/agent/checkers, replacing the macOS binaries that cannot run here).
if [ "$(uname -s)" = Linux ]; then
	if [ "$BUILD_CHECKERS" = 1 ]; then
		mkdir -p "$CHECKERS_OUT/checkers" "$HOME/.local/bin"
		fetch OwaisQuadri/edit-time-check "$WORK/edit-time-check" "$CHECKERS_REF"
		if ! stamp edit-time-check "$(rev "$WORK/edit-time-check")"; then
			(cd "$WORK/edit-time-check" && ./build-linux.sh "$CHECKERS_OUT/edit-time-check") || die "edit-time-check Linux build failed"
			mark edit-time-check "$(rev "$WORK/edit-time-check")"
		fi
		fetch OwaisQuadri/command-guard "$WORK/command-guard" "$CHECKERS_REF"
		if ! stamp command-guard "$(rev "$WORK/command-guard")"; then
			(cd "$WORK/command-guard" && swift build -c release --product command-guard) || die "command-guard Linux build failed"
			install -m 755 "$WORK/command-guard/.build/release/command-guard" "$CHECKERS_OUT/checkers/command-guard"
			mark command-guard "$(rev "$WORK/command-guard")"
		fi
		fetch OwaisQuadri/affected-tests "$WORK/affected-tests" "$CHECKERS_REF"
		if ! stamp affected-tests "$(rev "$WORK/affected-tests")"; then
			(cd "$WORK/affected-tests" && AFFECTED_TESTS_PREFIX="$HOME/.local" zsh setup.zsh) || die "affected-tests setup failed"
			mark affected-tests "$(rev "$WORK/affected-tests")"
		fi
		RG=$(command -v rg); FD=$(command -v fd || command -v fdfind)
		digest=$(sha256sum "$CHECKERS_OUT/checkers/command-guard" | cut -d' ' -f1)
		printf '{"version":2,"sha256":"%s","rgExecutable":"%s","fdExecutable":"%s"}\n' "$digest" "$RG" "$FD" > "$CHECKERS_OUT/checkers/command-guard.json"
		"$CHECKERS_OUT/checkers/command-guard" --guidance-json >/dev/null || die "Linux command-guard does not run"
		dest=.agent-hooks/vendor/pi/agent/checkers; mkdir -p "$dest"
		rm -rf "$dest/edit-time-check" "$dest/lib" "$dest/parsers"
		cp -R "$CHECKERS_OUT/edit-time-check/." "$dest/"
		cp -p "$CHECKERS_OUT/checkers/command-guard" "$CHECKERS_OUT/checkers/command-guard.json" "$dest/"
		# edit-time-check's default parser root (hooks pass no --parser-root).
		mkdir -p "$HOME/.local/lib/agents-tree-sitter"; ln -sfn "$CHECKERS_OUT/edit-time-check/parsers" "$HOME/.local/lib/agents-tree-sitter/parsers"
	else
		echo "cloud-bootstrap: WARNING BUILD_CHECKERS=0 on Linux; command and comment-shape guards will deny (fail closed)" >&2
	fi
fi

# pi: build the fork, install globally, then extensions from local clones and the public packages.
if [ "$INSTALL_PI" = 1 ]; then
	PI_DIR=${PI_DIR:-$HOME/.local/share/pi-fork}
	fetch "$PI_REPO" "$PI_DIR"
	if ! command -v pi >/dev/null || ! stamp pi "$(rev "$PI_DIR")"; then
		(cd "$PI_DIR" && npm ci --ignore-scripts && npm run build:offline) || die "pi build failed"
		npm install -g --ignore-scripts "$PI_DIR/packages/coding-agent" || die "pi global install failed"
		need pi "not on PATH after install"; mark pi "$(rev "$PI_DIR")"
	fi
	for ext in $PI_EXTENSIONS; do
		dest="$HOME/.local/share/pi-extensions/$(basename "$ext")"
		fetch "$ext" "$dest"
		stamp "ext-$(basename "$ext")" "$(rev "$dest")" && continue
		[ -f "$dest/package.json" ] && (cd "$dest" && npm install --ignore-scripts --no-audit --no-fund >/dev/null)
		pi install "$dest" || die "pi install $ext failed"; mark "ext-$(basename "$ext")" "$(rev "$dest")"
	done
	stamp pi-public "$PI_PUBLIC_PACKAGES" || { ok=1; for pkg in $PI_PUBLIC_PACKAGES; do pi install "$pkg" || { ok=0; echo "cloud-bootstrap: WARNING pi install $pkg failed" >&2; }; done; [ $ok = 1 ] && mark pi-public "$PI_PUBLIC_PACKAGES"; }
fi

# Instructions: pi-config AGENTS.md is used only when the project has none; Claude reads it via CLAUDE.md import.
if [ ! -e AGENTS.md ] && [ -f "$WORK/pi-config/AGENTS.md" ]; then cp "$WORK/pi-config/AGENTS.md" AGENTS.md; fi
if [ -e AGENTS.md ] && [ ! -e CLAUDE.md ]; then printf '@AGENTS.md\n' > CLAUDE.md; fi

# MCP: only allowlisted servers ($MCP_ALLOW) from pi-config mcp.json into .cursor/mcp.json and .mcp.json. Existing servers win; stdio servers
# whose command is not installed here are skipped. Env values are copied, never printed.
node - "$PROJECT" "$WORK/pi-config/mcp.json" "$MCP_ALLOW" <<'JS'
const fs = require("fs"), path = require("path"), { execSync } = require("child_process");
const [root, source, allowList] = process.argv.slice(2);
const allow = new Set(allowList.split(/\s+/).filter(Boolean));
if (!fs.existsSync(source)) { console.log("cloud-bootstrap: no pi-config mcp.json"); process.exit(0); }
const raw = JSON.parse(fs.readFileSync(source, "utf8")), servers = raw.mcpServers ?? raw;
const has = (cmd) => { try { execSync(`command -v ${JSON.stringify(cmd)}`, { stdio: "ignore", shell: "/bin/sh" }); return true; } catch { return false; } };
for (const [target, claude] of [[".cursor/mcp.json", false], [".mcp.json", true]]) {
	const file = path.join(root, target);
	const cur = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, "utf8")) : {};
	cur.mcpServers ??= {};
	const skipped = [];
	for (const [name, s] of Object.entries(servers)) {
		if (!allow.has(name) || cur.mcpServers[name]) continue;
		if (s.url) cur.mcpServers[name] = claude ? { type: "http", url: s.url } : { url: s.url };
		else if (s.command && has(s.command)) cur.mcpServers[name] = { command: s.command, args: s.args ?? [], ...(s.env ? { env: s.env } : {}) };
		else skipped.push(name);
	}
	fs.mkdirSync(path.dirname(file), { recursive: true });
	fs.writeFileSync(file, JSON.stringify(cur, null, 2) + "\n");
	console.log(`cloud-bootstrap: merged ${target}${skipped.length ? ` (skipped, command missing: ${skipped.join(", ")})` : ""}`);
}
JS

# Merge hook config: keep foreign entries, add each guard once. An entry already running the same
# .agent-hooks/hooks/<guard>.mjs (any spelling of the path) is replaced in place, so reruns never duplicate.
node - "$PROJECT" <<'JS'
const fs = require("fs"), path = require("path");
const root = process.argv[2];
const merge = (target, template, cursor) => {
	const file = path.join(root, target);
	const cur = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, "utf8")) : (cursor ? { version: 1 } : {});
	const add = JSON.parse(fs.readFileSync(path.join(root, ".agent-hooks", template), "utf8"));
	cur.hooks ??= {};
	for (const [event, entries] of Object.entries(add.hooks)) {
		const list = (cur.hooks[event] ??= []);
		for (const entry of entries) {
			const script = (c) => /\/hooks\/[\w-]+\.mjs/.exec(String(c ?? ""))?.[0] ?? String(c);
			const key = (e) => JSON.stringify(cursor ? script(e.command) : [e.matcher ?? "", (e.hooks ?? []).map((h) => script(h.command))]);
			const at = list.findIndex((e) => key(e) === key(entry));
			if (at === -1) list.push(entry); else list[at] = entry;
		}
	}
	fs.mkdirSync(path.dirname(file), { recursive: true });
	fs.writeFileSync(file, JSON.stringify(cur, null, 2) + "\n");
	console.log(`cloud-bootstrap: merged ${target}`);
};
merge(".cursor/hooks.json", "templates/cursor/.cursor/hooks.json", true);
merge(".claude/settings.json", "templates/claude/.claude/settings.json", false);
JS

# Keep generated files out of the agent's diffs (local exclude, never committed).
if [ -d .git ]; then
	for p in .agent-hooks/ .cursor/skills/ .claude/skills/ .cursor/mcp.json .mcp.json; do grep -qxF "$p" .git/info/exclude 2>/dev/null || echo "$p" >> .git/info/exclude; done
fi
echo "cloud-bootstrap: done ($(ls "$SKILLS" | wc -l | tr -d ' ') skills, hooks from $HOOKS_SOURCE)"
