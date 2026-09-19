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

///|
test "escaped quotes inside a fragment are handled" {
  // '' closes nothing, and "" is a literal quote within an identifier, so a
  // removed column named either side of one must still be found or ignored
  // correctly.
  let before = sch("1", [
    checked_table(
      [id_column(), column("note", "TEXT"), column("legacy", "INTEGER")],
      "note <> 'it''s legacy' AND legacy > 0",
    ),
  ])
  let after = sch("2", [
    checked_table(
      [id_column(), column("note", "TEXT")],
      "note <> 'it''s legacy' AND legacy > 0",
    ),
  ])
  let report = reported(rejected(before, after, @moon_schema_plan.PostgreSQL))
  // Reported once, for the bare identifier -- not for the one in the literal.
  assert_true(
    report.contains("references a column this change removes: legacy"),
  )
  let escaped_before = sch("1", [
    checked_table(
      [id_column(), column("od\"d", "INTEGER"), column("keep", "INTEGER")],
      "\"od\"\"d\" > 0",
    ),
  ])
  let escaped_after = sch("2", [
    checked_table([id_column(), column("keep", "INTEGER")], "\"od\"\"d\" > 0"),
  ])
  assert_true(
    reported(
      rejected(escaped_before, escaped_after, @moon_schema_plan.PostgreSQL),
    ).contains("references a column this change removes: od\"d"),
  )
}

///|
test "identifier length counts every UTF-8 width" {
  // One character of each width: 1, 2, 3 and 4 bytes.
  let mixed = "a" + "é" + "表" + "😀"
  let padding = long_name(60)
  let schema = sch("2", [tbl(padding + mixed, [id_column()])])
  // 60 + 1 + 2 + 3 + 4 = 70 bytes.
  assert_true(
    reported(rejected(sch("1", []), schema, @moon_schema_plan.PostgreSQL)).contains(
      "is 70 bytes",
    ),
  )
}

///|
test "a hand-built SQLite check drop reports the planner invariant it broke" {
  let plan = @moon_schema_plan.Plan::{
    from_version: "1",
    to_version: "2",
    dialect: @moon_schema_plan.SQLite,
    steps: [
      {
        id: "step-1",
        risk: @moon_schema_plan.Review,
        reason: "constructed directly rather than by build_plan",
        change: @moon_schema_plan.DropCheck("t", {
          name: "t_rule",
          expression: "id > 0",
        }),
      },
    ],
  }
  assert_true(
    sql_for(plan).contains("-- internal error: SQLite check-constraint changes"),
  )
}

///|
test "a table missing a required field names the field" {
  let schema : Json = { "version": "1", "tables": [{ "name": "t" }] }
  try @moon_schema_plan.schema_from_json(schema) |> ignore catch {
    error => assert_true(error.to_string().contains("Missing field columns"))
  } noraise {
    _ => fail("expected a table without columns to be rejected")
  }
}
