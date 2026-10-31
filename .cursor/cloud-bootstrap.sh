#!/usr/bin/env bash
# Cloud bootstrap for agent-hooks, in two phases:
#   bootstrap.sh install  token-free (Cursor `install` / Claude setup script): toolchain checks only; safe without secrets.
#   bootstrap.sh start    needs runtime secret PI_CONFIG_TOKEN (Cursor `start` / Claude SessionStart): clones pi-config,
#                         agents-config, the pi fork, extensions, checker repos; installs skills, hooks, MCP, pi, checkers.
# Idempotent: start skips any component whose upstream commit is unchanged (stamps in $BOOTSTRAP_CACHE), so repeat starts
# cost a few `git ls-remote` calls. Required steps (clones, skills, hook scripts, hook config) stop the script on error.
# Optional steps (Linux checkers, pi, extensions, MCP) run isolated: a failure prints a loud ERROR, the hooks still
# install, and the script exits non-zero at the end with a summary.
set -euo pipefail
set +x
trap 'echo "cloud-bootstrap: FAILED at line $LINENO" >&2' ERR
MODE=${1:-start}

# Claude Code cloud runs hooks with CLAUDE_PROJECT_DIR (e.g. /home/user/repo); honor it so the hooks land in <repo>/.agent-hooks.
PROJECT=${CLAUDE_PROJECT_DIR:-$(pwd)}
cd "$PROJECT"
PI_CONFIG_REPO=${PI_CONFIG_REPO:-OwaisQuadri/pi-config}
# agent-hooks/ lives only on agent-hooks/cloud until that branch is merged into main.
PI_CONFIG_REF=${PI_CONFIG_REF:-agent-hooks/cloud}
AGENTS_CONFIG_REPO=${AGENTS_CONFIG_REPO:-OwaisQuadri/agents-config}
# 1 = build command-guard, edit-time-check and affected-tests for Linux from source (needs Swift 6.4, clang, zsh, tree-sitter 0.27.1).
# Default 1 on Linux (cloud): without Linux checkers the command and comment-shape guards deny everything.
if [ "$(uname -s)" = Linux ]; then BUILD_CHECKERS=${BUILD_CHECKERS:-1}; else BUILD_CHECKERS=${BUILD_CHECKERS:-0}; fi
# 1 = install missing checker toolchain pieces (apt packages via sudo, libtree-sitter from source, Swift via swiftly).
PROVISION_TOOLCHAIN=${PROVISION_TOOLCHAIN:-1}
TREE_SITTER_VERSION=${TREE_SITTER_VERSION:-0.27.1}
CHECKERS_SWIFT_VERSION=${CHECKERS_SWIFT_VERSION:-6.4}
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
export PATH="$HOME/.local/bin:$HOME/.local/share/swiftly/bin:$PATH"
ERRORS=()
# soft name cmd...: run an optional step in a subshell with errexit on; on failure log loudly and continue.
soft() {
	local name=$1 rc; shift
	set +e; (set -e; "$@"); rc=$?; set -e
	if [ $rc -ne 0 ]; then ERRORS+=("$name"); echo "cloud-bootstrap: ERROR optional step '$name' failed (exit $rc); continuing so the hooks still install" >&2; fi
	return 0
}
SUDO=; [ "$(id -u)" = 0 ] || { command -v sudo >/dev/null && sudo -n true 2>/dev/null && SUDO=sudo; }
# libtree-sitter lives in /usr/local when we can write there (root or sudo), else ~/.local.
if [ -z "${TREE_SITTER_PREFIX:-}" ]; then
	if ls /usr/local/lib/libtree-sitter.so* >/dev/null 2>&1 || [ -w /usr/local/lib ] || [ -n "$SUDO" ]; then TREE_SITTER_PREFIX=/usr/local; else TREE_SITTER_PREFIX=$HOME/.local; fi
fi
export TREE_SITTER_PREFIX
has_fd() { command -v fd >/dev/null || command -v fdfind >/dev/null; }
provision_toolchain() {
	if [ "$(uname -s)" = Linux ] && command -v apt-get >/dev/null; then
		local pkgs=()
		command -v clang >/dev/null || pkgs+=(clang); command -v zsh >/dev/null || pkgs+=(zsh); command -v rg >/dev/null || pkgs+=(ripgrep)
		has_fd || pkgs+=(fd-find); command -v make >/dev/null || pkgs+=(make); command -v curl >/dev/null || pkgs+=(curl ca-certificates)
		command -v pkg-config >/dev/null || pkgs+=(pkg-config)
		# Swift toolchain runtime deps (swift.org Ubuntu list) plus gpg for swiftly's signature check, only when Swift is missing.
		swift --version 2>/dev/null | grep -q "Swift version $CHECKERS_SWIFT_VERSION" || pkgs+=(gnupg gnupg2 zip binutils git unzip libc6-dev libcurl4-openssl-dev libedit2 libgcc-13-dev libpython3-dev libsqlite3-0 libstdc++-13-dev libxml2-dev libncurses-dev libz3-dev tzdata zlib1g-dev)
		if [ ${#pkgs[@]} -gt 0 ]; then
			[ "$(id -u)" = 0 ] || [ -n "$SUDO" ] || die "missing ${pkgs[*]} and no root/sudo to apt-get them"
			echo "cloud-bootstrap: apt-get install ${pkgs[*]}"
			$SUDO apt-get update -qq && DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq --no-install-recommends "${pkgs[@]}" >/dev/null
		fi
		# C++ standard library headers for the GCC install clang selects (the highest /usr/lib/gcc/<triple>/N, which may lack
		# libstdc++-N-dev, e.g. gcc-14 runtime present but only libstdc++-13-dev): swift-crypto's CCryptoBoringSSL needs <memory>.
		local gccv; gccv=$(clang -v 2>&1 | sed -n 's|^Selected GCC installation: .*/\([0-9][0-9]*\)$|\1|p')
		if [ -n "$gccv" ] && ! echo '#include <memory>' | clang++ -x c++ -fsyntax-only - 2>/dev/null; then
			[ "$(id -u)" = 0 ] || [ -n "$SUDO" ] || die "C++ headers missing (need libstdc++-$gccv-dev) and no root/sudo to apt-get them"
			echo "cloud-bootstrap: apt-get install libstdc++-$gccv-dev libgcc-$gccv-dev (C++ headers for clang's GCC $gccv)"
			$SUDO apt-get update -qq && DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq --no-install-recommends "libstdc++-$gccv-dev" "libgcc-$gccv-dev" >/dev/null
			echo '#include <memory>' | clang++ -x c++ -fsyntax-only - || die "clang++ still cannot find <memory> after installing libstdc++-$gccv-dev"
		fi
	fi
	if ! ls "$TREE_SITTER_PREFIX"/lib/libtree-sitter.so."${TREE_SITTER_VERSION%.*}"* >/dev/null 2>&1; then
		echo "cloud-bootstrap: building libtree-sitter $TREE_SITTER_VERSION into $TREE_SITTER_PREFIX"
		local tmp; tmp=$(mktemp -d)
		curl -fsSL "https://github.com/tree-sitter/tree-sitter/archive/refs/tags/v$TREE_SITTER_VERSION.tar.gz" | tar xz -C "$tmp"
		make -s -C "$tmp/tree-sitter-$TREE_SITTER_VERSION" PREFIX="$TREE_SITTER_PREFIX" >/dev/null
		if [ -w "$TREE_SITTER_PREFIX" ] || [ "$TREE_SITTER_PREFIX" = "$HOME/.local" ]; then mkdir -p "$TREE_SITTER_PREFIX"; make -s -C "$tmp/tree-sitter-$TREE_SITTER_VERSION" PREFIX="$TREE_SITTER_PREFIX" install >/dev/null
		else $SUDO make -s -C "$tmp/tree-sitter-$TREE_SITTER_VERSION" PREFIX="$TREE_SITTER_PREFIX" install >/dev/null; fi
		{ [ "$(id -u)" = 0 ] || [ -n "$SUDO" ]; } && $SUDO ldconfig 2>/dev/null || true
		rm -rf "$tmp"
	fi
	if ! swift --version 2>/dev/null | grep -q "Swift version $CHECKERS_SWIFT_VERSION"; then
		echo "cloud-bootstrap: installing Swift $CHECKERS_SWIFT_VERSION with swiftly (into ~/.local/share/swiftly)"
		local tmp; tmp=$(mktemp -d)
		curl -fsSL "https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz" | tar xz -C "$tmp"
		export SWIFTLY_HOME_DIR=${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly} SWIFTLY_BIN_DIR=${SWIFTLY_BIN_DIR:-$HOME/.local/share/swiftly/bin}
		"$tmp/swiftly" init --quiet-shell-followup --assume-yes --skip-install
		# shellcheck disable=SC1091
		. "$SWIFTLY_HOME_DIR/env.sh"
		swiftly install --use --assume-yes "$CHECKERS_SWIFT_VERSION"
		hash -r; rm -rf "$tmp"
	fi
}
check_toolchain() {
	command -v swift >/dev/null && swift --version 2>&1 | grep -q "Swift version $CHECKERS_SWIFT_VERSION" || die "need Swift $CHECKERS_SWIFT_VERSION on PATH"
	need clang; need zsh; need rg; has_fd || die "fd/fdfind missing"
	ls "$TREE_SITTER_PREFIX"/lib/libtree-sitter.so* >/dev/null 2>&1 || die "tree-sitter $TREE_SITTER_VERSION not found under $TREE_SITTER_PREFIX"
}
# tree-sitter CLI (edit-time-check tests run `tree-sitter generate`). Prebuilt release binary from GitHub (public, token-free,
# no npm/node needed); skipped when the right version is present.
# It must be on the agent's PATH, not just this script's: with root or sudo it goes to /usr/local (bin on every PATH);
# otherwise to ~/.local, and ~/.local/bin is added to ~/.profile and ~/.bashrc.
TREE_SITTER_CLI_PREFIX=${TREE_SITTER_CLI_PREFIX:-}
install_tree_sitter_cli() {
	local prefix=$TREE_SITTER_CLI_PREFIX run=
	if [ -z "$prefix" ]; then if [ "$(id -u)" = 0 ] || [ -n "$SUDO" ]; then prefix=/usr/local; else prefix=$HOME/.local; fi; fi
	[ "$prefix" = /usr/local ] && [ "$(id -u)" != 0 ] && run=$SUDO
	if [ "$("$prefix/bin/tree-sitter" --version 2>/dev/null | cut -d' ' -f2)" != "$TREE_SITTER_CLI_VERSION" ]; then
		need curl "needed for the tree-sitter CLI"; need gzip "needed for the tree-sitter CLI"
		local arch
		case "$(uname -m)" in
			x86_64|amd64) arch=x64 ;;
			aarch64|arm64) arch=arm64 ;;
			armv7l|armv6l) arch=arm ;;
			i386|i686) arch=x86 ;;
			ppc64le|ppc64) arch=powerpc64 ;;
			*) die "no prebuilt tree-sitter CLI for $(uname -m)" ;;
		esac
		local url="https://github.com/tree-sitter/tree-sitter/releases/download/v$TREE_SITTER_CLI_VERSION/tree-sitter-linux-$arch.gz"
		echo "cloud-bootstrap: downloading tree-sitter CLI $TREE_SITTER_CLI_VERSION ($arch) into $prefix/bin"
		local tmp; tmp=$(mktemp)
		curl -fsSL --retry 3 "$url" | gzip -dc > "$tmp" || { rm -f "$tmp"; die "tree-sitter CLI download failed: $url"; }
		chmod 755 "$tmp"
		$run mkdir -p "$prefix/bin"
		$run rm -f "$prefix/bin/tree-sitter"  # may be a symlink left by an earlier npm install
		$run install -m 755 "$tmp" "$prefix/bin/tree-sitter"; rm -f "$tmp"
	fi
	if [ "$prefix" = "$HOME/.local" ]; then
		for rc in "$HOME/.profile" "$HOME/.bashrc"; do grep -qF '.local/bin' "$rc" 2>/dev/null || printf '\nexport PATH="$HOME/.local/bin:$PATH"  # cloud-bootstrap: tree-sitter CLI\n' >> "$rc"; done
		case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac
	fi
	hash -r
	local found; found=$(tree-sitter --version 2>&1 | head -1)
	[ "$(echo "$found" | cut -d' ' -f2)" = "$TREE_SITTER_CLI_VERSION" ] || die "tree-sitter CLI $TREE_SITTER_CLI_VERSION does not run after install: $found (the prebuilt CLI needs glibc >= 2.39, e.g. Ubuntu 24.04)"
	echo "cloud-bootstrap: tree-sitter CLI $TREE_SITTER_CLI_VERSION at $(command -v tree-sitter)"
}
if [ "$BUILD_CHECKERS" = 1 ]; then
	[ "$PROVISION_TOOLCHAIN" = 1 ] && soft "provision checker toolchain" provision_toolchain
	[ -f "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh" ] && . "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh"
	soft "checker toolchain check" check_toolchain
	soft "tree-sitter CLI" install_tree_sitter_cli
fi
finish() {
	if [ ${#ERRORS[@]} -gt 0 ]; then
		echo "cloud-bootstrap: ==== FAILED optional steps: ${ERRORS[*]} ====" >&2
		# install mode only checks the toolchain; still exit 0 so a caller chaining `install && start` installs the hooks.
		[ "$MODE" = install ] && { echo "cloud-bootstrap: optional toolchain steps failed; continue with start so the hooks still install" >&2; return 0; }
		echo "cloud-bootstrap: hooks are installed, but guards that need a missing piece fail closed. Fix the steps above and rerun." >&2
		exit 1
	fi
}
case "$MODE" in
	install) finish; echo "cloud-bootstrap: install checks passed (token-free; run 'start' at runtime)"; exit 0 ;;
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

# Merge hook config (required, runs before the optional steps so a later failure cannot skip it): keep foreign entries, add each guard once. An entry already running the same
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

# edit-time-check's privacy rule reads ~/.config/privacy-lint/identifiers (or $PRIVACY_LINT_IDENTIFIERS); when the file is
# missing every selected write fails with "Cannot read private identifier configuration" and the comment-shape guard
# denies it as a checker error. The list is private, so it never comes from a repo: set PRIVACY_IDENTIFIERS_TEXT (one
# identifier per line) as a runtime secret, or the file starts empty (generic privacy checks only). An existing file wins.
ensure_privacy_identifiers() {
	local file=${PRIVACY_LINT_IDENTIFIERS:-$HOME/.config/privacy-lint/identifiers}
	[ -f "$file" ] && return 0
	mkdir -p "$(dirname "$file")"; ( umask 077; printf '%s' "${PRIVACY_IDENTIFIERS_TEXT:-}" > "$file" )
	if [ -n "${PRIVACY_IDENTIFIERS_TEXT:-}" ]; then echo "cloud-bootstrap: wrote $file from PRIVACY_IDENTIFIERS_TEXT"
	else echo "cloud-bootstrap: WARNING created empty $file (set PRIVACY_IDENTIFIERS_TEXT to screen your private identifiers)" >&2; fi
}
ensure_privacy_identifiers

# Linux checkers from the linux-build branches, built once per commit, then placed where the hooks look
# (.agent-hooks/vendor/pi/agent/checkers, replacing the macOS binaries that cannot run here).
build_checkers() {
# edit-time-check links with --no-warn-rwx-segments, which gold before binutils 2.44 (Ubuntu 24.04 has 2.42) rejects.
# There, a build-only `swift` wrapper first on PATH makes `swift build` link through a gold wrapper that drops only that
# flag (it silences a warning, nothing else). The VM's swift and linker are untouched.
if command -v ld.gold >/dev/null && ! ld.gold --no-warn-rwx-segments --version >/dev/null 2>&1; then
	shim="$WORK/swift-shim"; mkdir -p "$shim"
	printf '#!/bin/bash\na=(); for x in "$@"; do [ "$x" = --no-warn-rwx-segments ] || a+=("$x"); done\nexec %s "${a[@]}"\n' "$(command -v ld.gold)" > "$shim/ld.gold-compat"
	printf '#!/bin/sh\n[ "$1" = build ] && { shift; exec %s build -Xswiftc -use-ld=%s "$@"; }\nexec %s "$@"\n' "$(command -v swift)" "$shim/ld.gold-compat" "$(command -v swift)" > "$shim/swift"
	chmod +x "$shim/swift" "$shim/ld.gold-compat"; export PATH="$shim:$PATH"
	echo "cloud-bootstrap: ld.gold $(ld.gold --version | head -1 | awk '{print $NF}') rejects --no-warn-rwx-segments; checkers link through $shim/ld.gold-compat"
fi
# swift may be a swiftly proxy, so locate swift-syntax host libs from the real toolchain's resource dir.
[ -n "${SWIFT_HOST_LIB:-}" ] || { SWIFT_HOST_LIB="$(swiftc -print-target-info | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).paths.runtimeResourcePath))')/host"; export SWIFT_HOST_LIB; }
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
	# The hook requires canonical paths (realpath === path) for rg and fd.
RG=$(readlink -f "$(command -v rg)"); FD=$(readlink -f "$(command -v fd || command -v fdfind)")
	digest=$(sha256sum "$CHECKERS_OUT/checkers/command-guard" | cut -d' ' -f1)
	printf '{"version":2,"sha256":"%s","rgExecutable":"%s","fdExecutable":"%s"}\n' "$digest" "$RG" "$FD" > "$CHECKERS_OUT/checkers/command-guard.json"
	"$CHECKERS_OUT/checkers/command-guard" --guidance-json >/dev/null || die "Linux command-guard does not run"
	dest=.agent-hooks/vendor/pi/agent/checkers; mkdir -p "$dest"
	rm -rf "$dest/edit-time-check" "$dest/lib" "$dest/parsers"
	cp -R "$CHECKERS_OUT/edit-time-check/." "$dest/"
	cp -p "$CHECKERS_OUT/checkers/command-guard" "$CHECKERS_OUT/checkers/command-guard.json" "$dest/"
	# edit-time-check's default parser root (hooks pass no --parser-root).
	mkdir -p "$HOME/.local/lib/agents-tree-sitter"; ln -sfn "$CHECKERS_OUT/edit-time-check/parsers" "$HOME/.local/lib/agents-tree-sitter/parsers"
}
# verify_checkers: the hooks need these Linux binaries; anything missing is an ERROR, never silent.
verify_checkers() {
	local d=.agent-hooks/vendor/pi/agent/checkers bad=0
	for f in command-guard edit-time-check; do
		if [ ! -x "$d/$f" ] || [ "$(head -c4 "$d/$f" | od -An -c | tr -d ' ')" != '177ELF' ]; then
			echo "cloud-bootstrap: ERROR checker $d/$f is missing or not a Linux binary; its guard will deny (fail closed)" >&2; bad=1
		fi
	done
	[ -x "$d/command-guard" ] && { "$d/command-guard" --guidance-json >/dev/null 2>&1 || { echo "cloud-bootstrap: ERROR $d/command-guard does not run" >&2; bad=1; }; }
	# End to end through the hook: a harmless command must be allowed, or every shell command will be denied.
	local verdict
	verdict=$(printf '{"hook_event_name":"preToolUse","tool_name":"Shell","tool_input":{"command":"git status"},"cwd":"%s"}' "$PROJECT" | node .agent-hooks/hooks/command-guard.mjs 2>&1 || true)
	case "$verdict" in *'"deny"'*|*'"ask"'*) echo "cloud-bootstrap: ERROR command-guard hook denies 'git status': $verdict" >&2; bad=1 ;; esac
	# Comment-shape guard end to end: a bare TODO comment must be blocked by the comment-shape rule (not a checker error),
	# and plain text must pass; a checker error here means a missing piece (parsers, config, identifiers file).
	verdict=$(printf '{"hook_event_name":"preToolUse","tool_name":"Write","tool_input":{"file_path":"%s/.agent-hooks/verify.swift","contents":"// TODO\\n"},"cwd":"%s"}' "$PROJECT" "$PROJECT" | node .agent-hooks/hooks/comment-shape-guard.mjs 2>&1 || true)
	case "$verdict" in *'comment-shape:'*) ;; *) echo "cloud-bootstrap: ERROR comment-shape guard did not block a TODO comment by policy: $verdict" >&2; bad=1 ;; esac
	verdict=$(printf '{"hook_event_name":"preToolUse","tool_name":"Write","tool_input":{"file_path":"%s/.agent-hooks/verify.txt","contents":"plain text\\n"},"cwd":"%s"}' "$PROJECT" "$PROJECT" | node .agent-hooks/hooks/comment-shape-guard.mjs 2>&1 || true)
	case "$verdict" in *'"deny"'*) echo "cloud-bootstrap: ERROR comment-shape guard denies plain text: $verdict" >&2; bad=1 ;; esac
	if [ "$BUILD_CHECKERS" = 1 ]; then command -v tree-sitter >/dev/null || { echo "cloud-bootstrap: ERROR tree-sitter CLI is not on PATH" >&2; bad=1; }; fi
	return $bad
}
if [ "$(uname -s)" = Linux ]; then
	if [ "$BUILD_CHECKERS" = 1 ]; then soft "Linux checkers build" build_checkers
	else echo "cloud-bootstrap: WARNING BUILD_CHECKERS=0 on Linux; command and comment-shape guards will deny (fail closed)" >&2; fi
	soft "checker verification" verify_checkers
fi

# pi: build the fork, install globally, then extensions from local clones and the public packages.
install_pi() {
	PI_DIR=${PI_DIR:-$HOME/.local/share/pi-fork}
	fetch "$PI_REPO" "$PI_DIR"
	if ! command -v pi >/dev/null || ! stamp pi "$(rev "$PI_DIR")"; then
		# build:offline checks packages/ai/src/providers/data (gitignored); hydrate:model-data generates it first.
		(cd "$PI_DIR" && npm ci --ignore-scripts && npm run hydrate:model-data && npm run build:offline) || die "pi build failed"
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
}
[ "$INSTALL_PI" = 1 ] && soft "pi install" install_pi

# Instructions: pi-config AGENTS.md is used only when the project has none; Claude reads it via CLAUDE.md import.
if [ ! -e AGENTS.md ] && [ -f "$WORK/pi-config/AGENTS.md" ]; then cp "$WORK/pi-config/AGENTS.md" AGENTS.md; GENERATED_EXCLUDES="${GENERATED_EXCLUDES:-} AGENTS.md"; fi
if [ -e AGENTS.md ] && [ ! -e CLAUDE.md ]; then printf '@AGENTS.md\n' > CLAUDE.md; GENERATED_EXCLUDES="${GENERATED_EXCLUDES:-} CLAUDE.md"; fi

# MCP: only allowlisted servers ($MCP_ALLOW) from pi-config mcp.json into .cursor/mcp.json and .mcp.json. Existing servers win; stdio servers
# whose command is not installed here are skipped. Env values are copied, never printed.
merge_mcp() {
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
}
soft "MCP merge" merge_mcp

# Keep generated files out of the agent's diffs (local exclude, never committed).
if [ -d .git ]; then
	for p in .agent-hooks/ .cursor/skills/ .claude/skills/ .cursor/mcp.json .mcp.json .swift-version ${GENERATED_EXCLUDES:-}; do grep -qxF "$p" .git/info/exclude 2>/dev/null || echo "$p" >> .git/info/exclude; done
fi
echo "cloud-bootstrap: done ($(ls "$SKILLS" | wc -l | tr -d ' ') skills, hooks from $HOOKS_SOURCE)"
finish
