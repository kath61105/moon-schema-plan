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

moon run cmd/main -- demo | sqlite3 -bail "$demo_db"

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
  --allow-destructive | sqlite3 -bail "$example_db"

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

sqlite3 -bail "$composite_db" < "$work_dir/composite.sql" 2>"$work_dir/composite.err" || true

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

# Case 5: a rebuild must not commit over a broken reference.
#
# PRAGMA foreign_key_check only reports violations, so the plan feeds its count
# through a CHECK constraint to turn that report into a real error. SQL cannot
# make a COMMIT conditional on a query result, so the rollback comes from the
# client stopping at the first error and leaving the transaction open. Both
# directions are asserted here, and the apply uses -bail exactly as the README
# tells operators to.
guard_before='{"version":"1","tables":[
{"name":"p","columns":[
  {"name":"id","data_type":"INTEGER","nullable":false,"primary_key":true,"unique":false},
  {"name":"v","data_type":"TEXT","nullable":true,"primary_key":false,"unique":false}],
 "indexes":[],"foreign_keys":[],"checks":[]},
{"name":"c","columns":[
  {"name":"id","data_type":"INTEGER","nullable":false,"primary_key":true,"unique":false},
  {"name":"pid","data_type":"INTEGER","nullable":true,"primary_key":false,"unique":false}],
 "indexes":[],"checks":[],
 "foreign_keys":[{"name":"c_p_fk","columns":["pid"],"referenced_table":"p",
                  "referenced_columns":["id"]}]}]}'
guard_after="$(printf '%s' "$guard_before"   | sed 's/"v","data_type":"TEXT"/"v","data_type":"INTEGER"/; s/"version":"1"/"version":"2"/')"

moon run cmd/main -- plan sqlite --before-json "$guard_before"   --after-json "$guard_after" --allow-destructive > "$work_dir/guard.sql"

# seed <database> <orphan yes|no>
seed_guard_db() {
  rm -f "$1"
  sqlite3 "$1"     "CREATE TABLE p (id INTEGER PRIMARY KEY NOT NULL, v TEXT);
     CREATE TABLE c (id INTEGER PRIMARY KEY NOT NULL,
                     pid INTEGER REFERENCES p(id));
     INSERT INTO p VALUES (1, 'kept');
     INSERT INTO c VALUES (1, 1);"
  if [ "$2" = "yes" ]; then
    sqlite3 "$1" "PRAGMA foreign_keys=OFF; INSERT INTO c VALUES (2, 99);"
  fi
}

broken_db="$work_dir/broken.db"
seed_guard_db "$broken_db" yes
set +e
sqlite3 -bail "$broken_db" < "$work_dir/guard.sql" >/dev/null 2>&1
broken_status=$?
set -e

if [ "$broken_status" = "0" ]; then
  printf 'FAIL the rebuild committed over a broken reference
' >&2
  failures=$((failures + 1))
else
  printf 'ok   a broken reference fails the rebuild (exit %s)
' "$broken_status"
fi

broken_type="$(sqlite3 "$broken_db"   "SELECT type FROM pragma_table_info('p') WHERE name = 'v';" | normalise)"
check 'the failed rebuild was rolled back, not partly applied' 'TEXT' "$broken_type"

broken_staging="$(sqlite3 "$broken_db"   "SELECT count(*) FROM sqlite_master WHERE name LIKE '__msp_%';" | normalise)"
check 'the failed rebuild left no staging or guard table' '0' "$broken_staging"

intact_db="$work_dir/intact.db"
seed_guard_db "$intact_db" no
sqlite3 -bail "$intact_db" < "$work_dir/guard.sql" >/dev/null

intact_type="$(sqlite3 "$intact_db"   "SELECT type FROM pragma_table_info('p') WHERE name = 'v';" | normalise)"
check 'a sound database still migrates' 'INTEGER' "$intact_type"

intact_staging="$(sqlite3 "$intact_db"   "SELECT count(*) FROM sqlite_master WHERE name LIKE '__msp_%';" | normalise)"
check 'the successful rebuild left no staging or guard table' '0' "$intact_staging"


# Case 6: a rebuild of a table that a view reads, and whose triggers must come
# back. Before views and triggers were modelled this failed outright: the rename
# inside the rebuild refuses to run while a view points at a table that is
# momentarily missing, and DROP TABLE takes the triggers with it.
cat > "$work_dir/tv_before.json" <<'TVBEFORE'
{
  "version": "1",
  "views": [{"name": "vx", "definition": "SELECT id, v FROM x"}],
  "tables": [
    {"name": "log", "indexes": [], "foreign_keys": [], "checks": [], "triggers": [],
     "columns": [{"name": "msg", "data_type": "TEXT", "nullable": true,
                  "primary_key": false, "unique": false}]},
    {"name": "x", "indexes": [], "foreign_keys": [], "checks": [],
     "columns": [{"name": "id", "data_type": "INTEGER", "nullable": false,
                  "primary_key": true, "unique": false},
                 {"name": "v", "data_type": "TEXT", "nullable": true,
                  "primary_key": false, "unique": false}],
     "triggers": [{"name": "tx", "timing": "AFTER", "event": "INSERT",
                   "action": "FOR EACH ROW BEGIN INSERT INTO log VALUES ('ins'); END"}]}
  ]
}
TVBEFORE
cat > "$work_dir/tv_after.json" <<'TVAFTER'
{
  "version": "2",
  "views": [{"name": "vx", "definition": "SELECT id, v FROM x"}],
  "tables": [
    {"name": "log", "indexes": [], "foreign_keys": [], "checks": [], "triggers": [],
     "columns": [{"name": "msg", "data_type": "TEXT", "nullable": true,
                  "primary_key": false, "unique": false}]},
    {"name": "x", "indexes": [], "foreign_keys": [], "checks": [],
     "columns": [{"name": "id", "data_type": "INTEGER", "nullable": false,
                  "primary_key": true, "unique": false},
                 {"name": "v", "data_type": "INTEGER", "nullable": true,
                  "primary_key": false, "unique": false}],
     "triggers": [{"name": "tx", "timing": "AFTER", "event": "INSERT",
                   "action": "FOR EACH ROW BEGIN INSERT INTO log VALUES ('ins'); END"}]}
  ]
}
TVAFTER

tv_db="$work_dir/tv.db"
sqlite3 "$tv_db"   "CREATE TABLE log (msg TEXT);
   CREATE TABLE x (id INTEGER PRIMARY KEY NOT NULL, v TEXT);
   CREATE VIEW vx AS SELECT id, v FROM x;
   CREATE TRIGGER tx AFTER INSERT ON x
     BEGIN INSERT INTO log VALUES ('ins'); END;
   INSERT INTO x VALUES (1, 'a');"

moon run cmd/main -- plan sqlite --before "$work_dir/tv_before.json"   --after "$work_dir/tv_after.json" --allow-destructive > "$work_dir/tv.sql"

set +e
sqlite3 -bail "$tv_db" < "$work_dir/tv.sql" >/dev/null 2>"$work_dir/tv.err"
tv_status=$?
set -e

if [ "$tv_status" != "0" ]; then
  printf 'FAIL the rebuild failed with a view present
%s
'     "$(cat "$work_dir/tv.err")" >&2
  failures=$((failures + 1))
else
  printf 'ok   a table a view reads can still be rebuilt
'
fi

tv_objects="$(sqlite3 "$tv_db"   "SELECT group_concat(type || ' ' || name, ',')
     FROM (SELECT type, name FROM sqlite_master
            WHERE type IN ('view','trigger') ORDER BY name);" | normalise)"
check 'the view and the trigger both survive' 'trigger tx,view vx' "$tv_objects"

tv_column="$(sqlite3 "$tv_db"   "SELECT type FROM pragma_table_info('x') WHERE name = 'v';" | normalise)"
check 'the rebuild actually changed the column' 'INTEGER' "$tv_column"

# The recreated trigger must still fire, not merely exist. The row inserted
# before the migration already fired it once, so the increment is what matters.
tv_before_rows="$(sqlite3 "$tv_db" "SELECT count(*) FROM log;" | normalise)"
sqlite3 "$tv_db" "INSERT INTO x VALUES (2, 7);" >/dev/null
tv_after_rows="$(sqlite3 "$tv_db" "SELECT count(*) FROM log;" | normalise)"
check 'the recreated trigger still fires'   "$((tv_before_rows + 1))" "$tv_after_rows"

tv_rows="$(sqlite3 "$tv_db" "SELECT count(*) FROM vx;" | normalise)"
check 'the recreated view still reads the rebuilt table' '2' "$tv_rows"

if [ "$failures" != "0" ]; then
  printf '\n%s SQLite end-to-end assertions failed\n' "$failures" >&2
  exit 1
fi

printf '\nSQLite end-to-end migration passed\n'
