///|
fn column(
  name : String,
  data_type : String,
  nullable? : Bool = true,
  default_value? : String? = None,
  primary_key? : Bool = false,
  unique? : Bool = false,
) -> @moon_schema_plan.Column {
  { name, data_type, nullable, default_value, primary_key, unique, }
}

///|
fn users_v1() -> @moon_schema_plan.Schema {
  {
    views: [],
    version: "1",
    tables: [
      {
        name: "users",
        columns: [
          column("id", "INTEGER", nullable=false, primary_key=true),
          column("nickname", "TEXT"),
          column("legacy", "TEXT"),
        ],
        indexes: [],
        foreign_keys: [],
        checks: [],
        triggers: [],
      },
    ],
  }
}

///|
fn users_v2() -> @moon_schema_plan.Schema {
  {
    views: [],
    version: "2",
    tables: [
      {
        name: "users",
        columns: [
          column("id", "INTEGER", nullable=false, primary_key=true),
          column("nickname", "TEXT"),
          column("email", "TEXT"),
        ],
        indexes: [
          { name: "users_email_idx", columns: ["email"], unique: true, },
        ],
        foreign_keys: [],
        checks: [],
        triggers: [],
      },
    ],
  }
}

///|
fn plan_v1_to_v2() -> @moon_schema_plan.Plan {
  match
    @moon_schema_plan.build_plan(
      users_v1(),
      users_v2(),
      @moon_schema_plan.PostgreSQL,
    ) {
    Ok(plan) => plan
    Err(_) => abort("expected the example schemas to plan cleanly")
  }
}

///|
test "risk severity is a total order from safe to destructive" {
  assert_eq(@moon_schema_plan.Safe.severity(), 0)
  assert_eq(@moon_schema_plan.Review.severity(), 1)
  assert_eq(@moon_schema_plan.Destructive.severity(), 2)
}

///|
test "risk labels round trip through parse" {
  for
    risk in [
      @moon_schema_plan.Safe,
      @moon_schema_plan.Review,
      @moon_schema_plan.Destructive,
    ] {
    assert_eq(@moon_schema_plan.Risk::parse(risk.label()), Some(risk))
  }
  assert_eq(@moon_schema_plan.Risk::parse("SAFE"), None)
  assert_eq(@moon_schema_plan.Risk::parse(""), None)
  assert_eq(@moon_schema_plan.Risk::parse("dangerous"), None)
}

///|
test "dialect labels round trip and accept the postgres alias" {
  assert_eq(@moon_schema_plan.SQLite.label(), "sqlite")
  assert_eq(@moon_schema_plan.PostgreSQL.label(), "postgresql")
  assert_eq(
    @moon_schema_plan.Dialect::parse("sqlite"),
    Some(@moon_schema_plan.SQLite),
  )
  assert_eq(
    @moon_schema_plan.Dialect::parse("postgres"),
    Some(@moon_schema_plan.PostgreSQL),
  )
  assert_eq(
    @moon_schema_plan.Dialect::parse("postgresql"),
    Some(@moon_schema_plan.PostgreSQL),
  )
  assert_eq(@moon_schema_plan.Dialect::parse("mysql"), None)
  assert_eq(@moon_schema_plan.Dialect::parse("SQLite"), None)
}

///|
test "summary counts every step exactly once" {
  let plan = plan_v1_to_v2()
  let summary = plan.summary()
  assert_eq(summary.total, plan.steps.length())
  assert_eq(summary.safe + summary.review + summary.destructive, summary.total)
  assert_true(summary.destructive > 0)
}

///|
test "an empty plan is safe and reports no steps" {
  let schema = @moon_schema_plan.Schema::{
    version: "1",
    tables: [],
    views: [],
  }
  match @moon_schema_plan.build_plan(schema, schema, @moon_schema_plan.SQLite) {
    Err(_) => fail("expected an empty schema pair to plan")
    Ok(plan) => {
      assert_eq(plan.max_risk(), @moon_schema_plan.Safe)
      assert_eq(plan.summary(), {
        total: 0,
        safe: 0,
        review: 0,
        destructive: 0,
      })
      assert_eq(plan.steps_above(@moon_schema_plan.Safe).length(), 0)
      assert_true(
        plan.to_markdown().contains("No schema changes were detected."),
      )
    }
  }
}

///|
test "max risk and steps_above agree with the policy threshold" {
  let plan = plan_v1_to_v2()
  assert_eq(plan.max_risk(), @moon_schema_plan.Destructive)
  assert_eq(plan.steps_above(@moon_schema_plan.Destructive).length(), 0)
  assert_eq(
    plan.steps_above(@moon_schema_plan.Review).length(),
    plan.summary().destructive,
  )
  assert_eq(
    plan.steps_above(@moon_schema_plan.Safe).length(),
    plan.summary().review + plan.summary().destructive,
  )
}

///|
test "markdown report lists every step and its risk" {
  let plan = plan_v1_to_v2()
  let markdown = plan.to_markdown()
  assert_true(markdown.contains("# Migration plan"))
  assert_true(markdown.contains("| Dialect | `postgresql` |"))
  assert_true(markdown.contains("| Highest risk | `destructive` |"))
  for step in plan.steps {
    assert_true(markdown.contains("| \{step.id} |"))
    assert_true(markdown.contains(step.change.describe()))
  }
}

///|
test "markdown report is deterministic" {
  assert_eq(plan_v1_to_v2().to_markdown(), plan_v1_to_v2().to_markdown())
}

///|
test "rendered markdown embeds the approved SQL" {
  let plan = plan_v1_to_v2()
  match @moon_schema_plan.render_plan(plan, allow_destructive=true) {
    Err(_) => fail("expected an explicitly approved plan to render")
    Ok(rendered) => {
      let markdown = rendered.to_markdown()
      assert_true(markdown.contains("## SQL"))
      assert_true(markdown.contains("```sql"))
      for statement in rendered.sql {
        assert_true(markdown.contains(statement))
      }
    }
  }
}

///|
test "markdown cells escape pipes in identifiers" {
  let before = @moon_schema_plan.Schema::{
    version: "1",
    tables: [],
    views: [],
  }
  let after = @moon_schema_plan.Schema::{
    version: "2",
    tables: [
      {
        name: "we|ird",
        columns: [column("id", "INTEGER", nullable=false, primary_key=true)],
        indexes: [],
        foreign_keys: [],
        checks: [],
        triggers: [],
      },
    ],
    views: [],
  }
  match @moon_schema_plan.build_plan(before, after, @moon_schema_plan.SQLite) {
    Err(_) => fail("expected an unusual but legal identifier to plan")
    Ok(plan) => {
      let markdown = plan.to_markdown()
      assert_true(markdown.contains("create table we\\|ird"))
      assert_false(markdown.contains("create table we|ird"))
    }
  }
}

///|
test "every change variant has a distinct description" {
  let descriptions = [
    @moon_schema_plan.Change::AddTable({
      name: "t",
      columns: [],
      indexes: [],
      foreign_keys: [],
      checks: [],
      triggers: [],
    }),
    @moon_schema_plan.Change::DropTable({
      name: "t",
      columns: [],
      indexes: [],
      foreign_keys: [],
      checks: [],
      triggers: [],
    }),
    @moon_schema_plan.Change::RenameTable("t", "u"),
    @moon_schema_plan.Change::AddColumn("t", column("c", "TEXT")),
    @moon_schema_plan.Change::DropColumn("t", column("c", "TEXT")),
    @moon_schema_plan.Change::RenameColumn("t", "c", "d"),
    @moon_schema_plan.Change::AlterColumn(
      "t",
      column("c", "TEXT"),
      column("c", "INTEGER"),
    ),
    @moon_schema_plan.Change::AddIndex("t", {
      name: "i",
      columns: ["c"],
      unique: false,
    }),
    @moon_schema_plan.Change::DropIndex("t", {
      name: "i",
      columns: ["c"],
      unique: false,
    }),
    @moon_schema_plan.Change::AddForeignKey("t", {
      name: "f",
      columns: ["c"],
      referenced_table: "u",
      referenced_columns: ["d"],
      on_delete: None,
      on_update: None,
    }),
    @moon_schema_plan.Change::DropForeignKey("t", {
      name: "f",
      columns: ["c"],
      referenced_table: "u",
      referenced_columns: ["d"],
      on_delete: None,
      on_update: None,
    }),
    @moon_schema_plan.Change::AddCheck("t", { name: "c", expression: "v > 0", }),
    @moon_schema_plan.Change::DropCheck("t", { name: "c", expression: "v > 0", }),
    @moon_schema_plan.Change::AddTrigger("t", {
      name: "g",
      timing: "AFTER",
      event: "INSERT",
      action: "FOR EACH ROW BEGIN SELECT 1; END",
    }),
    @moon_schema_plan.Change::DropTrigger("t", {
      name: "g",
      timing: "AFTER",
      event: "INSERT",
      action: "FOR EACH ROW BEGIN SELECT 1; END",
    }),
    @moon_schema_plan.Change::AddView({ name: "v", definition: "SELECT 1", }),
    @moon_schema_plan.Change::DropView({ name: "v", definition: "SELECT 1", }),
    @moon_schema_plan.Change::RebuildTable(
      {
        name: "t",
        columns: [],
        indexes: [],
        foreign_keys: [],
        checks: [],
        triggers: [],
      },
      {
        name: "t",
        columns: [],
        indexes: [],
        foreign_keys: [],
        checks: [],
        triggers: [],
      },
      [],
    ),
  ].map(change => change.describe())
  for i = 0; i < descriptions.length(); i = i + 1 {
    assert_true(descriptions[i] != "")
    for j = i + 1; j < descriptions.length(); j = j + 1 {
      assert_true(descriptions[i] != descriptions[j])
    }
  }
}
