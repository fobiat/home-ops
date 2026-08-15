#!/usr/bin/env bash
# Measures the comment ratio across tracked YAML, and fails past the ceiling.
# See AGENTS.md rule 2: target 3 to 5 percent, 10 percent is a defect.
set -euo pipefail

CEILING="${COMMENT_CEILING:-10}"

mapfile -t files < <(git ls-files '*.yaml' '*.yml' '*.sh' ':!:.archive/**' ':!:**/*.sops.yaml')
[[ ${#files[@]} -eq 0 ]] && { echo "no files to measure"; exit 0; }

total=0
comments=0
for f in "${files[@]}"; do
  [[ -f $f ]] || continue
  t=$(grep -cve '^[[:space:]]*$' "$f" || true)
  c=$(grep -ce '^[[:space:]]*#' "$f" || true)
  total=$((total + t))
  comments=$((comments + c))
done

[[ $total -eq 0 ]] && { echo "no non-blank lines"; exit 0; }
pct=$(awk -v c="$comments" -v t="$total" 'BEGIN { printf "%.1f", (c/t)*100 }')

printf 'comment lines: %d of %d non-blank (%s%%), ceiling %s%%\n' \
  "$comments" "$total" "$pct" "$CEILING"

awk -v p="$pct" -v ceil="$CEILING" 'BEGIN { exit (p > ceil) ? 1 : 0 }' || {
  echo "over the ceiling. Move the reasoning into docs/ instead." >&2
  exit 1
}
