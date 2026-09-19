# Schema, hints and report JSON

Everything the CLI reads and writes uses MoonBit's derived JSON encoding of the
types in `types.mbt`. This page is the reference for that encoding; the types
themselves remain the source of truth.

## Schema

A schema is a version string and a list of tables. The version is free-form —
it is copied into the plan as `from_version` and `to_version` so a report says
which two snapshots it compares, and it is never parsed.

```json
{
  "version": "2",
  "tables": [
    {
      "name": "users",
      "columns": [
        {
          "name": "id",
          "data_type": "INTEGER",
          "nullable": false,
          "primary_key": true,
          "unique": false
        },
        {
          "name": "name",
          "data_type": "TEXT",
          "nullable": false,
          "default_value": "'anonymous'",
          "primary_key": false,
          "unique": false
        }
      ],
      "indexes": [
        { "name": "users_name_idx", "columns": ["name"], "unique": false }
      ],
      "foreign_keys": [
        {
          "name": "users_team_fk",
          "columns": ["team_id"],
          "referenced_table": "teams",
          "referenced_columns": ["id"],
          "on_delete": "CASCADE"
        }
      ]
    }
  ]
}
```

### Fields

| Field | Notes |
| --- | --- |
| `version` | Required, non-empty. Compared as text, never as a number. |
| `data_type` | A dialect SQL fragment, emitted verbatim. Must be non-empty and free of `;`, `--` and `/*`. |
| `default_value` | Optional SQL expression, emitted verbatim. **A string literal needs its own quotes**: `"'anonymous'"`, not `"anonymous"`. Same delimiter rules as `data_type`. |
| `nullable` | `false` renders `NOT NULL`. A `primary_key` column must not be nullable. |
| `primary_key` | Marking one column renders an inline `PRIMARY KEY`. Marking several renders one table-level `PRIMARY KEY (a, b)` constraint, which is how a composite key must be written. |
| `unique` | A column-level `UNIQUE`. For a multi-column constraint use a unique index instead. |
| `indexes[].name` | Must be unique across the **whole schema**, not only within its table: index names are database-wide in SQLite and schema-wide in PostgreSQL. |
| `indexes[].columns` | Must name columns of the same table, and must not be empty. |
| `foreign_keys[].columns` / `referenced_columns` | Must be non-empty and the same length. Local columns must exist in this table; referenced ones in the referenced table. |
| `on_delete` / `on_update` | Optional. One of `NO ACTION`, `RESTRICT`, `CASCADE`, `SET NULL`, `SET DEFAULT`. |

Optional fields may be omitted entirely; an omitted `default_value` means the
column has no default. The encoder likewise omits them on output, so a schema
that round-trips through `schema_to_json` is not byte-identical to one written
by hand, only semantically equal.

Table names beginning with `__msp_new_` are rejected: that prefix is reserved
for SQLite rebuild staging.

Validation reports every problem it finds rather than stopping at the first, so
a rejected schema can be fixed in one pass. Each issue carries a `path` such as
`tables.users.columns.email.data_type`.

## Rename hints

The planner never guesses a rename. Without a hint, a disappeared name and a new
name are a drop and an add — which is exactly what makes the data loss visible.
A hint connects them explicitly.

```json
{
  "tables": [["accounts", "users"]],
  "columns": [["users", "display_name", "name"]]
}
```

`tables` entries are `[old_name, new_name]`. `columns` entries are
`[table, old_column, new_column]`, where `table` is the table's name **in the
target schema** — so a table that is itself being renamed is referred to by its
new name, as above.

Hints must be one-to-one: two tables cannot rename to the same name, and two
columns of one table cannot rename to the same column. A rename onto a name that
already exists in the source is rejected rather than silently merged.

## Plan and rendered-plan reports

`--format json` prints the derived encoding of `Plan` (for `verify`) or
`RenderedPlan` (for `plan`). A rendered plan is a plan plus a `sql` array of
statements, in execution order.

```json
{
  "from_version": "1",
  "to_version": "2",
  "dialect": "PostgreSQL",
  "steps": [
    {
      "id": "step-1",
      "risk": "Review",
      "reason": "explicit rename hint supplied; dependent raw SQL may still need updates",
      "change": ["RenameTable", "accounts", "users"]
    }
  ]
}
```

A `change` is encoded as an array whose first element is the variant name and
whose remaining elements are its payload, in declaration order. The variants are
`AddTable`, `DropTable`, `RenameTable`, `AddColumn`, `DropColumn`,
`RenameColumn`, `AlterColumn`, `AddIndex`, `DropIndex`, `AddForeignKey`,
`DropForeignKey` and `RebuildTable`.

Note the one inconsistency worth knowing about: **JSON uses the MoonBit
constructor spelling** (`"PostgreSQL"`, `"Review"`), because the encoding is
derived and has to round-trip back through `FromJson`. The text, Markdown and
SQL-comment outputs, and the CLI's own `--max-risk` argument, use the lowercase
spelling produced by `Risk::label` and `Dialect::label` (`postgresql`,
`review`). Consumers reading the JSON report should match on the constructor
spelling.

Step ids are positional (`step-1`, `step-2`, …) within one plan. They identify a
step inside a report; they are not stable across schema revisions.

## Examples

`examples/` holds a working set: `schema_v1.json`, `schema_v2.json` and
`rename_hints.json`, which together rename a table and a column, add a unique
column, make a column required with a backfill default, add an index, and drop a
column. `scripts/sqlite_e2e.sh` applies exactly that migration to a real
database and checks the result.
