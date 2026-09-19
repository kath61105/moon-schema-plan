#!/usr/bin/env sh
# Apply generated migrations to a real SQLite database and check the data.
#
# Rendering plausible SQL is not enough: these cases run the output through
# sqlite3 and assert that rows survive a rename, a backfill and a rebuild.
set -eu

cd "$(dirname "$0")/.."

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

failures=0

# sqlite3 on Windows terminates lines with CRLF; normalise before comparing so
# the same assertions hold in Git Bash and on Linux.
normalise() {
  tr -d '\r'
}

check() {
  description="$1"
  expected="$2"
  actual="$3"
  if [ "$actual" != "$expected" ]; then
    printf 'FAIL %s\nexpected:\n%s\nactual:\n%s\n' \
      "$description" "$expected" "$actual" >&2
    failures=$((failures + 1))
    return
  fi
  printf 'ok   %s\n' "$description"
}

# Case 1: the built-in demo renames a nullable column into a required one and
# backfills the historical NULL with the target default.
demo_db="$work_dir/demo.db"
sqlite3 "$demo_db" \
  "CREATE TABLE users (id INTEGER PRIMARY KEY NOT NULL, nickname TEXT);
   INSERT INTO users(id, nickname) VALUES (1, 'Ada'), (2, NULL);"

moon run cmd/main -- demo | sqlite3 "$demo_db"

demo_actual="$(sqlite3 "$demo_db" \
  "SELECT id || ':' || display_name FROM users ORDER BY id;
   PRAGMA foreign_key_check;
   PRAGMA integrity_check;" | normalise)"

check 'demo backfills a required column' '1:Ada
2:anonymous
ok' "$demo_actual"

# Case 2: the checked-in example schemas, applied as a SQLite table rebuild.
# The table and a column are renamed, a unique column is added, and a column
# is dropped, so the plan is destructive and must be approved explicitly.
example_db="$work_dir/example.db"
sqlite3 "$example_db" \
  "CREATE TABLE accounts (
     id INTEGER PRIMARY KEY NOT NULL,
     display_name TEXT,
     legacy_code TEXT
   );
   INSERT INTO accounts(id, display_name, legacy_code)
   VALUES (1, 'Ada', 'A-1'), (2, NULL, 'B-2');"

moon run cmd/main -- plan sqlite \
  --before examples/schema_v1.json \
  --after examples/schema_v2.json \
  --hints examples/rename_hints.json \
  --allow-destructive | sqlite3 "$example_db"

example_actual="$(sqlite3 "$example_db" \
  "SELECT id || ':' || name FROM users ORDER BY id;
   PRAGMA foreign_key_check;
   PRAGMA integrity_check;" | normalise)"

check 'example rebuild preserves rows and backfills the default' '1:Ada
2:anonymous
ok' "$example_actual"

example_columns="$(sqlite3 "$example_db" \
  "SELECT group_concat(name, ',') FROM pragma_table_info('users');" | normalise)"

check 'example rebuild drops the legacy column' 'id,name,email' "$example_columns"

example_indexes="$(sqlite3 "$example_db" \
  "SELECT name FROM sqlite_master
    WHERE type = 'index' AND sql IS NOT NULL ORDER BY name;" | normalise)"

check 'example rebuild recreates the target index' 'users_name_idx' "$example_indexes"

staging_left="$(sqlite3 "$example_db" \
  "SELECT count(*) FROM sqlite_master WHERE name LIKE '__msp_new_%';" | normalise)"

check 'example rebuild leaves no staging table behind' '0' "$staging_left"

# Case 3: the same plan must be refused without an explicit approval, so a
# pipeline cannot reach sqlite3 by accident.
set +e
moon run cmd/main -- plan sqlite \
  --before examples/schema_v1.json \
  --after examples/schema_v2.json \
  --hints examples/rename_hints.json > "$work_dir/blocked.sql" 2>&1
blocked_status=$?
set -e

check 'an unapproved destructive plan exits with the policy status' '2' "$blocked_status"

if grep -q 'CREATE TABLE' "$work_dir/blocked.sql"; then
  printf 'FAIL a blocked plan still emitted SQL\n' >&2
  failures=$((failures + 1))
fi

# Case 4: a composite primary key. Rendering this as one inline PRIMARY KEY per
# key column produces SQL that SQLite rejects outright, and reading the output
# did not catch it, so the statement is executed here.
composite_db="$work_dir/composite.db"
composite_schema='{"version":"2","tables":[{"name":"membership","columns":[
  {"name":"user_id","data_type":"INTEGER","nullable":false,"primary_key":true,"unique":false},
  {"name":"team_id","data_type":"INTEGER","nullable":false,"primary_key":true,"unique":false},
  {"name":"role","data_type":"TEXT","nullable":true,"primary_key":false,"unique":false}
],"indexes":[],"foreign_keys":[]}]}'

moon run cmd/main -- plan sqlite \
  --before-json '{"version":"1","tables":[]}' \
  --after-json "$composite_schema" > "$work_dir/composite.sql"

sqlite3 "$composite_db" < "$work_dir/composite.sql" 2>"$work_dir/composite.err" || true

if [ -s "$work_dir/composite.err" ]; then
  printf 'FAIL composite primary key was rejected: %s\n' \
    "$(cat "$work_dir/composite.err")" >&2
  failures=$((failures + 1))
else
  printf 'ok   composite primary key applies cleanly\n'
fi

composite_key="$(sqlite3 "$composite_db" \
  "SELECT group_concat(name, ',') FROM pragma_table_info('membership') WHERE pk > 0;" \
  | normalise)"

check 'composite primary key covers both columns' 'user_id,team_id' "$composite_key"

# The key must actually be enforced, not merely accepted.
sqlite3 "$composite_db" \
  "INSERT INTO membership(user_id, team_id, role) VALUES (1, 1, 'owner');" >/dev/null
duplicate_rejected=0
sqlite3 "$composite_db" \
  "INSERT INTO membership(user_id, team_id, role) VALUES (1, 1, 'member');" \
  >/dev/null 2>&1 || duplicate_rejected=1

check 'composite primary key rejects a duplicate pair' '1' "$duplicate_rejected"

if [ "$failures" != "0" ]; then
  printf '\n%s SQLite end-to-end assertions failed\n' "$failures" >&2
  exit 1
fi

printf '\nSQLite end-to-end migration passed\n'
