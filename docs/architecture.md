# Architecture and invariants

`moon_schema_plan` is a pipeline of small, pure stages. Nothing in the library
performs I/O, so every stage can be tested as a function and compiled for every
MoonBit backend.

```
Schema ─▶ validate ─▶ deterministic diff ─▶ risk classification ─▶ policy gate ─▶ dialect renderer
```

1. **Schema IR and JSON** describe tables, columns, indexes, foreign keys and
   explicit rename hints without accessing a database.
2. **Validation** rejects ambiguous names, dangling references, unsafe raw SQL
   fragments, invalid primary keys and rename collisions. It returns every issue
   it can find, so a schema can be fixed in one pass.
3. **Planning** calculates a stable, dependency-aware sequence and assigns each
   step a `Safe`, `Review` or `Destructive` risk.
4. **Policy** compares the plan against a ceiling. `Plan::max_risk` and
   `Plan::steps_above` are the whole mechanism; the CLI's `--max-risk` and exit
   code `2` are a thin layer over them.
5. **Rendering** quotes identifiers, applies dialect rules, and refuses to emit
   destructive SQL unless the caller explicitly opts in.

The planner never guesses a rename. A missing old name plus a new name therefore
becomes a drop and an add until an explicit hint connects them. This makes data
loss visible in review.

## Determinism

Changes are sorted by semantic phase and then lexically, so the same pair of
schemas always yields the same plan regardless of how the input was ordered.
Table creation follows foreign-key dependency depth; table removal uses reverse
dependency depth. Depth computation carries a visiting set, so cyclic references
terminate at depth zero instead of recursing.

PostgreSQL foreign keys for new tables are deferred until every table exists,
which is also what makes cyclic references expressible.

## Dialect behavior

PostgreSQL uses `ALTER TABLE` operations. Making a column required with a target
default first backfills historical NULL values, then sets `NOT NULL`, then sets
the default for future rows. A primary-key or uniqueness change is refused
during rendering rather than emitted, because the IR does not carry the
constraint name such a statement would need.

SQLite operations that cannot be expressed safely as direct alterations become
one auditable rebuild: create a temporary target table, copy mapped columns,
replace the old table, recreate indexes, and run `foreign_key_check`, all inside
a transaction. Nullable values moving into a required column are backfilled with
the explicit target default; no default means planning fails rather than
silently dropping rows. Table names beginning with `__msp_new_` are reserved for
collision-free rebuild staging and are rejected in user schemas.

## Reporting

`Plan::to_markdown` and `RenderedPlan::to_markdown` render the same deterministic
review document the CLI prints. They exist in the library, not the CLI, so a
bot or an ORM can post a migration for review without shelling out to a binary.
Identifiers are escaped for Markdown tables: a schema is configuration, but a
review artefact still must not be corrupted by an unusual name.

## The library / CLI boundary

The library has no third-party dependencies and is a pure function of its
inputs. The executable in `cmd/main` imports `moonbitlang/x` for file reading,
file writing and process exit codes. Keeping that dependency out of the library
is what lets the planner compile for `wasm`, `wasm-gc`, `js` and `native`, and
what lets it be embedded in a tool that has its own idea of I/O.

That split is also why the two are tested differently. The library is covered by
unit and public-API tests (607 of 613 lines; the remainder are branches a
validated schema cannot reach, marked as such in the source). The CLI is covered
by `scripts/cli_smoke.sh`, which asserts observable behaviour — exit status and
output — rather than internals, and by `scripts/sqlite_e2e.sh`, which pipes the
generated SQL into a real `sqlite3` database and checks that the rows survived.

## Trust boundary

Column types and default expressions remain dialect SQL fragments because a
portable planner cannot fully parse both database grammars. Validation rejects
empty fragments, semicolons and SQL comment delimiters. Callers must still treat
schema JSON as trusted configuration, not as untrusted public input.
