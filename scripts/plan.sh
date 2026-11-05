#!/usr/bin/env bash
# usage: scripts/plan.sh <installable> <derivation-name-pattern>
#
# Says whether Nix would BUILD the derivation whose name matches the pattern
# (an extended regexp on the .drv name, e.g. 'ghc-wasm-native-[0-9.]+\.drv$')
# or FETCH it, without building anything. Prints the derivation path and
# `BUILT` or `FETCHED` on stdout; the dry-run report goes to stderr.
set -euo pipefail
installable=$1 pattern=$2
drv=$(nix path-info --derivation "$installable")
plan=$(nix build --dry-run "$installable" 2>&1)
echo "$plan" >&2
# Lines under "... will be built:" are indented derivation paths; the section
# ends at the first line that is not indented.
built=$(printf '%s\n' "$plan" | awk '
  /will be built:$/ { on = 1; next }
  on && /^  \// { print; next }
  { on = 0 }' | grep -E "$pattern" || true)
if [ -n "$built" ]; then state=BUILT; else state=FETCHED; fi
echo "$drv $state"
