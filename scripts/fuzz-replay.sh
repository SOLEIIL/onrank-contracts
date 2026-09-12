#!/usr/bin/env bash
# Release gate G1: replay the whole suite with the documented fuzz seeds (docs/08). Exit 1 if any seed fails.
cd "$(dirname "$0")/.."
export PATH="$HOME/.acton/bin:$PATH"
rc=0
for s in 11 23 37 59 71 97; do
  out=$(acton test --fuzz-seed "$s" 2>&1 | grep -E ' passed| failed' | tail -n 1)
  echo "seed $s: $out"
  echo "$out" | grep -q ' failed' && rc=1
done
exit $rc
