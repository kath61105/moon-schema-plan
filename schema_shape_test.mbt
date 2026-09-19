// Regressions for two shapes that used to render SQL a database rejects.
//
// Both were found by feeding generated output to sqlite3 rather than by
// reading it. scripts/sqlite_e2e.sh now executes both cases end to end.

///|
fn key_column(name : String) -> @moon_schema_plan.Column {
  column(name, "INTEGER", nullable=false, primary_key=true)
}

///|
test "a composite primary key becomes one table-level constraint" {
  // Previously each key column carried its own inline PRIMARY KEY, which both
  // SQLite and PostgreSQL reject as more than one primary key per table.
  let membership = tbl("membership", [
    key_column("user_id"),
    key_column("team_id"),
    column("joined_at", "TEXT"),
  ])
  let sql = sql_for(
    planned(sch("1", []), sch("2", [membership]), @moon_schema_plan.SQLite),
  )
  assert_true(sql.contains("PRIMARY KEY (\"user_id\", \"team_id\")"))
  assert_false(sql.contains("\"user_id\" INTEGER PRIMARY KEY"))
  assert_false(sql.contains("\"team_id\" INTEGER PRIMARY KEY"))
}

///|
test "a single-column primary key keeps the inline form" {
  // SQLite treats an inline `INTEGER PRIMARY KEY` as a rowid alias and a
  // separate `PRIMARY KEY("id")` clause as an ordinary index, so the two
  // spellings are not interchangeable and the single-column case must not
  // drift to the table-level form.
  let sql = sql_for(
    planned(
      sch("1", []),
      sch("2", [tbl("t", [id_column(), column("v", "TEXT")])]),
      @moon_schema_plan.SQLite,
    ),
  )
  assert_true(sql.contains("\"id\" INTEGER PRIMARY KEY NOT NULL"))
  assert_false(sql.contains("PRIMARY KEY ("))
}

///|
test "a composite key survives a SQLite rebuild" {
  let before = tbl("membership", [
    key_column("user_id"),
    key_column("team_id"),
    column("note", "TEXT"),
  ])
  let after = tbl("membership", [
    key_column("user_id"),
    key_column("team_id"),
    column("note", "INTEGER"),
  ])
  let sql = sql_for(
    planned(sch("1", [before]), sch("2", [after]), @moon_schema_plan.SQLite),
  )
  assert_true(sql.contains("__msp_new_membership"))
  assert_true(sql.contains("PRIMARY KEY (\"user_id\", \"team_id\")"))
}

///|
test "two tables cannot share an index name" {
  // Index names are database-wide in SQLite and schema-wide in PostgreSQL. The
  // per-table duplicate check could not see this, so the renderer emitted a
  // CREATE INDEX that failed on the second table.
  let indexed = (table : String) => {
    tbl(table, [id_column(), column("v", "TEXT")], indexes=[
      { name: "shared_idx", columns: ["v"], unique: false, },
    ])
  }
  let schema = sch("2", [indexed("a"), indexed("b")])
  let report = reported(
    rejected(sch("1", []), schema, @moon_schema_plan.SQLite),
  )
  assert_true(report.contains("already used by another table"))
  assert_true(report.contains("tables.b.indexes.shared_idx"))
}

///|
test "the same index name on one table is still reported once per table" {
  let schema = sch("2", [
    tbl("a", [id_column(), column("v", "TEXT")], indexes=[
      { name: "dup_idx", columns: ["v"], unique: false, },
      { name: "dup_idx", columns: ["id"], unique: false, },
    ]),
  ])
  let report = reported(
    rejected(sch("1", []), schema, @moon_schema_plan.SQLite),
  )
  assert_true(report.contains("duplicate name: dup_idx"))
}

///|
test "distinct index names across tables remain valid" {
  let indexed = (table : String, index : String) => {
    tbl(table, [id_column(), column("v", "TEXT")], indexes=[
      { name: index, columns: ["v"], unique: false, },
    ])
  }
  let schema = sch("2", [indexed("a", "a_v_idx"), indexed("b", "b_v_idx")])
  assert_eq(@moon_schema_plan.validate_schema(schema).length(), 0)
}
