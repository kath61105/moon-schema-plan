// Ordering, dependency and diagnostic cases that the first two suites reach
// only indirectly: dependency depth for new tables, cyclic references under
// SQLite, untouched indexes and foreign keys, lexical tie-breaks between
// changes of the same kind, and the remaining validation messages.

///|
test "SQLite orders new tables by their foreign-key depth" {
  let parent = tbl("parent", [id_column()])
  let child = tbl("child", [id_column(), column("parent_id", "INTEGER")], foreign_keys=[
    foreign_key(
      "child_parent_fk",
      column="parent_id",
      references="parent",
      on="id",
    ),
  ])
  let sql = sql_for(
    planned(sch("1", []), sch("2", [child, parent]), @moon_schema_plan.SQLite),
  )
  assert_true(
    offset_of(sql, "CREATE TABLE \"parent\"") <
    offset_of(sql, "CREATE TABLE \"child\""),
  )
}

///|
test "SQLite tolerates cyclic foreign keys between new tables" {
  let a = tbl("a", [id_column(), column("b_id", "INTEGER")], foreign_keys=[
    foreign_key("a_b_fk", column="b_id", references="b", on="id"),
  ])
  let b = tbl("b", [id_column(), column("a_id", "INTEGER")], foreign_keys=[
    foreign_key("b_a_fk", column="a_id", references="a", on="id"),
  ])
  let plan = planned(sch("1", []), sch("2", [a, b]), @moon_schema_plan.SQLite)
  assert_eq(plan.steps.length(), 2)
  assert_eq(
    plan.to_markdown(),
    planned(sch("1", []), sch("2", [b, a]), @moon_schema_plan.SQLite).to_markdown(),
  )
}

///|
test "a foreign key removed without a replacement is dropped" {
  let parent = tbl("parent", [id_column()])
  let columns = [id_column(), column("parent_id", "INTEGER")]
  let before = sch("1", [
    parent,
    tbl("child", columns, foreign_keys=[
      foreign_key(
        "child_parent_fk",
        column="parent_id",
        references="parent",
        on="id",
      ),
    ]),
  ])
  let after = sch("2", [parent, tbl("child", columns)])
  let plan = planned(before, after, @moon_schema_plan.PostgreSQL)
  assert_eq(plan.steps.length(), 1)
  assert_eq(
    plan.steps[0].change.describe(),
    "drop foreign key child_parent_fk on child",
  )
}

///|
test "a foreign key added to an existing table is an alteration, not a rebuild" {
  let parent = tbl("parent", [id_column()])
  let columns = [id_column(), column("parent_id", "INTEGER")]
  let before = sch("1", [parent, tbl("child", columns)])
  let after = sch("2", [
    parent,
    tbl("child", columns, foreign_keys=[
      foreign_key(
        "child_parent_fk",
        column="parent_id",
        references="parent",
        on="id",
      ),
    ]),
  ])
  let plan = planned(before, after, @moon_schema_plan.PostgreSQL)
  assert_eq(plan.steps.length(), 1)
  assert_true(
    sql_for(plan).contains(
      "ALTER TABLE \"child\" ADD CONSTRAINT \"child_parent_fk\"",
    ),
  )
}

///|
test "unchanged indexes and foreign keys produce no steps of their own" {
  let parent = tbl("parent", [id_column()])
  let key = foreign_key(
    "child_parent_fk",
    column="parent_id",
    references="parent",
    on="id",
  )
  let index : @moon_schema_plan.Index = {
    name: "child_parent_idx",
    columns: ["parent_id"],
    unique: false,
  }
  let before_child = tbl(
    "child",
    [id_column(), column("parent_id", "INTEGER")],
    indexes=[index],
    foreign_keys=[key],
  )
  let after_child = tbl(
    "child",
    [id_column(), column("parent_id", "INTEGER"), column("note", "TEXT")],
    indexes=[index],
    foreign_keys=[key],
  )
  let plan = planned(
    sch("1", [parent, before_child]),
    sch("2", [parent, after_child]),
    @moon_schema_plan.PostgreSQL,
  )
  assert_eq(plan.steps.length(), 1)
  assert_eq(plan.steps[0].change.describe(), "add column child.note")
}

///|
test "table renames of the same kind are ordered lexically" {
  let renames = @moon_schema_plan.RenameHints::{
    tables: [("b", "y"), ("a", "x")],
    columns: [],
  }
  let plan = planned(
    sch("1", [tbl("a", [id_column()]), tbl("b", [id_column()])]),
    sch("2", [tbl("x", [id_column()]), tbl("y", [id_column()])]),
    @moon_schema_plan.PostgreSQL,
    hints=renames,
  )
  assert_eq(plan.steps[0].change.describe(), "rename table a to x")
  assert_eq(plan.steps[1].change.describe(), "rename table b to y")
}

///|
test "dropped foreign keys on one table are ordered lexically" {
  let parent = tbl("parent", [id_column()])
  let columns = [id_column(), column("parent_id", "INTEGER")]
  let keys = [
    foreign_key("fk_b", column="parent_id", references="parent", on="id"),
    foreign_key("fk_a", column="parent_id", references="parent", on="id"),
  ]
  let plan = planned(
    sch("1", [parent, tbl("child", columns, foreign_keys=keys)]),
    sch("2", [parent, tbl("child", columns)]),
    @moon_schema_plan.PostgreSQL,
  )
  assert_eq(plan.steps[0].change.describe(), "drop foreign key fk_a on child")
  assert_eq(plan.steps[1].change.describe(), "drop foreign key fk_b on child")
}

///|
test "SQLite rebuilds of several tables are ordered lexically" {
  let typed = (name : String, data_type : String) => {
    tbl(name, [id_column(), column("v", data_type)])
  }
  let plan = planned(
    sch("1", [typed("zulu", "TEXT"), typed("alpha", "TEXT")]),
    sch("2", [typed("zulu", "INTEGER"), typed("alpha", "INTEGER")]),
    @moon_schema_plan.SQLite,
  )
  assert_eq(plan.steps[0].change.describe(), "rebuild table alpha")
  assert_eq(plan.steps[1].change.describe(), "rebuild table zulu")
}

///|
test "PostgreSQL adds NOT NULL without a backfill when no default exists" {
  let before = sch("1", [tbl("t", [id_column(), column("v", "TEXT")])])
  let after = sch("2", [
    tbl("t", [id_column(), column("v", "TEXT", nullable=false)]),
  ])
  let sql = sql_for(planned(before, after, @moon_schema_plan.PostgreSQL))
  assert_true(sql.contains("ALTER COLUMN \"v\" SET NOT NULL;"))
  assert_false(sql.contains("COALESCE"))
}

///|
test "PostgreSQL renders a column rename on its own" {
  let before = sch("1", [tbl("t", [id_column(), column("old", "TEXT")])])
  let after = sch("2", [tbl("t", [id_column(), column("new", "TEXT")])])
  let hints = @moon_schema_plan.RenameHints::{
    tables: [],
    columns: [("t", "old", "new")],
  }
  let plan = planned(before, after, @moon_schema_plan.PostgreSQL, hints~)
  assert_eq(plan.steps.length(), 1)
  assert_true(
    sql_for(plan).contains(
      "ALTER TABLE \"t\" RENAME COLUMN \"old\" TO \"new\";",
    ),
  )
}

///|
test "a foreign key to an unknown table or column is reported" {
  let orphan = tbl("child", [id_column(), column("parent_id", "INTEGER")], foreign_keys=[
    foreign_key(
      "child_parent_fk",
      column="parent_id",
      references="absent",
      on="id",
    ),
  ])
  assert_true(
    reported(
      rejected(sch("1", []), sch("2", [orphan]), @moon_schema_plan.SQLite),
    ).contains("unknown referenced table: absent"),
  )
  let parent = tbl("parent", [id_column()])
  let wrong_column = tbl(
    "child",
    [id_column(), column("parent_id", "INTEGER")],
    foreign_keys=[
      foreign_key(
        "child_parent_fk",
        column="parent_id",
        references="parent",
        on="absent",
      ),
    ],
  )
  assert_true(
    reported(
      rejected(
        sch("1", []),
        sch("2", [parent, wrong_column]),
        @moon_schema_plan.SQLite,
      ),
    ).contains("unknown referenced column: absent"),
  )
}

///|
test "a column rename hint naming an unknown source column is rejected" {
  let before = sch("1", [tbl("t", [id_column(), column("a", "TEXT")])])
  let after = sch("2", [tbl("t", [id_column(), column("b", "TEXT")])])
  let hints = @moon_schema_plan.RenameHints::{
    tables: [],
    columns: [("t", "absent", "b")],
  }
  assert_true(
    reported(rejected(before, after, @moon_schema_plan.PostgreSQL, hints~)).contains(
      "unknown source column",
    ),
  )
}

///|
test "a table rename onto an existing source table is rejected" {
  let before = sch("1", [tbl("a", [id_column()]), tbl("b", [id_column()])])
  let after = sch("2", [tbl("b", [id_column()])])
  let hints = @moon_schema_plan.RenameHints::{
    tables: [("a", "b")],
    columns: [],
  }
  assert_true(
    reported(rejected(before, after, @moon_schema_plan.PostgreSQL, hints~)).contains(
      "already exists in the source schema: b",
    ),
  )
}

///|
test "dropped indexes on one table are ordered lexically" {
  let indexed = tbl("t", [id_column(), column("v", "TEXT")], indexes=[
    { name: "t_idx_b", columns: ["v"], unique: false, },
    { name: "t_idx_a", columns: ["v"], unique: false, },
  ])
  let plan = planned(
    sch("1", [indexed]),
    sch("2", [tbl("t", [id_column(), column("v", "TEXT")])]),
    @moon_schema_plan.PostgreSQL,
  )
  assert_eq(plan.steps[0].change.describe(), "drop index t_idx_a on t")
  assert_eq(plan.steps[1].change.describe(), "drop index t_idx_b on t")
}

///|
test "independent dropped tables are ordered lexically" {
  let plan = planned(
    sch("1", [tbl("zulu", [id_column()]), tbl("alpha", [id_column()])]),
    sch("2", []),
    @moon_schema_plan.PostgreSQL,
  )
  assert_eq(plan.steps[0].change.describe(), "drop table alpha")
  assert_eq(plan.steps[1].change.describe(), "drop table zulu")
}

///|
test "renamed columns in one table are ordered lexically" {
  let before = sch("1", [
    tbl("t", [id_column(), column("b_old", "TEXT"), column("a_old", "TEXT")]),
  ])
  let after = sch("2", [
    tbl("t", [id_column(), column("b_new", "TEXT"), column("a_new", "TEXT")]),
  ])
  let hints = @moon_schema_plan.RenameHints::{
    tables: [],
    columns: [("t", "b_old", "b_new"), ("t", "a_old", "a_new")],
  }
  let plan = planned(before, after, @moon_schema_plan.PostgreSQL, hints~)
  assert_eq(plan.steps.length(), 2)
  assert_eq(plan.steps[0].change.describe(), "rename column t.a_old to t.a_new")
  assert_eq(plan.steps[1].change.describe(), "rename column t.b_old to t.b_new")
}
