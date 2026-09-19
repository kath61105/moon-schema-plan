// Two transitions that used to plan cleanly and then be refused by the
// database. Both were found by executing generated SQL, not by reading it.

///|
fn key_col(name : String) -> @moon_schema_plan.Column {
  column(name, "INTEGER", nullable=false, primary_key=true)
}

///|
test "PostgreSQL refuses to add a key column to a table that already has one" {
  // ALTER TABLE ... ADD COLUMN ... PRIMARY KEY only works while the table has
  // no primary key. Reshaping an existing one needs the constraint's name,
  // which the IR does not carry, so the transition is refused at plan time
  // rather than rendered into SQL PostgreSQL rejects.
  let before = sch("1", [tbl("t", [key_col("a")])])
  let after = sch("2", [tbl("t", [key_col("a"), key_col("b")])])
  let report = reported(rejected(before, after, @moon_schema_plan.PostgreSQL))
  assert_true(report.contains("tables.t.columns.b"))
  assert_true(report.contains("already has a primary key"))
}

///|
test "SQLite reaches the same change through a rebuild" {
  // The new key column carries a default, because SQLite separately refuses to
  // populate a new required column without one. That rule is about backfilling
  // rows; the PostgreSQL rule above is about naming a constraint.
  let keyed = column(
    "b",
    "INTEGER",
    nullable=false,
    primary_key=true,
    default_value=Some("0"),
  )
  let before = sch("1", [tbl("t", [key_col("a")])])
  let after = sch("2", [tbl("t", [key_col("a"), keyed])])
  let plan = planned(before, after, @moon_schema_plan.SQLite)
  assert_eq(plan.steps[0].change.describe(), "rebuild table t")
  assert_true(sql_for(plan).contains("PRIMARY KEY (\"a\", \"b\")"))
}

///|
test "a key column may still be added to a table that has no key" {
  // The restriction is about replacing a key, not about having one, so this
  // must keep working.
  let before = sch("1", [tbl("t", [column("v", "TEXT")])])
  let after = sch("2", [tbl("t", [column("v", "TEXT"), key_col("id")])])
  let sql = sql_for(planned(before, after, @moon_schema_plan.PostgreSQL))
  assert_true(sql.contains("ADD COLUMN \"id\" INTEGER PRIMARY KEY NOT NULL;"))
}

///|
fn parent_child(
  referenced : String,
  parent_columns : Array[@moon_schema_plan.Column],
  parent_indexes? : Array[@moon_schema_plan.Index] = [],
) -> @moon_schema_plan.Schema {
  sch("2", [
    tbl("p", parent_columns, indexes=parent_indexes),
    tbl("c", [key_col("id"), column("ref", "INTEGER")], foreign_keys=[
      foreign_key("c_p_fk", column="ref", references="p", on=referenced),
    ]),
  ])
}

///|
test "a foreign key must reference a uniquely constrained column set" {
  // PostgreSQL refuses the constraint outright; SQLite reports a foreign key
  // mismatch when rows are written. Neither is worth discovering in production.
  let loose = parent_child("code", [key_col("id"), column("code", "INTEGER")])
  let report = reported(
    rejected(sch("1", []), loose, @moon_schema_plan.PostgreSQL),
  )
  assert_true(report.contains("tables.c.foreign_keys.c_p_fk"))
  assert_true(
    report.contains("must be a primary key or covered by a unique index in p"),
  )
}

///|
test "a primary key, a unique column and a unique index all satisfy it" {
  let by_primary_key = parent_child("id", [key_col("id")])
  assert_eq(@moon_schema_plan.validate_schema(by_primary_key).length(), 0)
  let by_unique_column = parent_child("code", [
    key_col("id"),
    column("code", "INTEGER", unique=true),
  ])
  assert_eq(@moon_schema_plan.validate_schema(by_unique_column).length(), 0)
  let by_unique_index = parent_child(
    "code",
    [key_col("id"), column("code", "INTEGER")],
    parent_indexes=[{ name: "p_code_idx", columns: ["code"], unique: true, }],
  )
  assert_eq(@moon_schema_plan.validate_schema(by_unique_index).length(), 0)
}

///|
test "a non-unique index does not satisfy it" {
  let schema = parent_child(
    "code",
    [key_col("id"), column("code", "INTEGER")],
    parent_indexes=[{ name: "p_code_idx", columns: ["code"], unique: false, }],
  )
  assert_true(
    reported(@moon_schema_plan.validate_schema(schema)).contains(
      "must be a primary key or covered by a unique index",
    ),
  )
}

///|
test "a composite key is matched as a set, not by order" {
  let parent = tbl("p", [key_col("a"), key_col("b")])
  let child = (referenced : Array[String]) => {
    tbl("c", [key_col("id"), column("x", "INTEGER"), column("y", "INTEGER")], foreign_keys=[
      {
        name: "c_p_fk",
        columns: ["x", "y"],
        referenced_table: "p",
        referenced_columns: referenced,
        on_delete: None,
        on_update: None,
      },
    ])
  }
  assert_eq(
    @moon_schema_plan.validate_schema(sch("2", [parent, child(["a", "b"])])).length(),
    0,
  )
  assert_eq(
    @moon_schema_plan.validate_schema(sch("2", [parent, child(["b", "a"])])).length(),
    0,
  )
  // Referencing only half of a composite key is not enough.
  let partial = tbl("c", [key_col("id"), column("x", "INTEGER")], foreign_keys=[
    foreign_key("c_p_fk", column="x", references="p", on="a"),
  ])
  assert_true(
    reported(@moon_schema_plan.validate_schema(sch("2", [parent, partial]))).contains(
      "must be a primary key or covered by a unique index",
    ),
  )
}
