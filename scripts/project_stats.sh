#!/usr/bin/env sh
# Recompute the figures the README and the Chinese proposal quote.
#
# Those documents cite a commit count, a diff size, a test count and a coverage
# ratio. Every one of them goes stale as work continues, so this script derives
# them rather than leaving them to be remembered. Run it before submitting and
# update the two documents if anything moved.
set -eu

cd "$(dirname "$0")/.."

first="$(git rev-list --max-parents=0 HEAD)"

printf 'Baseline commit (pre-version-control implementation)\n'
printf '  %s  %s\n\n' "$(git log -1 --format=%h "$first")" "$(git log -1 --format=%s "$first")"

printf 'Work completed since that commit\n'
printf '  commits:   %s\n' "$(git log --oneline "$first..HEAD" | wc -l | tr -d ' ')"
printf '  diff:      %s\n' "$(git diff --shortstat "$first" HEAD | sed 's/^ *//')"
printf '  MoonBit:   %s lines now, %s lines at the baseline\n' \
  "$(git ls-files '*.mbt' | xargs wc -l | tail -1 | awk '{print $1}')" \
  "$(git ls-tree -r "$first" --name-only | grep '\.mbt$' \
     | while read -r f; do git show "$first:$f"; done | wc -l | tr -d ' ')"

printf '\nTests and coverage\n'
moon coverage clean >/dev/null 2>&1 || true
moon test --enable-coverage 2>&1 | tail -1 | sed 's/^/  /'
summary="$(moon coverage report -f summary 2>&1)"
total="$(printf '%s' "$summary" | grep '^Total:' | awk '{print $2}')"
cli="$(printf '%s' "$summary" | grep 'main.mbt:' | awk '{print $2}')"
covered="${total%%/*}"
overall="${total##*/}"
cli_lines="${cli##*/}"
printf '  library:   %s/%s lines\n' "$covered" "$((overall - cli_lines))"
printf '  cli:       %s (covered by scripts/cli_smoke.sh instead)\n' "$cli"
