# moon_schema_plan

Deterministic database schema diff, migration planning, and destructive-change
gates for MoonBit. The library is transport-independent and does not connect to
production databases. Callers provide two explicit schema descriptions and get
an auditable plan plus SQLite or PostgreSQL SQL.

## Why this exists

MoonBit has database drivers, ORMs, and SQL parsers, but applications still need
to answer a different question safely: “How do I move this known schema to that
known schema?” `moon_schema_plan` makes that decision visible and testable.

The core rules are deliberately conservative:

- output is deterministic, making plans suitable for code review and CI;
- renames require explicit hints and are never guessed from similar names;
- destructive changes are classified and blocked during rendering by default;
- invalid schemas return all discovered issues rather than partial SQL;
- SQLite-incompatible changes use a transactional table-rebuild plan;
- identifiers are quoted and raw SQL fragments reject statement delimiters.

## Installation

After the package owner is set and version `0.1.0` is published to Mooncakes:

```sh
moon add <owner>/moon_schema_plan
```

For local development, clone the repository and run `moon check`; the library
has no third-party runtime dependencies.

## Current scope

The schema IR covers tables, columns, indexes, and foreign keys. Planning covers
create/drop/rename table, create/drop/rename/alter column, index changes, foreign
key changes, and SQLite table rebuilds. PostgreSQL and SQLite renderers are
included.

This release intentionally does **not** connect to a live database, parse
arbitrary DDL, infer renames, migrate business data, or support MySQL. Database
introspection belongs in optional adapters; the planner stays deterministic and
cross-target.

## Library example

```mbt nocheck
let result = @moon_schema_plan.build_plan(
  before,
  after,
  @moon_schema_plan.PostgreSQL,
)

match result {
  Err(issues) => // report every invalid schema path
  Ok(plan) =>
    match @moon_schema_plan.render_plan(plan) {
      Err(blocked) => // destructive changes require explicit approval
      Ok(rendered) => println(rendered.sql.join("\n"))
    }
}
```

## CLI

Run the built-in example:

```sh
moon run cmd/main -- demo
```

Plan the checked-in example for PostgreSQL:

```sh
moon run cmd/main -- plan postgresql \
  "$(cat examples/schema_v1.json)" \
  "$(cat examples/schema_v2.json)" \
  "$(cat examples/rename_hints.json)" \
  --allow-destructive
```

Add `--json` for a stable machine-readable report. Omit
`--allow-destructive` to make destructive changes fail closed.

## Development

```sh
moon check --deny-warn
moon test --deny-warn
scripts/sqlite_e2e.sh
moon info
moon fmt --check
```

On an Intel Mac, where the current official MoonBit installer has no native
binary, use the reproducible Linux environment:

```sh
docker build -t moon-schema-plan-dev -f .devcontainer/Dockerfile .
docker run --rm -v "$PWD:/workspace" moon-schema-plan-dev moon test --deny-warn
```

## Safety model

`Safe` means the planner has no evidence of data loss; it does not mean the
operation is free of locks or performance cost. `Review` calls for operator
attention. `Destructive` means existing data or key semantics can be lost or
converted. Production migrations still require backups, staging rehearsal, and
database-specific operational review.

## License

Apache-2.0.

## Documentation

- [Architecture and invariants](docs/architecture.md)
- [One-page Chinese contest proposal](docs/proposal.zh-CN.md)
- [Release and contest checklist](docs/release-checklist.md)
