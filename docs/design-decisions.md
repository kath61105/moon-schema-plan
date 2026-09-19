# Design decisions

`docs/architecture.md` describes what the planner does. This page records *why*
three of its more opinionated choices were made, what the alternatives were, and
what each choice costs. Where a decision is enforced by a test or a script, that
is named, so a reader can check the claim rather than take it on trust.

A Chinese translation of this page is at
[design-decisions.zh-CN.md](design-decisions.zh-CN.md).

## Renames require an explicit hint

**What the code does.** `collect_changes` in `diff.mbt` looks up each source
table under `renamed_table_target(hints, name).unwrap_or(name)`. If no table of
that name exists in the target schema, the change is a `DropTable`. Columns
work the same way. Without a hint, a rename necessarily appears as a drop plus
an add.

**The alternative** was inferring renames from name similarity — edit distance,
or matching on type and position. It was rejected for two reasons.

The first is that **the cost of being wrong is not symmetric**:

| | Result | Cost |
| --- | --- | --- |
| Do not infer, and it was a rename | A false `Destructive` | Write one line of hint |
| Infer, and it was not a rename | A false `Safe` | The column is dropped, the data is gone, and the plan said it was safe |

The entire value of this tool is making data loss visible. A heuristic that can
conceal data loss inverts its own purpose.

The second reason is **determinism**. A similarity score depends on the whole
set of names in scope. A column matched today can stop matching tomorrow because
an unrelated column was added nearby. That would destroy the property that the
same two schemas always produce the same plan — which is exactly what makes a
plan reviewable in a pull request.

**The cost** is that the caller has to write hints. Validation carries the
weight instead: `validate_hints` rejects an unknown source or target table, an
unknown source or target column, mappings that are not one-to-one within a
table, and a rename onto a name that already exists in the source. A hint file
that has drifted away from the schema therefore fails loudly rather than
mapping the wrong pair silently. `planner_cases_test.mbt` and
`planner_order_test.mbt` cover each of those messages.

One consequence worth stating plainly: a rename is classified `Review`, never
`Safe`. Views, triggers and raw SQL in the application may still reference the
old name, and the planner cannot see any of them. An explicit hint means "the
planner is not guessing"; it does not mean "this operation is free".

## Exit code 1 and exit code 2 are different answers

**What the code does.** `cmd/main/main.mbt` defines `EXIT_USAGE = 1` and
`EXIT_POLICY = 2`. Every diagnostic path reaches the first through `fail_cli`;
only `reject_policy` reaches the second.

They call for different responses:

| Code | Meaning | What to do |
| --- | --- | --- |
| `1` | The tool **could not answer**. A bad path, malformed JSON, an invalid schema, an unknown dialect. | Fix the input and re-run. Retrying is pointless. |
| `2` | The tool **answered, and the answer is no**. The schema is valid and the plan is well formed; it simply contains a step above the policy. | A decision point for a person: either the change is wrong, or it is intended and someone approves it with `--max-risk destructive`. |

Collapsing both into `1` would leave a pipeline unable to tell "your JSON is
broken" from "you are about to drop a production column". Kept apart, CI can
treat them differently: on `2`, post the Markdown plan and require an approval;
on `1`, fail the lint stage and say no more.

Two ordering details follow from the same reasoning:

- `verify` writes its report **before** exiting `2`. The artefact has to exist
  when the build fails, because that is precisely when someone needs to read it.
- `plan` checks the policy **before** rendering, so a blocked run emits no SQL
  at all. This is not left to code review: `scripts/sqlite_e2e.sh` greps the
  blocked output for `CREATE TABLE` and fails if it finds any.

## SQLite changes become one table rebuild

**The constraint.** SQLite's `ALTER TABLE` supports renaming a table, renaming a
column, adding a column and dropping a column. Changing a column's type or
nullability, adding or removing `UNIQUE` or `PRIMARY KEY`, and changing foreign
keys are not expressible at all. SQLite's own guidance for those is the
twelve-step procedure: build a new table, copy, drop the old one, rename.

**What the code does.** In `diff_existing_table`, the SQLite branch sets
`rebuild` when foreign keys differ, a column disappeared, a column differs in
any field, or a new column is a primary key or unique. It then emits a single
`RebuildTable` change instead of several fine-grained ones.

**Why one step rather than several.** A rebuild is atomic in meaning. Emitting
`DropColumn` plus `AlterColumn` plus `AddIndex`, as the PostgreSQL path does,
would produce statements SQLite cannot execute, or interleave several rebuilds
of the same table. Collapsing them keeps the plan honest: one step is one
auditable operation carrying one risk verdict.

Several details of `sqlite_rebuild_sql` are deliberate:

- **`BEGIN IMMEDIATE`, not `BEGIN`.** The write lock is taken up front.
  Otherwise a busy database can fail with `SQLITE_BUSY` halfway through, after
  the new table exists and the copy is partly done.
- **`foreign_keys=OFF` around the whole sequence**, which is SQLite's
  recommended order — dropping and renaming the table would otherwise cascade or
  be rejected. The guarantee is restored before `COMMIT`, but not by the pragma
  alone: `PRAGMA foreign_key_check` only *reports* violations, and a script that
  ignores its output commits over them regardless. The plan therefore feeds its
  count through a `CHECK` constraint, which turns the report into a real error.
  SQL cannot make a `COMMIT` conditional on a query result, so the rollback
  comes from the client: **the migration must be applied with `sqlite3 -bail`,
  or any driver that stops at the first error**, which leaves the transaction
  open and rolls it back on exit. `scripts/sqlite_e2e.sh` asserts both
  directions against a database seeded with a deliberate orphan.
- **`__msp_new_` is a reserved prefix.** `validate_schema` rejects any user table
  whose name starts with it, so staging can never collide with a real table.
- **Backfill is explicit or the plan fails.** When a nullable column becomes
  required and the target declares a default, the copy uses
  `COALESCE(old, default)`. With no default, `validate_dialect_transition`
  refuses to plan at all rather than emitting SQL that would either fail or
  quietly insert nulls.
- **A rebuild is never `Safe`.** It is `Destructive` when a column is dropped or
  a type converts, and `Review` otherwise, because it rewrites the whole table
  either way.

### Why a column drop cannot use SQLite's native DROP COLUMN

SQLite has supported `ALTER TABLE ... DROP COLUMN` since 3.35, so an obvious
optimisation is to use it when the restrictions do not apply and to rebuild only
otherwise. That optimisation cannot be implemented soundly here, and the reason
is structural rather than a matter of effort.

SQLite documents eight conditions under which `DROP COLUMN` fails. Split them by
what this project's schema IR can actually see:

| Condition | Visible in the IR? |
| --- | --- |
| The column is, or is part of, a `PRIMARY KEY` | Yes — `Column::primary_key` |
| The column has a `UNIQUE` constraint | Yes — `Column::unique` |
| The column is indexed | Yes — `Table::indexes` |
| The column is used in a foreign key | Yes — `Table::foreign_keys` |
| The column is named in a partial index's `WHERE` clause | **No** — index predicates are not modelled |
| The column is named in a `CHECK` constraint | Yes, for constraints the schema declares — but not for any the real table also carries |
| The column is used in a generated column's expression | **No** — generated columns are not modelled |
| The column appears in a trigger or a view | **No** — neither is modelled |

Half of them are invisible, and the check-constraint row is only half visible:
the IR knows the constraints the schema declares, not any the real table also
carries. A gate built on what can be seen would emit `DROP COLUMN` for a column
that a trigger, a view or an undeclared constraint still references, and that
statement fails against the real database. For a planner
whose entire contract is to fail closed before touching data, emitting SQL that
can fail is a worse outcome than being slow.

This is the same trust boundary that governs the rest of the design: the planner
is given two schema descriptions and never inspects a database, so it can only
reason about what those descriptions contain. The rebuild is SQLite's own
prescribed procedure for the general case and is unaffected by all eight
conditions.

`sqlite_rebuild_test.mbt` locks this in: the easiest possible case for a native
drop — a column that is not a primary key, not unique, not indexed and not in
any foreign key — still produces one `RebuildTable`, and the rendered SQL
contains no `DROP COLUMN`. The same file asserts the contrast, that PostgreSQL
does drop the identical column directly, so the rebuild reads as a dialect
constraint rather than a house style.

### What the rebuild does not carry over

SQLite's generalised procedure recreates indexes, **triggers and views**. This
planner recreates indexes only, because the IR models indexes and does not model
triggers or views. `DROP TABLE` removes a table's triggers, and a view over the
old table survives but is left referring to a shape that no longer exists.

Rather than leave that to be discovered afterwards, every rebuild step says so
in its `reason`, which travels into the SQL comment, the JSON report and the
Markdown review document alike:

```
-- step-1 [review] SQLite requires an auditable table rebuild for this schema
-- change; triggers and views on the table are not recreated
```

A table carrying triggers or views therefore needs an operator to reinstate them
as part of the migration. That is a real limitation of the IR's scope, and the
plan states it rather than implying completeness it does not have.

**How it is verified.** `scripts/sqlite_e2e.sh` pipes the generated SQL into a
real `sqlite3` database and asserts that rows survive, the backfill applied, the
legacy column is gone, the index was recreated, no staging table remains, and
`integrity_check` returns ok.

## The principle underneath all three

Every point of uncertainty resolves toward refusing, not toward proceeding. The
planner does not guess a rename. It will not plan a required column without a
backfill. It renders no SQL when the policy is not met. Its exit codes separate
"I don't know" from "I won't".

The cost is a tool that is more tedious to use: you write hints, and you approve
destructive changes explicitly. What that buys is that when it does say `safe`,
the word means something.
