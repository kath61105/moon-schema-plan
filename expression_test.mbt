// Two limits that used to be left to the database to discover: a check
// constraint that outlives the column it names, and a PostgreSQL identifier
// long enough to be silently truncated into a collision.

///|
fn checked_table(
  columns : Array[@moon_schema_plan.Column],
  expression : String,
) -> @moon_schema_plan.Table {
  tbl("t", columns, checks=[{ name: "t_rule", expression, }])
}

///|
test "a check that names a dropped column is reported" {
  let before = sch("1", [
    checked_table(
      [id_column(), column("quantity", "INTEGER"), column("legacy", "INTEGER")],
      "legacy > 0",
    ),
  ])
  let after = sch("2", [
    checked_table([id_column(), column("quantity", "INTEGER")], "legacy > 0"),
  ])
  let report = reported(rejected(before, after, @moon_schema_plan.PostgreSQL))
  assert_true(report.contains("tables.t.checks.t_rule.expression"))
  assert_true(
    report.contains("references a column this change removes: legacy"),
  )
}

///|
test "a check that names a renamed column is reported" {
  // After a rename the old name is gone just the same, and the planner cannot
  // rewrite the expression for the caller.
  let before = sch("1", [
    checked_table([id_column(), column("old", "INTEGER")], "old > 0"),
  ])
  let after = sch("2", [
    checked_table([id_column(), column("new", "INTEGER")], "old > 0"),
  ])
  let hints = @moon_schema_plan.RenameHints::{
    tables: [],
    columns: [("t", "old", "new")],
  }
  assert_true(
    reported(rejected(before, after, @moon_schema_plan.PostgreSQL, hints~)).contains(
      "references a column this change removes: old",
    ),
  )
}

///|
test "a check updated alongside the rename is accepted" {
  let before = sch("1", [
    checked_table([id_column(), column("old", "INTEGER")], "old > 0"),
  ])
  let after = sch("2", [
    checked_table([id_column(), column("new", "INTEGER")], "new > 0"),
  ])
  let hints = @moon_schema_plan.RenameHints::{
    tables: [],
    columns: [("t", "old", "new")],
  }
  let plan = planned(before, after, @moon_schema_plan.PostgreSQL, hints~)
  assert_true(plan.steps.length() > 0)
}

///|
test "a removed name inside a string literal is not a reference" {
  let before = sch("1", [
    checked_table(
      [id_column(), column("note", "TEXT"), column("legacy", "INTEGER")],
      "note <> 'legacy'",
    ),
  ])
  let after = sch("2", [
    checked_table([id_column(), column("note", "TEXT")], "note <> 'legacy'"),
  ])
  let plan = planned(before, after, @moon_schema_plan.PostgreSQL)
  assert_eq(plan.steps.length(), 1)
  assert_eq(plan.steps[0].change.describe(), "drop column t.legacy")
}

///|
test "a quoted identifier is still a reference" {
  let before = sch("1", [
    checked_table(
      [id_column(), column("note", "TEXT"), column("legacy", "INTEGER")],
      "\"legacy\" > 0",
    ),
  ])
  let after = sch("2", [
    checked_table([id_column(), column("note", "TEXT")], "\"legacy\" > 0"),
  ])
  assert_true(
    reported(rejected(before, after, @moon_schema_plan.PostgreSQL)).contains(
      "references a column this change removes: legacy",
    ),
  )
}

///|
test "an unrelated check on an unrelated column is untouched" {
  let before = sch("1", [
    checked_table(
      [id_column(), column("quantity", "INTEGER"), column("legacy", "INTEGER")],
      "quantity > 0",
    ),
  ])
  let after = sch("2", [
    checked_table([id_column(), column("quantity", "INTEGER")], "quantity > 0"),
  ])
  let plan = planned(before, after, @moon_schema_plan.PostgreSQL)
  assert_eq(plan.steps[0].change.describe(), "drop column t.legacy")
}

///|
fn long_name(length : Int) -> String {
  let builder = StringBuilder()
  for i = 0; i < length; i = i + 1 {
    builder.write_char('a')
  }
  builder.to_string()
}

///|
test "PostgreSQL reports an identifier it would silently truncate" {
  let name = long_name(64)
  let schema = sch("2", [tbl(name, [id_column()])])
  let report = reported(
    rejected(sch("1", []), schema, @moon_schema_plan.PostgreSQL),
  )
  assert_true(report.contains("truncates an identifier over 63 bytes"))
  assert_true(report.contains("this table name is 64 bytes"))
}

///|
test "the limit is exactly 63 bytes" {
  let ok = sch("2", [tbl(long_name(63), [id_column()])])
  assert_eq(@moon_schema_plan.validate_schema(ok).length(), 0)
  let plan = planned(sch("1", []), ok, @moon_schema_plan.PostgreSQL)
  assert_eq(plan.steps.length(), 1)
}

///|
test "the limit counts bytes, not characters" {
  // Each of these is three UTF-8 bytes, so 22 of them fit and 22 do not once
  // one more character is added.
  let builder = StringBuilder()
  for i = 0; i < 22; i = i + 1 {
    builder.write_char('表')
  }
  let name = builder.to_string()
  assert_eq(name.char_length(), 22)
  let schema = sch("2", [tbl(name + "x", [id_column()])])
  assert_true(
    reported(rejected(sch("1", []), schema, @moon_schema_plan.PostgreSQL)).contains(
      "is 67 bytes",
    ),
  )
}

///|
test "every kind of identifier is measured" {
  let name = long_name(64)
  let table = tbl(
    "t",
    [id_column(), column(name, "INTEGER")],
    indexes=[{ name, columns: ["id"], unique: false, }],
    checks=[{ name, expression: "id > 0", }],
  )
  let report = reported(
    rejected(sch("1", []), sch("2", [table]), @moon_schema_plan.PostgreSQL),
  )
  assert_true(report.contains("this column name is 64 bytes"))
  assert_true(report.contains("this index name is 64 bytes"))
  assert_true(report.contains("this constraint name is 64 bytes"))
}

///|
test "SQLite has no such limit and is not restricted" {
  let schema = sch("2", [tbl(long_name(200), [id_column()])])
  let plan = planned(sch("1", []), schema, @moon_schema_plan.SQLite)
  assert_eq(plan.steps.length(), 1)
}
