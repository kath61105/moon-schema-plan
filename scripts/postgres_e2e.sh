#!/usr/bin/env sh
# Apply generated PostgreSQL migrations to a real server and check the result.
#
# The SQLite renderer has been executed against a real database from the start;
# the PostgreSQL renderer was only ever compared against expected strings. Two
# defects found by running SQLite output rather than reading it argued for
# giving this half the same treatment.
#
# Connection settings come from the standard libpq environment variables
# (PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE), so this works against the
# CI service container and against any local server.
set -eu

cd "$(dirname "$0")/.."

: "${PGHOST:=localhost}"
: "${PGPORT:=5432}"
: "${PGUSER:=postgres}"
: "${PGDATABASE:=postgres}"
export PGHOST PGPORT PGUSER PGDATABASE

failures=0

# Every statement must succeed, and a NOTICE must not be mistaken for output.
psql_run() {
  psql --quiet --no-align --tuples-only --no-psqlrc \
    --set ON_ERROR_STOP=1 "$@"
}

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

# Each case owns a schema, so one failure cannot cascade into the next.
fresh_schema() {
  psql_run -c "DROP SCHEMA IF EXISTS $1 CASCADE; CREATE SCHEMA $1; " >/dev/null
  PGOPTIONS="--search_path=$1"
  export PGOPTIONS
}

apply() {
  if ! psql_run -f "$1" >/dev/null 2>"$work_dir/apply.err"; then
    printf 'FAIL %s did not apply\n%s\n' "$1" "$(cat "$work_dir/apply.err")" >&2
    failures=$((failures + 1))
    return 1
  fi
  return 0
}

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

# Case 1: the checked-in example migration. A table and a column are renamed,
# a unique column is added, a nullable column becomes required with a backfill,
# an index is added and a column is dropped.
fresh_schema msp_example
psql_run -c "
  CREATE TABLE accounts (
    id INTEGER PRIMARY KEY NOT NULL,
    display_name TEXT,
    legacy_code TEXT
  );
  INSERT INTO accounts(id, display_name, legacy_code)
  VALUES (1, 'Ada', 'A-1'), (2, NULL, 'B-2');" >/dev/null

moon run cmd/main -- plan postgresql \
  --before examples/schema_v1.json \
  --after examples/schema_v2.json \
  --hints examples/rename_hints.json \
  --allow-destructive > "$work_dir/example.sql"

if apply "$work_dir/example.sql"; then
  rows="$(psql_run -c "SELECT id || ':' || name FROM users ORDER BY id;" | normalise)"
  check 'example migration preserves rows and backfills the default' '1:Ada
2:anonymous' "$rows"

  columns="$(psql_run -c "
    SELECT string_agg(column_name, ',' ORDER BY ordinal_position)
    FROM information_schema.columns
    WHERE table_schema = 'msp_example' AND table_name = 'users';" | normalise)"
  check 'example migration drops the legacy column' 'id,name,email' "$columns"

  not_null="$(psql_run -c "
    SELECT is_nullable FROM information_schema.columns
    WHERE table_schema = 'msp_example' AND table_name = 'users'
      AND column_name = 'name';" | normalise)"
  check 'the backfilled column is now NOT NULL' 'NO' "$not_null"

  indexes="$(psql_run -c "
    SELECT indexname FROM pg_indexes
    WHERE schemaname = 'msp_example' AND indexname = 'users_name_idx';" | normalise)"
  check 'the target index exists' 'users_name_idx' "$indexes"
fi

# Case 2: a composite primary key, the defect that a single inline PRIMARY KEY
# per column used to produce.
fresh_schema msp_composite
composite='{"version":"2","tables":[{"name":"membership","columns":[
  {"name":"user_id","data_type":"INTEGER","nullable":false,"primary_key":true,"unique":false},
  {"name":"team_id","data_type":"INTEGER","nullable":false,"primary_key":true,"unique":false},
  {"name":"role","data_type":"TEXT","nullable":true,"primary_key":false,"unique":false}
],"indexes":[],"foreign_keys":[],"checks":[]}]}'

moon run cmd/main -- plan postgresql \
  --before-json '{"version":"1","tables":[]}' \
  --after-json "$composite" > "$work_dir/composite.sql"

if apply "$work_dir/composite.sql"; then
  key="$(psql_run -c "
    SELECT string_agg(a.attname, ',' ORDER BY k.ordinality)
    FROM pg_constraint c
    JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS k(attnum, ordinality) ON true
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
    WHERE c.conrelid = 'msp_composite.membership'::regclass AND c.contype = 'p';" | normalise)"
  check 'composite primary key covers both columns' 'user_id,team_id' "$key"

  psql_run -c "INSERT INTO membership VALUES (1, 1, 'owner');" >/dev/null
  duplicate_rejected=0
  psql_run -c "INSERT INTO membership VALUES (1, 1, 'member');" >/dev/null 2>&1 \
    || duplicate_rejected=1
  check 'composite primary key rejects a duplicate pair' '1' "$duplicate_rejected"
fi

# Case 3: cyclic foreign keys. PostgreSQL new-table foreign keys are deferred
# until every table exists, which is the only reason a cycle can be expressed
# at all. Nothing else in the suite executes that path.
fresh_schema msp_cycle
cat > "$work_dir/cyclic.json" <<'CYCLIC'
{
  "version": "2",
  "tables": [
    {
      "name": "a",
      "columns": [
        {"name": "id", "data_type": "INTEGER", "nullable": false, "primary_key": true, "unique": false},
        {"name": "b_id", "data_type": "INTEGER", "nullable": true, "primary_key": false, "unique": false}
      ],
      "indexes": [],
      "checks": [],
      "foreign_keys": [
        {"name": "a_b_fk", "columns": ["b_id"], "referenced_table": "b", "referenced_columns": ["id"]}
      ]
    },
    {
      "name": "b",
      "columns": [
        {"name": "id", "data_type": "INTEGER", "nullable": false, "primary_key": true, "unique": false},
        {"name": "a_id", "data_type": "INTEGER", "nullable": true, "primary_key": false, "unique": false}
      ],
      "indexes": [],
      "checks": [],
      "foreign_keys": [
        {"name": "b_a_fk", "columns": ["a_id"], "referenced_table": "a", "referenced_columns": ["id"]}
      ]
    }
  ]
}
CYCLIC

moon run cmd/main -- plan postgresql \
  --before-json '{"version":"1","tables":[]}' \
  --after "$work_dir/cyclic.json" > "$work_dir/cyclic.sql"

if apply "$work_dir/cyclic.sql"; then
  constraints="$(psql_run -c "
    SELECT string_agg(conname, ',' ORDER BY conname)
    FROM pg_constraint
    WHERE connamespace = 'msp_cycle'::regnamespace AND contype = 'f';" | normalise)"
  check 'both sides of the cycle have their foreign key' 'a_b_fk,b_a_fk' "$constraints"

  orphan_rejected=0
  psql_run -c "INSERT INTO a VALUES (1, 99);" >/dev/null 2>&1 || orphan_rejected=1
  check 'the deferred foreign key is enforced' '1' "$orphan_rejected"
fi

# Case 4: check constraints, added in place and then enforced.
fresh_schema msp_check
plain='{"version":"1","tables":[{"name":"orders","columns":[
  {"name":"id","data_type":"INTEGER","nullable":false,"primary_key":true,"unique":false},
  {"name":"quantity","data_type":"INTEGER","nullable":true,"primary_key":false,"unique":false}
],"indexes":[],"foreign_keys":[],"checks":[]}]}'
constrained='{"version":"2","tables":[{"name":"orders","columns":[
  {"name":"id","data_type":"INTEGER","nullable":false,"primary_key":true,"unique":false},
  {"name":"quantity","data_type":"INTEGER","nullable":true,"primary_key":false,"unique":false}
],"indexes":[],"foreign_keys":[],
"checks":[{"name":"orders_quantity_positive","expression":"quantity > 0"}]}]}'

moon run cmd/main -- plan postgresql \
  --before-json '{"version":"1","tables":[]}' --after-json "$plain" \
  > "$work_dir/orders.sql"
apply "$work_dir/orders.sql" || true

moon run cmd/main -- plan postgresql \
  --before-json "$plain" --after-json "$constrained" > "$work_dir/check.sql"

if apply "$work_dir/check.sql"; then
  psql_run -c "INSERT INTO orders VALUES (1, 5);" >/dev/null
  violation_rejected=0
  psql_run -c "INSERT INTO orders VALUES (2, -1);" >/dev/null 2>&1 \
    || violation_rejected=1
  check 'the added check constraint is enforced' '1' "$violation_rejected"

  moon run cmd/main -- plan postgresql \
    --before-json "$constrained" --after-json "$plain" > "$work_dir/uncheck.sql"
  if apply "$work_dir/uncheck.sql"; then
    remaining="$(psql_run -c "
      SELECT count(*) FROM pg_constraint
      WHERE conrelid = 'msp_check.orders'::regclass AND contype = 'c';" | normalise)"
    check 'dropping the check removes the constraint' '0' "$remaining"
  fi
fi

# Case 5: an unapproved destructive plan must reach no database at all.
set +e
moon run cmd/main -- plan postgresql \
  --before examples/schema_v1.json \
  --after examples/schema_v2.json \
  --hints examples/rename_hints.json > "$work_dir/blocked.sql" 2>&1
blocked_status=$?
set -e

check 'an unapproved destructive plan exits with the policy status' '2' "$blocked_status"

if grep -q 'ALTER TABLE' "$work_dir/blocked.sql"; then
  printf 'FAIL a blocked plan still emitted SQL\n' >&2
  failures=$((failures + 1))
fi

psql_run -c "DROP SCHEMA IF EXISTS msp_example, msp_composite, msp_cycle, msp_check CASCADE;" \
  >/dev/null 2>&1 || true

if [ "$failures" != "0" ]; then
  printf '\n%s PostgreSQL end-to-end assertions failed\n' "$failures" >&2
  exit 1
fi

printf '\nPostgreSQL end-to-end migration passed\n'
