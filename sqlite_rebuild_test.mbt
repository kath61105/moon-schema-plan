// Why a SQLite column drop always rebuilds, locked down as behaviour.
//
// SQLite has supported `ALTER TABLE ... DROP COLUMN` since 3.35. It fails when
// the column is a primary key, is unique, is indexed, is named in a partial
// index predicate, is named in a CHECK constraint, is used in a foreign key,
// is used by a generated column, or appears in a trigger or a view.
//
// This schema IR models tables, columns, indexes and foreign keys. It does not
// model CHECK constraints, generated columns, triggers or views. Four of the
// eight conditions are therefore invisible to the planner, so no amount of
// inspection of the IR can prove that a native DROP COLUMN would succeed.
// Emitting one would mean emitting SQL that can fail against a database the
// planner was never shown — the opposite of this project's fail-closed rule.
//
// The rebuild is what SQLite's own documentation prescribes for the general
// case, and it works regardless of those four conditions.

///|
test "dropping an ordinary column still rebuilds under SQLite" {
  // Deliberately the easiest possible case for a native DROP COLUMN: the
  // column is not a primary key, not unique, not indexed and not part of any
  // foreign key. It still rebuilds, because CHECK constraints, triggers and
  // views remain outside what the IR can see.
  let before = sch("1", [
    tbl("t", [id_column(), column("keep", "TEXT"), column("plain", "TEXT")]),
  ])
  let after = sch("2", [tbl("t", [id_column(), column("keep", "TEXT")])])
  let plan = planned(before, after, @moon_schema_plan.SQLite)
  assert_eq(plan.steps.length(), 1)
  assert_eq(plan.steps[0].change.describe(), "rebuild table t")
  assert_eq(plan.max_risk(), @moon_schema_plan.Destructive)
  let sql = sql_for(plan)
  assert_false(sql.contains("DROP COLUMN"))
  assert_true(sql.contains("__msp_new_t"))
}

///|
test "PostgreSQL drops the same column directly" {
  // The contrast is the point: PostgreSQL's DROP COLUMN has no comparable
  // restriction list, so the planner uses it. The SQLite rebuild is a dialect
  // constraint, not a house style.
  let before = sch("1", [
    tbl("t", [id_column(), column("keep", "TEXT"), column("plain", "TEXT")]),
  ])
  let after = sch("2", [tbl("t", [id_column(), column("keep", "TEXT")])])
  let sql = sql_for(planned(before, after, @moon_schema_plan.PostgreSQL))
  assert_true(sql.contains("ALTER TABLE \"t\" DROP COLUMN \"plain\";"))
  assert_false(sql.contains("__msp_new_t"))
}

///|
test "a rebuild says what it cannot carry over" {
  // Declared triggers are recreated and declared views are dropped and
  // recreated around the rebuild. Anything the schema does not declare is
  // still lost, and the plan says so rather than leaving an operator to
  // discover it afterwards. The reason travels into the SQL comment, the JSON
  // report and the Markdown report alike.
  let before = sch("1", [tbl("t", [id_column(), column("v", "TEXT")])])
  let after = sch("2", [tbl("t", [id_column(), column("v", "INTEGER")])])
  let plan = planned(before, after, @moon_schema_plan.SQLite)
  assert_true(plan.steps[0].reason.contains("does not declare are lost"))
  assert_true(sql_for(plan).contains("does not declare are lost"))
  assert_true(plan.to_markdown().contains("does not declare are lost"))
}

///|
test "a rebuild recreates exactly the indexes the target schema declares" {
  let before = sch("1", [
    tbl("t", [id_column(), column("v", "TEXT")], indexes=[
      { name: "t_old_idx", columns: ["v"], unique: false, },
    ]),
  ])
  let after = sch("2", [
    tbl("t", [id_column(), column("v", "INTEGER")], indexes=[
      { name: "t_new_idx", columns: ["v"], unique: true, },
    ]),
  ])
  let sql = sql_for(planned(before, after, @moon_schema_plan.SQLite))
  assert_true(sql.contains("CREATE UNIQUE INDEX \"t_new_idx\""))
  assert_false(sql.contains("t_old_idx"))
}
