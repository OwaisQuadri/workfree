#!/bin/zsh
set -euo pipefail
ref=${WORKFREE_REF:-main}
work=$(mktemp -d "${TMPDIR:-/tmp}/workfree-bootstrap.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
curl -fsSL "https://codeload.github.com/OwaisQuadri/workfree/tar.gz/$ref" | tar -xz -C "$work" --strip-components 1
"$work/scripts/install.zsh" "$@"
