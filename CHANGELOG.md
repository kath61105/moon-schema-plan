# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[semantic versioning](https://semver.org/).

## Unreleased

### Fixed

- A composite primary key rendered one inline `PRIMARY KEY` per key column,
  which both SQLite and PostgreSQL reject as more than one primary key per
  table. It now renders a single table-level `PRIMARY KEY (a, b)` constraint.
  A single-column key keeps the inline form, because in SQLite an inline
  `INTEGER PRIMARY KEY` is a rowid alias and a separate clause is not. The
  plan had classified the broken output as `safe`.
- Two tables could declare the same index name. Index names are database-wide
  in SQLite and schema-wide in PostgreSQL, so the second `CREATE INDEX` failed.
  Validation now rejects the collision and names the table that repeats it.

### Changed

- A SQLite rebuild step now states in its reason that check constraints,
  triggers and views the schema does not model are not carried over. SQLite's
  generalised procedure recreates indexes, triggers and views; this planner
  models only indexes, and the plan now says so instead of implying
  completeness it does not have.

### Documentation

- `docs/design-decisions.md` and its Chinese translation now explain why a
  SQLite column drop cannot use the native `DROP COLUMN` added in 3.35: four of
  SQLite's eight refusal conditions involve check constraints, generated
  columns, partial-index predicates, triggers and views, none of which the IR
  models, so a gate built on the other four would emit SQL that can fail.
- The README and the architecture note state what the IR does not model, since
  that boundary is what decides both behaviours above.

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
