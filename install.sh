#!/bin/sh
# Install workfree (`wf`).
#
# From a clone:   ./install.sh
# From the web:   curl -fsSL https://raw.githubusercontent.com/OwaisQuadri/workfree/rust-rewrite/install.sh | sh
#
# Env vars:
#   WF_INSTALL_DIR  where the binary goes   (default: ~/.local/bin)
#   WF_REF          git branch/tag to build (default: rust-rewrite, only used when not run from a clone)
set -eu

REPO_URL="https://github.com/OwaisQuadri/workfree.git"
REF="${WF_REF:-rust-rewrite}"
INSTALL_DIR="${WF_INSTALL_DIR:-$HOME/.local/bin}"
BIN="wf"

say() { printf '\033[1m==>\033[0m %s\n' "$1"; }
die() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }

case "$(uname -s)" in
    Linux|Darwin) ;;
    *) die "unsupported OS: $(uname -s) (workfree supports Linux and macOS)" ;;
esac

# 1. Make sure cargo is available, offer rustup if not.
if ! command -v cargo >/dev/null 2>&1 && [ -x "$HOME/.cargo/bin/cargo" ]; then
    PATH="$HOME/.cargo/bin:$PATH"
fi
if ! command -v cargo >/dev/null 2>&1; then
    say "Rust (cargo) not found. Installing it with rustup..."
    command -v curl >/dev/null 2>&1 || die "curl is required to install Rust"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
    PATH="$HOME/.cargo/bin:$PATH"
fi

# 2. Find the source: use this directory if it's the repo, otherwise clone it.
SCRIPT_DIR=""
case "$0" in
    */*) SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)" ;;
esac

if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/Cargo.toml" ]; then
    SRC="$SCRIPT_DIR"
else
    command -v git >/dev/null 2>&1 || die "git is required"
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    say "Cloning $REPO_URL ($REF)..."
    git clone --quiet --depth 1 --branch "$REF" "$REPO_URL" "$TMP/workfree"
    SRC="$TMP/workfree"
fi

# 3. Build and install.
say "Building release binary..."
cargo build --release --locked --manifest-path "$SRC/Cargo.toml"

mkdir -p "$INSTALL_DIR"
install -m 755 "$SRC/target/release/$BIN" "$INSTALL_DIR/$BIN"
say "Installed $BIN to $INSTALL_DIR/$BIN"

# 4. PATH hint.
case ":$PATH:" in
    *":$INSTALL_DIR:"*) say "Done. Run '$BIN --help' to get started." ;;
    *)
        say "Done, but $INSTALL_DIR is not on your PATH. Add this to your shell config:"
        printf '\n    export PATH="%s:$PATH"\n\n' "$INSTALL_DIR"
        ;;
esac
