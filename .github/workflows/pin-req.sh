#!/usr/bin/env bash
# Pin the :req dependency to an exact version so a compatibility matrix
# job exercises one specific point of the range declared in mix.exs.
#
# Dependency resolution always picks the newest version a constraint
# allows, and `mix deps.update --to` is a no-op for this, so the only
# reliable way to test the floor of a range is to rewrite the constraint
# before resolving. This edit is scratch-only; CI never commits it.
set -euo pipefail

version="${1:?usage: pin-req.sh <version>}"

# Fail loudly rather than silently testing the wrong version if the
# constraint in mix.exs is ever reworded.
if ! grep -qE '\{:req, "[^"]+"\}' mix.exs; then
  echo "pin-req: no {:req, \"...\"} dependency found in mix.exs" >&2
  exit 1
fi

perl -pi -e 'BEGIN { $v = shift } s/\{:req, "[^"]+"\}/{:req, "$v"}/' "$version" mix.exs

grep -E '\{:req, ' mix.exs

rm -f mix.lock
mix deps.get

resolved=$(grep -oE '"req": \{:hex, :req, "[^"]+"' mix.lock | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
echo "resolved req: $resolved"

if [ "$resolved" != "$version" ]; then
  echo "pin-req: expected req $version but resolved $resolved" >&2
  exit 1
fi
