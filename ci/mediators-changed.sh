#!/usr/bin/env bash
# Tells whether HomeOmnibridge or ForeignOmnibridge changed compared with a base commit, which decides
# whether the upgrade e2e test (test-e2e/Upgrade.t.sol) has to run.
#
#   ci/mediators-changed.sh <base commit>
#
# Prints "true" or "false" on stdout (and writes changed=... to $GITHUB_OUTPUT in CI).
#   1. Nothing under contracts/ changed: false.
#   2. Otherwise both mediators are built at the base commit and at HEAD, and their deployed bytecode compared.
#      This catches changes in any inherited contract or library, and ignores changes that do not reach the
#      mediators. The metadata hash is turned off, so comment-only edits do not count.
#   3. If the base cannot be built (e.g. it predates the Foundry setup), assume a change: true.
set -euo pipefail
cd "$(dirname "$0")/.."

base=${1:?usage: $0 <base commit>}
export FOUNDRY_BYTECODE_HASH=none FOUNDRY_DISABLE_NIGHTLY_WARNING=1

result() {
  echo "$1"
  [ -n "${GITHUB_OUTPUT:-}" ] && echo "changed=$1" >>"$GITHUB_OUTPUT"
  exit 0
}

if git diff --quiet "$base" HEAD -- contracts/; then
  echo "No changes under contracts/ since $base" >&2
  result false
fi

bytecode() {
  forge inspect "$1" deployedBytecode 2>/dev/null
}

head_code="$(bytecode HomeOmnibridge)$(bytecode ForeignOmnibridge)"
[ -n "$head_code" ] || { echo "Could not build the mediators at HEAD" >&2; exit 1; }

worktree=$(mktemp -d)
trap 'git worktree remove --force "$worktree" >/dev/null 2>&1 || true' EXIT
git worktree add --detach "$worktree" "$base" >/dev/null 2>&1
# dependencies are not part of the commit: reuse the ones installed for HEAD
ln -s "$PWD/node_modules" "$worktree/node_modules"
rm -rf "$worktree/lib" && ln -s "$PWD/lib" "$worktree/lib"

base_code=$(cd "$worktree" && echo "$(bytecode HomeOmnibridge)$(bytecode ForeignOmnibridge)" || true)
if [ -z "$base_code" ]; then
  echo "Could not build the mediators at $base, assuming they changed" >&2
  result true
fi

if [ "$head_code" = "$base_code" ]; then
  echo "Mediator bytecode unchanged since $base" >&2
  result false
fi
echo "Mediator bytecode changed since $base" >&2
result true
