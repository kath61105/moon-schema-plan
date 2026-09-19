# Architecture and invariants

`moon_schema_plan` is split into four deliberately small stages:

1. **Schema IR and JSON** describe tables, columns, indexes, foreign keys, and
   explicit rename hints without accessing a database.
2. **Validation** rejects ambiguous names, dangling references, unsafe raw SQL
   fragments, invalid primary keys, and rename collisions.
3. **Planning** calculates a stable, dependency-aware sequence and assigns each
   step a `Safe`, `Review`, or `Destructive` risk.
4. **Rendering** quotes identifiers, applies dialect rules, and refuses to emit
   destructive SQL unless the caller explicitly opts in.

The planner never guesses a rename. A missing old name plus a new name therefore
becomes a drop and an add until an explicit hint connects them. This makes data
loss visible in review.

## Determinism

Changes are sorted by semantic phase and then lexically. Table creation follows
foreign-key dependency depth; table removal uses reverse dependency depth.
PostgreSQL foreign keys for new tables are deferred until every table exists,
which also supports cyclic references.

## Dialect behavior

PostgreSQL uses `ALTER TABLE` operations. Making a column required with a target
default first backfills historical NULL values, then sets `NOT NULL`, then sets
the default for future rows.

SQLite operations that cannot be expressed safely as direct alterations become
one auditable rebuild: create a temporary target table, copy mapped columns,
replace the old table, recreate indexes, and run `foreign_key_check`. Nullable
values moving into a required column are backfilled with the explicit target
default. No default means planning fails. Table names beginning with
`__msp_new_` are reserved for collision-free rebuild staging.

## Trust boundary

Column types and default expressions remain dialect SQL fragments because a
portable planner cannot fully parse both database grammars. Validation rejects
empty fragments, semicolons, and SQL comment delimiters. Callers must still
treat schema JSON as trusted configuration, not untrusted public input.
