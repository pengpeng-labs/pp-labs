#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
compiler="${1:-$root/pplc/target/debug/pp}"

if [[ ! -x "$compiler" ]]; then
  echo "compiler not found: $compiler" >&2
  echo "build it with: cd pplc && cargo build" >&2
  exit 1
fi

count=0
while IFS= read -r source; do
  "$compiler" ir "$source" >/dev/null
  count=$((count + 1))
done < <(find "$root/tutorial/examples/pplang" -name '*.pp' -type f | sort)

echo "tutorial examples: $count passed"
