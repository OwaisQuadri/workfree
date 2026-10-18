#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build -c release -Xswiftc -warnings-as-errors
swift test -Xswiftc -warnings-as-errors
swift format lint --strict --recursive Package.swift Sources Tests scripts
npm run typecheck
npm test
for script in scripts/*.zsh integrations/herdr/*.zsh; do
  /bin/zsh -n "$script"
done
git diff --check
