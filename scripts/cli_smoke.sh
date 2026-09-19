#!/usr/bin/env sh
# Exercise every command and exit code documented in README.md.
#
# The CLI is the contract that CI pipelines depend on, so each documented
# invocation is asserted here rather than only described in prose.
set -eu

cd "$(dirname "$0")/.."

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

failures=0

# run <expected-exit> <description> -- <cli arguments...>
run() {
  expected="$1"
  description="$2"
  shift 3
  set +e
  output="$(moon run cmd/main -- "$@" 2>&1)"
  actual=$?
  set -e
  if [ "$actual" != "$expected" ]; then
    printf 'FAIL %s\n  expected exit %s, got %s\n%s\n' \
      "$description" "$expected" "$actual" "$output" >&2
    failures=$((failures + 1))
    return
  fi
  printf '%s' "$output" > "$work_dir/last_output"
  printf 'ok   %s (exit %s)\n' "$description" "$actual"
}

expect_output() {
  if ! grep -q -- "$1" "$work_dir/last_output"; then
    printf 'FAIL output did not contain: %s\n' "$1" >&2
    failures=$((failures + 1))
  fi
}

before=examples/schema_v1.json
after=examples/schema_v2.json
hints=examples/rename_hints.json

run 0 'help' -- help
expect_output 'moon-schema-plan plan'

run 0 'version reports the build' -- version
expect_output 'moon-schema-plan '

# The CLI cannot read moon.mod at run time, so the two are checked against
# each other here rather than trusted to stay in step.
manifest_version="$(grep '^version = ' moon.mod | head -1 | cut -d"\"" -f2)"
reported_version="$(sed -n 's/^moon-schema-plan //p' "$work_dir/last_output")"
if [ "$manifest_version" != "$reported_version" ]; then
  printf 'FAIL version drift: moon.mod says %s, the binary says %s\n' \
    "$manifest_version" "$reported_version" >&2
  failures=$((failures + 1))
else
  printf 'ok   the reported version matches moon.mod (%s)\n' "$manifest_version"
fi

run 0 'demo renders the SQLite example' -- demo
expect_output 'CREATE TABLE'

run 2 'plan blocks a destructive change by default' -- \
  plan postgresql --before "$before" --after "$after" --hints "$hints"
expect_output 'migration policy violated'

run 0 'plan renders PostgreSQL SQL once approved' -- \
  plan postgresql --before "$before" --after "$after" --hints "$hints" \
  --allow-destructive
expect_output 'ALTER TABLE "accounts" RENAME TO "users";'

run 0 'plan renders a SQLite rebuild once approved' -- \
  plan sqlite --before "$before" --after "$after" --hints "$hints" \
  --allow-destructive
expect_output '__msp_new_users'

run 0 'plan emits a machine-readable report' -- \
  plan postgresql --before "$before" --after "$after" --hints "$hints" \
  --allow-destructive --format json
expect_output '"from_version"'

run 0 'plan emits a Markdown review report' -- \
  plan postgresql --before "$before" --after "$after" --hints "$hints" \
  --allow-destructive --format markdown
expect_output '# Migration plan'

run 2 'verify fails CI on a destructive plan' -- \
  verify postgresql --before "$before" --after "$after" --hints "$hints"
expect_output 'highest risk: destructive'

run 0 'verify passes when the policy allows the plan' -- \
  verify postgresql --before "$before" --after "$after" --hints "$hints" \
  --max-risk destructive
expect_output 'policy: --max-risk destructive'

one_column_table='{"name":"t","columns":[{"name":"id","data_type":"INTEGER","nullable":false,"primary_key":true,"unique":false}]'
indexless="{\"version\":\"1\",\"tables\":[$one_column_table,\"indexes\":[],\"foreign_keys\":[]}]}"
indexed="{\"version\":\"2\",\"tables\":[$one_column_table,\"indexes\":[{\"name\":\"t_id_idx\",\"columns\":[\"id\"],\"unique\":false}],\"foreign_keys\":[]}]}"

run 2 'verify rejects a review-level plan under a safe policy' -- \
  verify postgresql --before-json "$indexless" --after-json "$indexed" \
  --max-risk safe
expect_output 'create index t_id_idx on t'

run 0 'the same plan passes under the default review policy' -- \
  verify postgresql --before-json "$indexless" --after-json "$indexed"
expect_output 'highest risk: review'

run 0 'verify reports an unchanged schema as safe' -- \
  verify postgresql --before "$before" --after "$before"
expect_output 'steps: 0'

run 0 'inline JSON is still accepted' -- \
  verify sqlite --before-json "$(cat "$before")" --after-json "$(cat "$before")"
expect_output 'steps: 0'

run 1 'a missing schema file is a usage error' -- \
  plan postgresql --before "$work_dir/absent.json" --after "$after"
expect_output 'cannot read'

run 1 'an unknown dialect is a usage error' -- \
  plan mysql --before "$before" --after "$after"
expect_output 'unsupported dialect: mysql'

run 1 'an unknown option is a usage error' -- \
  plan postgresql --before "$before" --after "$after" --colour
expect_output 'unknown option: --colour'

run 1 'a repeated schema flag is a usage error' -- \
  plan postgresql --before "$before" --before "$after" --after "$after"
expect_output 'was given twice'

run 1 'a missing target schema is a usage error' -- \
  plan postgresql --before "$before"
expect_output 'the target schema is required'

run 1 'malformed JSON is a usage error' -- \
  plan postgresql --before-json '{' --after "$after"
expect_output 'invalid JSON'

run 1 'an invalid schema reports every issue at once' -- \
  plan postgresql --before "$before" \
  --after-json '{"version":"2","tables":[{"name":"t","columns":[],"indexes":[],"foreign_keys":[]}]}'
expect_output 'at least one column'

run 0 'plan writes to a file when asked' -- \
  plan postgresql --before "$before" --after "$after" --hints "$hints" \
  --allow-destructive --out "$work_dir/plan.sql"
if ! grep -q 'ALTER TABLE' "$work_dir/plan.sql"; then
  printf 'FAIL --out did not write the rendered SQL\n' >&2
  failures=$((failures + 1))
fi

# Diagnostics share stdout with the SQL, because the wasm backend has no
# portable stderr. Every line a failing run writes must therefore be a SQL
# comment, so that `plan ... | sqlite3` cannot be fed a stray message.
check_output_is_inert() {
  description="$1"
  if grep -qv '^--' "$work_dir/last_output" 2>/dev/null; then
    printf 'FAIL %s wrote a line that is not a SQL comment:\n%s\n' \
      "$description" "$(grep -v '^--' "$work_dir/last_output" | head -3)" >&2
    failures=$((failures + 1))
  else
    printf 'ok   %s writes only SQL comments\n' "$description"
  fi
}

run 1 'a failing plan writes nothing a database would execute' -- \
  plan postgresql --before "$work_dir/absent.json" --after "$after"
check_output_is_inert 'a failing plan'

run 2 'a blocked plan writes nothing a database would execute' -- \
  plan postgresql --before "$before" --after "$after" --hints "$hints"
check_output_is_inert 'a blocked plan'

if [ "$failures" != "0" ]; then
  printf '\n%s CLI smoke assertions failed\n' "$failures" >&2
  exit 1
fi

printf '\nCLI smoke test passed\n'
