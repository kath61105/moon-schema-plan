// Triggers and views, and the rebuild bug that modelling them fixes.
//
// Before they were modelled, a SQLite rebuild of a table that any view
// referenced failed outright: `ALTER TABLE ... RENAME TO` refuses to run while
// a view in the schema points at a table that is momentarily missing.

///|
fn trigger_of(
  name : String,
  action? : String = "FOR EACH ROW BEGIN SELECT 1; END",
) -> @moon_schema_plan.Trigger {
  { name, timing: "AFTER", event: "INSERT", action, }
}

///|
fn view_of(name : String, definition : String) -> @moon_schema_plan.View {
  { name, definition, }
}

///|
test "a trigger is created with its timing, event and action" {
  let before = sch("1", [tbl("t", [id_column()])])
  let after = sch("2", [
    tbl("t", [id_column()], triggers=[trigger_of("t_audit")]),
  ])
  let plan = planned(before, after, @moon_schema_plan.SQLite)
  assert_eq(plan.steps.length(), 1)
  assert_eq(plan.steps[0].change.describe(), "add trigger t_audit on t")
  assert_eq(plan.max_risk(), @moon_schema_plan.Review)
  assert_true(
    sql_for(plan).contains(
      "CREATE TRIGGER \"t_audit\" AFTER INSERT ON \"t\" FOR EACH ROW BEGIN SELECT 1; END;",
    ),
  )
}

///|
test "dropping a trigger names its table only where the dialect needs it" {
  let before = sch("1", [
    tbl("t", [id_column()], triggers=[trigger_of("t_audit")]),
  ])
  let after = sch("2", [tbl("t", [id_column()])])
  // PostgreSQL scopes a trigger to its table; SQLite's are schema-wide.
  assert_true(
    sql_for(planned(before, after, @moon_schema_plan.PostgreSQL)).contains(
      "DROP TRIGGER \"t_audit\" ON \"t\";",
    ),
  )
  assert_true(
    sql_for(planned(before, after, @moon_schema_plan.SQLite)).contains(
      "DROP TRIGGER \"t_audit\";",
    ),
  )
}

///|
test "a changed trigger is dropped and recreated in that order" {
  let with_action = (action : String) => {
    sch("1", [
      tbl("t", [id_column()], triggers=[trigger_of("t_audit", action~)]),
    ])
  }
  let plan = planned(
    with_action("FOR EACH ROW BEGIN SELECT 1; END"),
    with_action("FOR EACH ROW BEGIN SELECT 2; END"),
    @moon_schema_plan.SQLite,
  )
  assert_eq(plan.steps.length(), 2)
  assert_true(plan.steps[0].change.describe().has_prefix("drop trigger"))
  assert_true(plan.steps[1].change.describe().has_prefix("add trigger"))
}

///|
test "a view is created after the tables it reads and dropped before them" {
  let table = tbl("t", [id_column()])
  let before = sch("1", [])
  let after = sch("2", [table], views=[view_of("v", "SELECT id FROM t")])
  let plan = planned(before, after, @moon_schema_plan.PostgreSQL)
  assert_eq(plan.steps[0].change.describe(), "create table t")
  assert_eq(plan.steps[1].change.describe(), "create view v")
  let sql = sql_for(plan)
  assert_true(sql.contains("CREATE VIEW \"v\" AS SELECT id FROM t;"))
  let removal = planned(after, sch("3", []), @moon_schema_plan.PostgreSQL)
  assert_eq(removal.steps[0].change.describe(), "drop view v")
  assert_eq(removal.steps[1].change.describe(), "drop table t")
  assert_true(sql_for(removal).contains("DROP VIEW \"v\";"))
}

///|
test "a SQLite rebuild is bracketed by dropping and recreating every view" {
  // This is the whole reason views are modelled: without the bracket, the
  // rename inside the rebuild fails with "error in view ...: no such table".
  let typed = (data_type : String) => {
    tbl("x", [id_column(), column("v", data_type)])
  }
  let views = [view_of("vx", "SELECT id, v FROM x")]
  let plan = planned(
    sch("1", [typed("TEXT")], views~),
    sch("2", [typed("INTEGER")], views~),
    @moon_schema_plan.SQLite,
  )
  let described = plan.steps.map(step => step.change.describe())
  assert_eq(described, ["drop view vx", "rebuild table x", "create view vx"])
  let sql = sql_for(plan)
  assert_true(
    sql.index_of_or_fail("DROP VIEW") < sql.index_of_or_fail("__msp_new_x"),
  )
  assert_true(
    sql.index_of_or_fail("__msp_new_x") < sql.index_of_or_fail("CREATE VIEW"),
  )
}

///|
test "PostgreSQL leaves an unchanged view alone" {
  // Only SQLite has to take views down, because only SQLite rebuilds.
  let typed = (data_type : String) => {
    tbl("x", [id_column(), column("v", data_type)])
  }
  let views = [view_of("vx", "SELECT id, v FROM x")]
  let plan = planned(
    sch("1", [typed("TEXT")], views~),
    sch("2", [typed("BIGINT")], views~),
    @moon_schema_plan.PostgreSQL,
  )
  assert_eq(plan.steps.map(step => step.change.describe()), ["alter column x.v"])
}

///|
test "a rebuild recreates the table's triggers" {
  let typed = (data_type : String) => {
    tbl("x", [id_column(), column("v", data_type)], triggers=[
      trigger_of("x_audit"),
    ])
  }
  let sql = sql_for(
    planned(
      sch("1", [typed("TEXT")]),
      sch("2", [typed("INTEGER")]),
      @moon_schema_plan.SQLite,
    ),
  )
  assert_true(sql.contains("__msp_new_x"))
  assert_true(sql.contains("CREATE TRIGGER \"x_audit\""))
  assert_true(
    sql.index_of_or_fail("RENAME TO") < sql.index_of_or_fail("CREATE TRIGGER"),
  )
}

///|
test "trigger timing and event are validated" {
  let bad : @moon_schema_plan.Trigger = {
    name: "t_audit",
    timing: "SOMETIMES",
    event: "UPSERT",
    action: "",
  }
  let report = reported(
    @moon_schema_plan.validate_schema(
      sch("1", [tbl("t", [id_column()], triggers=[bad])]),
    ),
  )
  assert_true(report.contains("timing must be BEFORE, AFTER or INSTEAD OF"))
  assert_true(report.contains("event must be INSERT, UPDATE or DELETE"))
  assert_true(report.contains("trigger action must not be empty"))
}

///|
test "a trigger action may contain semicolons" {
  // A SQLite trigger body needs them between BEGIN and END, so the delimiter
  // rule that governs every other fragment cannot apply here.
  let schema = sch("1", [
    tbl("t", [id_column()], triggers=[
      trigger_of("t_audit", action="FOR EACH ROW BEGIN SELECT 1; SELECT 2; END"),
    ]),
  ])
  assert_eq(@moon_schema_plan.validate_schema(schema).length(), 0)
}

///|
test "a view definition is still delimiter checked" {
  let schema = sch("1", [tbl("t", [id_column()])], views=[
    view_of("v", "SELECT 1; DROP TABLE t"),
  ])
  assert_true(
    reported(@moon_schema_plan.validate_schema(schema)).contains(
      "view definition must be non-empty and contain no SQL statement delimiter",
    ),
  )
}

///|
test "a view cannot share a name with a table or another view" {
  let clash = sch("1", [tbl("t", [id_column()])], views=[
    view_of("t", "SELECT 1"),
  ])
  assert_true(
    reported(@moon_schema_plan.validate_schema(clash)).contains(
      "a view and a table cannot share a name",
    ),
  )
  let duplicate = sch("1", [tbl("t", [id_column()])], views=[
    view_of("v", "SELECT 1"),
    view_of("v", "SELECT 2"),
  ])
  assert_true(
    reported(@moon_schema_plan.validate_schema(duplicate)).contains(
      "duplicate name: v",
    ),
  )
}

///|
test "SQLite rejects two tables sharing a trigger name, PostgreSQL does not" {
  let schema = sch("2", [
    tbl("a", [id_column()], triggers=[trigger_of("shared")]),
    tbl("b", [id_column()], triggers=[trigger_of("shared")]),
  ])
  assert_true(
    reported(rejected(sch("1", []), schema, @moon_schema_plan.SQLite)).contains(
      "SQLite trigger names are database-wide",
    ),
  )
  // A new table carries its triggers into its own creation, as it does its
  // indexes, so this is two steps rather than four.
  let plan = planned(sch("1", []), schema, @moon_schema_plan.PostgreSQL)
  assert_eq(plan.steps.length(), 2)
  let sql = sql_for(plan)
  assert_true(sql.contains("CREATE TRIGGER \"shared\" AFTER INSERT ON \"a\""))
  assert_true(sql.contains("CREATE TRIGGER \"shared\" AFTER INSERT ON \"b\""))
}

///|
test "a schema written before views existed still decodes" {
  let legacy : Json = { "version": "1", "tables": [] }
  let schema = @moon_schema_plan.schema_from_json(legacy) catch {
    _ => abort("a 0.3.0-era schema must still decode")
  }
  assert_eq(schema.views.length(), 0)
  assert_true(
    @moon_schema_plan.schema_to_json(schema)
    .stringify()
    .contains("\"views\":[]"),
  )
}

///|
test "views and triggers of the same kind are ordered lexically" {
  // Two of each, so the sort key for a dropped view and a dropped trigger is
  // exercised rather than only the single-item path.
  let table = (name : String) => {
    tbl("t", [id_column()], triggers=[
      trigger_of("b_" + name),
      trigger_of("a_" + name),
    ])
  }
  let views = [view_of("b_view", "SELECT 1"), view_of("a_view", "SELECT 2")]
  let plan = planned(
    sch("1", [table("x")], views~),
    sch("2", [tbl("t", [id_column()])]),
    @moon_schema_plan.PostgreSQL,
  )
  let described = plan.steps.map(step => step.change.describe())
  assert_eq(described, [
    "drop view a_view", "drop view b_view", "drop trigger a_x on t", "drop trigger b_x on t",
  ])
}

///|
test "added triggers of the same kind are ordered lexically" {
  let plan = planned(
    sch("1", [tbl("t", [id_column()])]),
    sch("2", [
      tbl("t", [id_column()], triggers=[
        trigger_of("b_audit"),
        trigger_of("a_audit"),
      ]),
    ]),
    @moon_schema_plan.PostgreSQL,
  )
  assert_eq(plan.steps.map(step => step.change.describe()), [
    "add trigger a_audit on t", "add trigger b_audit on t",
  ])
}

///|
test "added views of the same kind are ordered lexically" {
  let table = tbl("t", [id_column()])
  let plan = planned(
    sch("1", [table]),
    sch("2", [table], views=[
      view_of("b_view", "SELECT 1"),
      view_of("a_view", "SELECT 2"),
    ]),
    @moon_schema_plan.PostgreSQL,
  )
  assert_eq(plan.steps.map(step => step.change.describe()), [
    "create view a_view", "create view b_view",
  ])
}

///|
test "an unchanged trigger and view produce no steps" {
  let table = tbl("t", [id_column()], triggers=[trigger_of("t_audit")])
  let views = [view_of("v", "SELECT 1")]
  let schema = sch("1", [table], views~)
  let plan = planned(schema, schema, @moon_schema_plan.PostgreSQL)
  assert_eq(plan.steps.length(), 0)
}

///|
test "a changed view definition is dropped and recreated" {
  let table = tbl("t", [id_column()])
  let plan = planned(
    sch("1", [table], views=[view_of("v", "SELECT id FROM t")]),
    sch("2", [table], views=[view_of("v", "SELECT id + 1 FROM t")]),
    @moon_schema_plan.PostgreSQL,
  )
  assert_eq(plan.steps.map(step => step.change.describe()), [
    "drop view v", "create view v",
  ])
  assert_true(sql_for(plan).contains("SELECT id + 1 FROM t"))
}

///|
test "a schema that is not an object is rejected" {
  try @moon_schema_plan.schema_from_json(["not a schema"]) |> ignore catch {
    error => assert_true(error.to_string().contains("schema"))
  } noraise {
    _ => fail("expected a non-object schema to be rejected")
  }
}
