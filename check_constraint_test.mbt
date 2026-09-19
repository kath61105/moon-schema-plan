///|
fn check_of(
  name : String,
  expression : String,
) -> @moon_schema_plan.CheckConstraint {
  { name, expression, }
}

///|
test "a new table renders its check constraints" {
  let t = tbl("orders", [id_column(), column("quantity", "INTEGER")], checks=[
    check_of("orders_quantity_positive", "quantity > 0"),
  ])
  let sql = sql_for(
    planned(sch("1", []), sch("2", [t]), @moon_schema_plan.SQLite),
  )
  assert_true(
    sql.contains("CONSTRAINT \"orders_quantity_positive\" CHECK (quantity > 0)"),
  )
}

///|
test "PostgreSQL adds and drops a check constraint in place" {
  let plain = tbl("orders", [id_column(), column("quantity", "INTEGER")])
  let constrained = tbl(
    "orders",
    [id_column(), column("quantity", "INTEGER")],
    checks=[check_of("orders_quantity_positive", "quantity > 0")],
  )
  let added = planned(
    sch("1", [plain]),
    sch("2", [constrained]),
    @moon_schema_plan.PostgreSQL,
  )
  assert_eq(added.steps.length(), 1)
  assert_eq(
    added.steps[0].change.describe(),
    "add check orders_quantity_positive on orders",
  )
  assert_eq(added.max_risk(), @moon_schema_plan.Review)
  assert_true(
    sql_for(added).contains(
      "ALTER TABLE \"orders\" ADD CONSTRAINT \"orders_quantity_positive\" CHECK (quantity > 0);",
    ),
  )
  let dropped = planned(
    sch("1", [constrained]),
    sch("2", [plain]),
    @moon_schema_plan.PostgreSQL,
  )
  assert_eq(
    dropped.steps[0].change.describe(),
    "drop check orders_quantity_positive on orders",
  )
  assert_true(dropped.steps[0].reason.contains("data-integrity constraint"))
  assert_true(
    sql_for(dropped).contains(
      "ALTER TABLE \"orders\" DROP CONSTRAINT \"orders_quantity_positive\";",
    ),
  )
}

///|
test "a changed check expression is dropped and re-added in that order" {
  let with_check = (expression : String) => {
    tbl("orders", [id_column(), column("quantity", "INTEGER")], checks=[
      check_of("orders_quantity", expression),
    ])
  }
  let plan = planned(
    sch("1", [with_check("quantity > 0")]),
    sch("2", [with_check("quantity >= 1")]),
    @moon_schema_plan.PostgreSQL,
  )
  assert_eq(plan.steps.length(), 2)
  assert_true(plan.steps[0].change.describe().has_prefix("drop check"))
  assert_true(plan.steps[1].change.describe().has_prefix("add check"))
  assert_true(sql_for(plan).contains("CHECK (quantity >= 1)"))
}

///|
test "SQLite rebuilds when a check constraint changes" {
  let plain = tbl("orders", [id_column(), column("quantity", "INTEGER")])
  let constrained = tbl(
    "orders",
    [id_column(), column("quantity", "INTEGER")],
    checks=[check_of("orders_quantity_positive", "quantity > 0")],
  )
  let plan = planned(
    sch("1", [plain]),
    sch("2", [constrained]),
    @moon_schema_plan.SQLite,
  )
  assert_eq(plan.steps.length(), 1)
  assert_eq(plan.steps[0].change.describe(), "rebuild table orders")
  let sql = sql_for(plan)
  assert_true(sql.contains("__msp_new_orders"))
  assert_true(sql.contains("CHECK (quantity > 0)"))
}

///|
test "a rebuild carries check constraints over but not triggers or views" {
  let constrained = (data_type : String) => {
    tbl("orders", [id_column(), column("quantity", data_type)], checks=[
      check_of("orders_quantity_positive", "quantity > 0"),
    ])
  }
  let plan = planned(
    sch("1", [constrained("INTEGER")]),
    sch("2", [constrained("BIGINT")]),
    @moon_schema_plan.SQLite,
  )
  assert_true(sql_for(plan).contains("CHECK (quantity > 0)"))
  assert_true(plan.steps[0].reason.contains("triggers and views"))
  assert_false(plan.steps[0].reason.contains("check constraints"))
}

///|
test "check constraints are validated like other SQL fragments" {
  let bad = tbl("orders", [id_column()], checks=[
    check_of("a", ""),
    check_of("b", "id > 0; DROP TABLE orders"),
    check_of("b", "id > 0"),
  ])
  let report = reported(
    rejected(sch("1", []), sch("2", [bad]), @moon_schema_plan.SQLite),
  )
  assert_true(report.contains("tables.orders.checks.a.expression"))
  assert_true(report.contains("tables.orders.checks.b.expression"))
  assert_true(report.contains("duplicate name: b"))
}

///|
test "a schema written before checks existed still decodes" {
  // Version 0.2.0 shipped without the field. Refusing those documents on
  // upgrade would break every stored schema over a field whose absence just
  // means "no check constraints".
  let legacy : Json = @json.parse(
    (
      #|{"version":"1","tables":[{"name":"t",
      #|"columns":[{"name":"id","data_type":"INTEGER","nullable":false,
      #|"primary_key":true,"unique":false}],
      #|"indexes":[],"foreign_keys":[]}]}
    ),
  ) catch {
    _ => abort("the fixture itself must be valid JSON")
  }
  let schema = @moon_schema_plan.schema_from_json(legacy) catch {
    _ => abort("a 0.2.0-era schema must still decode")
  }
  assert_eq(schema.tables[0].checks.length(), 0)
  assert_eq(@moon_schema_plan.validate_schema(schema).length(), 0)
  // Encoding always writes the field, so a round trip normalises the document.
  assert_true(
    @moon_schema_plan.schema_to_json(schema)
    .stringify()
    .contains("\"checks\":[]"),
  )
}

///|
test "a table that is not an object is rejected, naming where it was" {
  let schema : Json = { "version": "1", "tables": ["not a table"] }
  try @moon_schema_plan.schema_from_json(schema) |> ignore catch {
    error => assert_true(error.to_string().contains("table"))
  } noraise {
    _ => fail("expected a non-object table to be rejected")
  }
}
