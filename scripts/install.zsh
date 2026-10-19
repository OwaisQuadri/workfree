#!/bin/zsh
set -euo pipefail
if [[ "${1:-}" = --help ]]; then
  print 'Usage: scripts/install.zsh [--prefix DIRECTORY]'
  print 'Build and install Workfree. Existing commands are never replaced. Pi and Herdr activation are separate.'
  exit 0
fi
prefix=$HOME/.local
if [[ "${1:-}" = --prefix && $# -eq 2 ]]; then
  prefix=$2
elif [[ $# -ne 0 ]]; then
  print -u2 'Specify --prefix DIRECTORY or no arguments.'
  exit 2
fi
prefix=${prefix:A}
for target in "$prefix/bin/wf" "$prefix/bin/wf-herdr-open" "$prefix/bin/wf-herdr-close" "$prefix/share/workfree"; do
  [[ ! -e "$target" && ! -L "$target" ]] || { print -u2 "Installation target already exists: $target"; exit 1; }
done
root=${0:A:h:h}
cd "$root"
swift build -c release -Xswiftc -warnings-as-errors
build_dir=$(swift build -c release --show-bin-path)
[[ -x "$build_dir/wf" ]] || { print -u2 'The built executable is unavailable.'; exit 1; }
install -d "$prefix/bin" "$prefix/share"
staging=$(mktemp -d "$prefix/.workfree-install.XXXXXX")
trap 'rm -rf -- "$staging"' EXIT
install -d "$staging/bin" "$staging/share/workfree/herdr"
for name in open close event sizes; do
  install -m 755 "integrations/herdr/wf-herdr-$name.zsh" "$staging/share/workfree/herdr/wf-herdr-$name.zsh"
done
install -m 755 integrations/herdr/wf-herdr-open.zsh "$staging/bin/wf-herdr-open"
install -m 755 integrations/herdr/wf-herdr-close.zsh "$staging/bin/wf-herdr-close"
install -m 644 integrations/herdr/herdr-plugin.toml "$staging/share/workfree/herdr/herdr-plugin.toml"
install -m 755 "$build_dir/wf" "$staging/bin/wf"
swift -warnings-as-errors "$root/scripts/publish-install.swift" "$staging" "$prefix"
"$prefix/bin/wf" --version
print 'Installed. Pi and Herdr activation are separate operations.'
