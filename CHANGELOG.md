# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[semantic versioning](https://semver.org/).

## Unreleased

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
