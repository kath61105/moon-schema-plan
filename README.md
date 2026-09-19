# moon_schema_plan

[![CI](https://github.com/kath61105/moon-schema-plan/actions/workflows/ci.yml/badge.svg)](https://github.com/kath61105/moon-schema-plan/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![mooncakes](https://img.shields.io/badge/mooncakes-0.2.0-brightgreen.svg)](https://mooncakes.io/docs/kath61105/moon_schema_plan)

Deterministic database schema diffing, migration planning and destructive-change
gates for [MoonBit](https://docs.moonbitlang.com). The library is
transport-independent and never connects to a database. You give it two explicit
schema descriptions; it gives you an auditable plan, a risk verdict, and SQLite
or PostgreSQL SQL.

```sh
# Fail the build when a migration would destroy data.
moon run cmd/main -- verify postgresql \
  --before schema/v1.json --after schema/v2.json
# exit 2: migration policy violated: --max-risk is review
#   step-5 [destructive] drop column users.legacy_code: drops all values stored in the column
```

## Why this exists

MoonBit already has database drivers, ORMs and SQL parsers. They answer "how do
I talk to this database?". `moon_schema_plan` answers a different question:
**"may this schema change run, and what exactly will it do?"** It is the piece
you put in CI, between a schema definition and a production database.

The rules are deliberately conservative:

- output is deterministic, so a plan can be reviewed in a pull request;
- renames require explicit hints and are never guessed from similar names;
- destructive changes are classified and refused unless approved in the command;
- an invalid schema returns every issue it has, never partial SQL;
- SQLite changes that `ALTER TABLE` cannot express become one auditable,
  transactional table rebuild;
- identifiers are quoted, and raw SQL fragments reject statement delimiters.

## Installation

```sh
moon add kath61105/moon_schema_plan
```

The library itself has no third-party runtime dependencies. The bundled CLI
additionally uses `moonbitlang/x` for file access and exit codes, so the library
stays pure and portable while the executable can talk to a real shell.

For local development, clone the repository and run `moon check`.

## Using it in CI

`verify` is the command a pipeline runs. It builds the plan, reports it and then
exits with a status a build system can act on. It never emits SQL.

```sh
moon run cmd/main -- verify postgresql \
  --before schema/v1.json \
  --after schema/v2.json \
  --hints schema/renames.json \
  --max-risk review
```

| Exit code | Meaning |
| --- | --- |
| `0` | The plan satisfies `--max-risk`. |
| `1` | Usage, file, JSON or schema-validation error. Nothing was planned. |
| `2` | The plan is valid but contains a step above `--max-risk`. |

`--max-risk` accepts `safe`, `review` or `destructive` and defaults to `review`,
so dropping a table or a column fails the build until someone says otherwise.

To attach the plan to a pull request, ask for Markdown:

```sh
moon run cmd/main -- verify postgresql \
  --before schema/v1.json --after schema/v2.json \
  --format markdown --out migration-plan.md
```

## Generating SQL

`plan` renders the SQL, under the same policy.

```sh
# Blocked: exits 2 and prints the offending steps, with no SQL.
moon run cmd/main -- plan postgresql \
  --before examples/schema_v1.json \
  --after examples/schema_v2.json \
  --hints examples/rename_hints.json

# Approved: renders the migration.
moon run cmd/main -- plan postgresql \
  --before examples/schema_v1.json \
  --after examples/schema_v2.json \
  --hints examples/rename_hints.json \
  --allow-destructive
```

`--format` selects `sql` (default), `json` for a stable machine-readable report,
or `markdown` for review. `--out <path>` writes to a file. Schemas may also be
passed inline with `--before-json` and `--after-json`.

The JSON accepted and produced by every one of these is documented in
[docs/schema-format.md](docs/schema-format.md), including why a rename needs an
explicit hint and how to write a default expression.

Run `moon run cmd/main -- demo` for a complete, executable SQLite example, and
`moon run cmd/main -- help` for the full option list.

## Library example

```moonbit
let result = @moon_schema_plan.build_plan(before, after, @moon_schema_plan.PostgreSQL)

match result {
  // Every invalid path at once, rather than the first one found.
  Err(issues) => report(issues)
  Ok(plan) =>
    if plan.max_risk().severity() > @moon_schema_plan.Review.severity() {
      reject(plan.steps_above(@moon_schema_plan.Review))
    } else {
      match @moon_schema_plan.render_plan(plan) {
        Err(blocked) => report(blocked)
        Ok(rendered) => println(rendered.sql.join("\n"))
      }
    }
}
```

`Plan::to_markdown` and `RenderedPlan::to_markdown` produce the same review
document the CLI prints, so a tool built on the library can post it without
shelling out.

## Safety model

`Safe` means the planner found no evidence of data loss. It does **not** mean the
operation is free of locks or performance cost. `Review` asks for operator
attention. `Destructive` means existing data or key semantics can be lost or
converted.

A plan is not a substitute for backups, a staging rehearsal or database-specific
operational review. It makes the decision explicit; a human still makes it.

## Scope

The schema IR covers tables, columns, indexes and foreign keys. Planning covers
creating, dropping and renaming tables and columns, altering columns, index and
foreign-key changes, and SQLite table rebuilds, for PostgreSQL and SQLite.

The IR models tables, columns, indexes, foreign keys and check constraints. It
does not model generated columns, partial-index predicates, triggers or views.
Two consequences show up in the output: a SQLite column drop always becomes a
rebuild rather than a native `DROP COLUMN`, because half of SQLite's conditions
for refusing that statement involve objects the IR cannot see; and a rebuild
recreates indexes but not triggers or views, which each rebuild step states in
its reason. [docs/design-decisions.md](docs/design-decisions.md) works through
both.

This release deliberately does **not** connect to a live database, parse
arbitrary DDL, infer renames, migrate business data, or support MySQL.
Introspection belongs in optional adapters; the planner stays a pure,
cross-target function. Column types and default expressions are dialect SQL
fragments from trusted configuration — this is a planner, not a SQL firewall.

## Development

```sh
moon fmt --check
moon info
moon check --deny-warn
moon test --deny-warn
sh scripts/cli_smoke.sh     # every documented CLI invocation and exit code
sh scripts/sqlite_e2e.sh    # applies generated SQL to a real sqlite3 database
sh scripts/postgres_e2e.sh  # the same against a real PostgreSQL server
```

`postgres_e2e.sh` reads the standard libpq environment variables (`PGHOST`,
`PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`), so it runs against any server
you point it at, including the one CI starts as a service container.

CI runs all of the above and the test suite on the `wasm`, `wasm-gc`, `js` and
`native` backends. The native backend compiles through C, so it needs a system C
compiler; the dev container provides one:

```sh
docker build -t moon-schema-plan-dev -f .devcontainer/Dockerfile .
docker run --rm -v "$PWD:/workspace" moon-schema-plan-dev moon test --deny-warn
```

## Work completed in this period

This project was built for the 2026 MoonBit September Hackathon. Recording the
boundary explicitly, because the rules ask entrants to distinguish new work from
pre-existing work:

The repository's first commit, `chore: import initial moon_schema_plan
implementation`, captures the code as it stood before version control was set up
on 19 September 2026 — the schema IR, validation, the diff engine, risk
classification, the SQLite and PostgreSQL renderers, a demo CLI, and 23 tests,
totalling 1,970 lines of MoonBit. Nothing was ever published from that state:
there was no repository, no CI, no release and no registry entry.

Every commit after it — 23 so far, changing 40 files by +4,688/-286 lines — was
written during this period. That work is:

- the risk-policy layer (`Risk::severity`/`parse`, `Plan::summary`,
  `Plan::max_risk`, `Plan::steps_above`) and the Markdown reporting layer
  (`Change::describe`, `Plan::to_markdown`, `RenderedPlan::to_markdown`) — a new
  `report.mbt`;
- the CLI rewrite: file inputs, the `verify` command, `--max-risk`, `--format`,
  `--out`, and distinct exit codes for a policy violation and a real error;
- CHECK constraints in the schema IR, which a SQLite rebuild used to drop in
  silence;
- the test suite going from 23 to 118 tests, library coverage to 715/719 lines
  and the CLI from none to 67/196, including four property-based checks of the
  determinism, gate and identity claims;
- real database execution for both dialects, which is how every renderer defect
  so far was found;
  two of those tests are regressions for defects found by executing generated
  SQL against a real database rather than by reading it;
- `scripts/cli_smoke.sh`, asserting all 21 documented CLI invocations, and a
  rewritten `scripts/sqlite_e2e.sh` that migrates the example schemas against a
  real database;
- GitHub Actions across four backends, a dev container, this README,
  `docs/schema-format.md`, and the 0.2.0 release to GitHub and mooncakes.

The CI history is part of that record: the first run failed because a fresh
runner has no MoonBit registry index, which local development had masked.

## Documentation

- [Schema, hints and report JSON](docs/schema-format.md)
- [Architecture and invariants](docs/architecture.md)
- [Design decisions and their trade-offs](docs/design-decisions.md)
  ([中文](docs/design-decisions.zh-CN.md))
- [One-page Chinese contest proposal](docs/proposal.zh-CN.md)
- [Release and contest checklist](docs/release-checklist.md)
- [Changelog](CHANGELOG.md)

## License

Apache-2.0. See [LICENSE](LICENSE).
