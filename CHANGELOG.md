# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[semantic versioning](https://semver.org/).

## 0.3.0 - 2026-09-19

### Added

- Check constraints in the schema IR: validated, diffed, rendered into
  `CREATE TABLE`, added and dropped in place on PostgreSQL, and carried across
  a SQLite rebuild, which previously dropped them in silence. Decoding treats
  the new `checks` field as optional so that schema files written against 0.2.0
  still read.
- `scripts/postgres_e2e.sh`, which applies generated SQL to a real PostgreSQL
  server, and a PostgreSQL service container in CI. Half the renderer had never
  been executed; the suite covers the example migration, a composite primary
  key, check constraints, and cyclic foreign keys, the last being the only case
  that exercises deferring a new table's foreign keys.
- Four property-based tests over generated schemas: a schema never differs from
  itself, table order never changes the plan, a destructive plan never renders
  without approval, and rendering is deterministic.
- A `version` command, checked against `moon.mod` by the smoke script.
- `scripts/project_stats.sh`, which derives the figures the documents quote.
- A Windows CI job, since the scripts had only run on Linux.

### Fixed

- A SQLite rebuild committed over a broken foreign key. `PRAGMA
  foreign_key_check` only reports violations, so the plan ended a rebuild by
  printing them and committing anyway, while the documentation claimed a broken
  reference was caught before the commit. The rebuild now feeds that count
  through a `CHECK` constraint, which raises a real error. SQL cannot make a
  `COMMIT` conditional on a query result, so the rollback comes from the client:
  the migration must be applied with `sqlite3 -bail`, or any driver that stops
  at the first error. The documentation says so now, and the end-to-end script
  asserts both directions against a database seeded with a deliberate orphan.
- The reserved table prefix widened from `__msp_new_` to `__msp_`, which also
  covers the guard table above.
- Adding a primary-key column to a table that already had one rendered
  `ALTER TABLE ... ADD COLUMN ... PRIMARY KEY`, which PostgreSQL refuses as
  more than one primary key per table, and the plan called it `review`.
  Reshaping an existing key needs the constraint's name, which the schema does
  not carry, so the transition is now refused while planning. Adding a key to a
  table that has none still works, and SQLite reaches the same change through a
  rebuild.
- A foreign key could reference a column with no uniqueness guarantee.
  PostgreSQL refuses such a constraint and SQLite reports a foreign key
  mismatch when rows are written; validation now requires the referenced
  columns to be, as a set, the referenced table's primary key, a single unique
  column, or the columns of one of its unique indexes.
- A composite primary key rendered one inline `PRIMARY KEY` per key column,
  which both SQLite and PostgreSQL reject as more than one primary key per
  table. It now renders a single table-level `PRIMARY KEY (a, b)` constraint.
  A single-column key keeps the inline form, because in SQLite an inline
  `INTEGER PRIMARY KEY` is a rowid alias and a separate clause is not. The
  plan had classified the broken output as `safe`.
- Two tables could declare the same index name. Index names are database-wide
  in SQLite and schema-wide in PostgreSQL, so the second `CREATE INDEX` failed.
  Validation now rejects the collision and names the table that repeats it.
- Validation issues were collected in table declaration order, so moving a
  table within a file changed the report without changing its meaning. They are
  now sorted by path and message.
- Diagnostics shared stdout with the SQL, so a failing or blocked run piped its
  message into the database in `plan ... | sqlite3`. Every diagnostic line is
  now a SQL comment, which a database ignores while the non-zero exit still
  stops the build.
- The delimiter check rejected `'a--b'` and `'x;y'`, which are ordinary string
  values. It now tracks quoting and judges only what falls outside a literal,
  while rejecting an unterminated literal, which it previously allowed.

### Changed

- A SQLite rebuild step states in its reason that triggers and views, which the
  schema does not model, are not carried over.
- CLI argument parsing is a pure function returning `Result`, so it is unit
  tested rather than only exercised through the smoke script. Errors point at
  `help` instead of reprinting the whole usage text.

## 0.2.0 - 2026-09-19

First public release. Version 0.1.0 was never published; it is kept below as
the record of the implementation this release builds on.

### Added

- `Risk::severity`, `Risk::label`, `Risk::parse`, `Dialect::label` and
  `Dialect::parse`, so a policy threshold and a dialect name have one spelling
  shared by the library and the CLI.
- `Plan::summary`, `Plan::max_risk` and `Plan::steps_above`, the policy
  primitives behind the CLI's `--max-risk`.
- `Change::describe`, `Plan::to_markdown` and `RenderedPlan::to_markdown`, which
  render a deterministic Markdown review document without shelling out.
- CLI: `--before`, `--after` and `--hints` read schemas from files; the inline
  `--before-json`, `--after-json` and `--hints-json` forms remain.
- CLI: a `verify` command that reports a plan and answers only whether it may
  proceed, with exit code `2` for a policy violation and `1` for a real error.
- CLI: `--max-risk`, `--format sql|json|markdown` and `--out <path>`.
- `scripts/cli_smoke.sh`, asserting every documented command and exit code.
- GitHub Actions CI across the `wasm`, `wasm-gc`, `js` and `native` backends,
  plus a `.devcontainer/Dockerfile` with the same toolchain.

### Changed

- `scripts/sqlite_e2e.sh` now also migrates the checked-in example schemas
  against a real database and asserts that rows survive, the dropped column is
  gone, the target index is recreated, no staging table is left behind, and an
  unapproved destructive plan emits no SQL.
- The CLI reports which file or flag a bad schema came from.
- `README.md` is the canonical readme; it was previously a symbolic link.

### Removed

- The PostgreSQL "manual review required" comment for key-constraint changes.
  `render_plan` already refuses those plans, so the comment was unreachable.

## 0.1.0 - 2026-09-19

- Added deterministic schema diffing and explicit rename hints.
- Added conservative validation and three-level migration risk classification.
- Added SQLite rebuild and PostgreSQL alter renderers.
- Added destructive-change gating, JSON reports, and a command-line demo.
- Added unit, public-API, cross-target, and real SQLite migration tests.
