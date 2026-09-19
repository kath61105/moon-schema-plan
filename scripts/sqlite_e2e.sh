#!/usr/bin/env sh
set -eu

db_path="$(mktemp /tmp/moon-schema-plan-e2e.XXXXXX.db)"
trap 'rm -f "$db_path"' EXIT

sqlite3 "$db_path" \
  "CREATE TABLE users (id INTEGER PRIMARY KEY NOT NULL, nickname TEXT);
   INSERT INTO users(id, nickname) VALUES (1, 'Ada'), (2, NULL);"

moon run cmd/main -- demo | sqlite3 "$db_path"

actual="$(sqlite3 "$db_path" \
  "SELECT id || ':' || display_name FROM users ORDER BY id;
   PRAGMA foreign_key_check;
   PRAGMA integrity_check;")"

expected='1:Ada
2:anonymous
ok'

if [ "$actual" != "$expected" ]; then
  printf 'SQLite end-to-end mismatch\nexpected:\n%s\nactual:\n%s\n' "$expected" "$actual" >&2
  exit 1
fi

printf 'SQLite end-to-end migration passed\n'
