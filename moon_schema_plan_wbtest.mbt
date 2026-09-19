///|
fn test_column(
  name : String,
  data_type? : String = "TEXT",
  nullable? : Bool = true,
  default_value? : String? = None,
  primary_key? : Bool = false,
  unique? : Bool = false,
) -> Column {
  { name, data_type, nullable, default_value, primary_key, unique, }
}

///|
fn test_table(
  name : String,
  columns : Array[Column],
  indexes? : Array[Index] = [],
  foreign_keys? : Array[ForeignKey] = [],
  checks? : Array[CheckConstraint] = [],
) -> Table {
  { name, columns, indexes, foreign_keys, checks, }
}

///|
test "schema validation reports duplicate and dangling references" {
  let schema = Schema::{
    version: "1",
    tables: [
      test_table("users", [test_column("id"), test_column("id")], indexes=[
        { name: "by_missing", columns: ["missing"], unique: false, },
      ]),
    ],
  }
  let issues = validate_schema(schema)
  assert_eq(issues.length(), 2)
  assert_eq(issues[0].message, "duplicate name: id")
  assert_eq(issues[1].message, "unknown column: missing")
}

///|
test "schema validation rejects unrenderable table and primary key shapes" {
  let schema = Schema::{
    version: "",
    tables: [
      test_table("empty", []),
      test_table("bad_key", [test_column("id", primary_key=true)]),
      test_table("__msp_new_reserved", [test_column("value")]),
    ],
  }
  let issues = validate_schema(schema)
  assert_true(issues.any(issue => issue.path == "version"))
  assert_true(issues.any(issue => issue.path == "tables.empty.columns"))
  assert_true(
    issues.any(issue => issue.path == "tables.bad_key.columns.id.nullable"),
  )
  assert_true(
    issues.any(issue => issue.path == "tables.__msp_new_reserved.name"),
  )
}

///|
test "schema validation reports unsafe fragments and malformed foreign keys" {
  let schema = Schema::{
    version: "1",
    tables: [
      test_table("parents", [test_column("id", nullable=false)]),
      test_table(
        "children",
        [
          test_column("id"),
          test_column(
            "payload",
            data_type="TEXT; DROP",
            default_value=Some("0--"),
          ),
        ],
        indexes=[{ name: "empty_index", columns: [], unique: false, }],
        foreign_keys=[
          {
            name: "bad_fk",
            columns: ["missing_local"],
            referenced_table: "parents",
            referenced_columns: ["missing_remote"],
            on_delete: Some("EXPLODE"),
            on_update: Some("CASCADE"),
          },
        ],
      ),
    ],
  }
  let issues = validate_schema(schema)
  assert_true(
    issues.any(issue => issue.message.contains("at least one column")),
  )
  assert_true(issues.any(issue => issue.message.contains("data type")))
  assert_true(issues.any(issue => issue.message.contains("default expression")))
  assert_true(
    issues.any(issue => issue.message == "unknown local column: missing_local"),
  )
  assert_true(
    issues.any(issue => {
      issue.message == "unknown referenced column: missing_remote"
    }),
  )
  assert_true(
    issues.any(issue => {
      issue.message == "unsupported referential action: EXPLODE"
    }),
  )
}

///|
test "planner classifies safe and destructive column changes" {
  let before = Schema::{
    version: "1",
    tables: [
      test_table("users", [
        test_column("id", nullable=false, primary_key=true),
        test_column("legacy"),
      ]),
    ],
  }
  let after = Schema::{
    version: "2",
    tables: [
      test_table("users", [
        test_column("id", nullable=false, primary_key=true),
        test_column("email", nullable=false, default_value=Some("''")),
      ]),
    ],
  }
  match build_plan(before, after, PostgreSQL) {
    Err(_) => fail("expected valid plan")
    Ok(plan) => {
      assert_eq(plan.steps.length(), 2)
      assert_true(plan.steps[0].change is AddColumn("users", _))
      assert_eq(plan.steps[0].risk, Safe)
      assert_true(plan.steps[1].change is DropColumn("users", _))
      assert_eq(plan.steps[1].risk, Destructive)
      assert_true(plan.has_destructive_changes())
    }
  }
}

///|
test "planner applies only explicit rename hints" {
  let before = Schema::{
    version: "1",
    tables: [test_table("accounts", [test_column("display_name")])],
  }
  let after = Schema::{
    version: "2",
    tables: [test_table("users", [test_column("name")])],
  }
  let hints = RenameHints::{
    tables: [("accounts", "users")],
    columns: [("users", "display_name", "name")],
  }
  match build_plan(before, after, SQLite, hints~) {
    Err(_) => fail("expected valid plan")
    Ok(plan) => {
      assert_eq(plan.steps.length(), 2)
      assert_true(plan.steps[0].change is RenameTable("accounts", "users"))
      assert_true(
        plan.steps[1].change is RenameColumn("users", "display_name", "name"),
      )
    }
  }
}

///|
test "table and column renames are ordered before dependent alterations" {
  let before = Schema::{
    version: "1",
    tables: [test_table("accounts", [test_column("nickname")])],
  }
  let after = Schema::{
    version: "2",
    tables: [test_table("users", [test_column("name", nullable=false)])],
  }
  let hints = RenameHints::{
    tables: [("accounts", "users")],
    columns: [("users", "nickname", "name")],
  }
  match build_plan(before, after, PostgreSQL, hints~) {
    Err(_) => fail("expected valid plan")
    Ok(plan) => {
      assert_true(plan.steps[0].change is RenameTable(_, _))
      assert_true(plan.steps[1].change is RenameColumn(_, _, _))
      assert_true(plan.steps[2].change is AlterColumn(_, _, _))
    }
  }
}

///|
test "SQLite table rename feeds a subsequent rebuild" {
  let before = Schema::{
    version: "1",
    tables: [test_table("accounts", [test_column("name")])],
  }
  let after = Schema::{
    version: "2",
    tables: [
      test_table("users", [
        test_column("name", nullable=false, default_value=Some("'anonymous'")),
      ]),
    ],
  }
  let hints = RenameHints::{ tables: [("accounts", "users")], columns: [], }
  match build_plan(before, after, SQLite, hints~) {
    Err(_) => fail("expected valid rename and rebuild plan")
    Ok(plan) => {
      assert_true(plan.steps[0].change is RenameTable("accounts", "users"))
      assert_true(
        plan.steps[1].change is RebuildTable({ name: "users", .. }, _, _),
      )
    }
  }
}

///|
test "new tables are ordered by foreign-key dependencies" {
  let organizations = test_table("organizations", [
    test_column("id", nullable=false, primary_key=true),
  ])
  let users = test_table(
    "users",
    [
      test_column("id", nullable=false, primary_key=true),
      test_column("organization_id"),
    ],
    foreign_keys=[
      {
        name: "users_organization_fk",
        columns: ["organization_id"],
        referenced_table: "organizations",
        referenced_columns: ["id"],
        on_delete: None,
        on_update: None,
      },
    ],
  )
  let before = Schema::{ version: "1", tables: [], }
  let after = Schema::{ version: "2", tables: [users, organizations], }
  match build_plan(before, after, PostgreSQL) {
    Err(_) => fail("expected valid plan")
    Ok(plan) => {
      assert_true(
        plan.steps[0].change is AddTable({ name: "organizations", .. }),
      )
      assert_true(plan.steps[1].change is AddTable({ name: "users", .. }))
      assert_true(plan.steps[2].change is AddForeignKey("users", _))
    }
  }
}

///|
test "plans are deterministic across schema declaration order" {
  let before = Schema::{ version: "1", tables: [], }
  let alpha = test_table("alpha", [test_column("id")])
  let beta = test_table("beta", [test_column("id")])
  let first = build_plan(
    before,
    Schema::{ version: "2", tables: [beta, alpha], },
    PostgreSQL,
  )
  let second = build_plan(
    before,
    Schema::{ version: "2", tables: [alpha, beta], },
    PostgreSQL,
  )
  assert_eq(first, second)
}

///|
test "dropped tables use reverse foreign-key dependency order" {
  let parents = test_table("parents", [
    test_column("id", nullable=false, primary_key=true),
  ])
  let children = test_table("children", [test_column("parent_id")], foreign_keys=[
    {
      name: "children_parent_fk",
      columns: ["parent_id"],
      referenced_table: "parents",
      referenced_columns: ["id"],
      on_delete: None,
      on_update: None,
    },
  ])
  let before = Schema::{ version: "1", tables: [parents, children], }
  let after = Schema::{ version: "2", tables: [], }
  match build_plan(before, after, PostgreSQL) {
    Err(_) => fail("expected valid removal plan")
    Ok(plan) => {
      assert_true(plan.steps[0].change is DropTable({ name: "children", .. }))
      assert_true(plan.steps[1].change is DropTable({ name: "parents", .. }))
    }
  }
}

///|
test "PostgreSQL defers foreign keys until all new tables exist" {
  let left = test_table(
    "left_nodes",
    [
      test_column("id", nullable=false, primary_key=true),
      test_column("right_id"),
    ],
    foreign_keys=[
      {
        name: "left_right_fk",
        columns: ["right_id"],
        referenced_table: "right_nodes",
        referenced_columns: ["id"],
        on_delete: None,
        on_update: None,
      },
    ],
  )
  let right = test_table(
    "right_nodes",
    [
      test_column("id", nullable=false, primary_key=true),
      test_column("left_id"),
    ],
    foreign_keys=[
      {
        name: "right_left_fk",
        columns: ["left_id"],
        referenced_table: "left_nodes",
        referenced_columns: ["id"],
        on_delete: None,
        on_update: None,
      },
    ],
  )
  let before = Schema::{ version: "1", tables: [], }
  let after = Schema::{ version: "2", tables: [left, right], }
  match build_plan(before, after, PostgreSQL) {
    Err(_) => fail("expected valid cyclic schema plan")
    Ok(plan) => {
      assert_true(plan.steps[0].change is AddTable(_))
      assert_true(plan.steps[1].change is AddTable(_))
      assert_true(plan.steps[2].change is AddForeignKey(_, _))
      assert_true(plan.steps[3].change is AddForeignKey(_, _))
    }
  }
}

///|
test "SQLite rejects an unpopulatable new required column" {
  let before = Schema::{
    version: "1",
    tables: [
      test_table("users", [test_column("id", nullable=false, primary_key=true)]),
    ],
  }
  let after = Schema::{
    version: "2",
    tables: [
      test_table("users", [
        test_column("id", nullable=false, primary_key=true),
        test_column("email", nullable=false),
      ]),
    ],
  }
  match build_plan(before, after, SQLite) {
    Ok(_) => fail("expected an actionable planning error")
    Err(issues) =>
      assert_eq(
        issues[0].message,
        "SQLite cannot populate a new non-null column without a default",
      )
  }
}

///|
test "SQLite rejects a required transition without a backfill default" {
  let before = Schema::{
    version: "1",
    tables: [test_table("users", [test_column("email")])],
  }
  let after = Schema::{
    version: "2",
    tables: [test_table("users", [test_column("email", nullable=false)])],
  }
  match build_plan(before, after, SQLite) {
    Ok(_) => fail("expected a missing-backfill error")
    Err(issues) =>
      assert_true(
        issues.any(issue => issue.message.contains("backfill default")),
      )
  }
}

///|
test "rename hints must form one-to-one mappings" {
  let before = Schema::{
    version: "1",
    tables: [test_table("a", []), test_table("b", [])],
  }
  let after = Schema::{ version: "2", tables: [test_table("c", [])], }
  let hints = RenameHints::{ tables: [("a", "c"), ("b", "c")], columns: [], }
  match build_plan(before, after, PostgreSQL, hints~) {
    Ok(_) => fail("expected ambiguous hint rejection")
    Err(issues) =>
      assert_true(
        issues.any(issue => {
          issue.message == "table rename hints must be one-to-one"
        }),
      )
  }
}

///|
test "invalid rename hint prevents partial planning" {
  let schema = Schema::{ version: "1", tables: [], }
  let hints = RenameHints::{
    tables: [("missing", "also_missing")],
    columns: [],
  }
  match build_plan(schema, schema, SQLite, hints~) {
    Ok(_) => fail("expected invalid hint")
    Err(issues) => assert_eq(issues.length(), 2)
  }
}

///|
test "rename hints reject existing table and column targets" {
  let before = Schema::{
    version: "1",
    tables: [
      test_table("accounts", [test_column("old"), test_column("name")]),
      test_table("users", [test_column("id")]),
    ],
  }
  let after = Schema::{
    version: "2",
    tables: [test_table("users", [test_column("name")])],
  }
  let hints = RenameHints::{
    tables: [("accounts", "users")],
    columns: [("users", "old", "name")],
  }
  match build_plan(before, after, PostgreSQL, hints~) {
    Ok(_) => fail("expected rename collision rejection")
    Err(issues) => {
      assert_true(issues.any(issue => issue.message.contains("source schema")))
      assert_true(issues.any(issue => issue.message.contains("source table")))
    }
  }
}

///|
test "destructive SQL is blocked by default" {
  let before = Schema::{
    version: "1",
    tables: [test_table("events", [test_column("id"), test_column("payload")])],
  }
  let after = Schema::{
    version: "2",
    tables: [test_table("events", [test_column("id")])],
  }
  match build_plan(before, after, PostgreSQL) {
    Err(_) => fail("expected valid plan")
    Ok(plan) =>
      match render_plan(plan) {
        Ok(_) => fail("expected destructive render gate")
        Err(issues) => {
          assert_eq(issues.length(), 1)
          assert_eq(issues[0].step_id, "step-1")
        }
      }
  }
}

///|
test "PostgreSQL renderer quotes identifiers and emits ordered SQL" {
  let before = Schema::{ version: "1", tables: [], }
  let after = Schema::{
    version: "2",
    tables: [
      test_table(
        "user",
        [
          test_column(
            "id",
            data_type="BIGINT",
            nullable=false,
            primary_key=true,
          ),
          test_column("email", nullable=false),
        ],
        indexes=[{ name: "user_email_idx", columns: ["email"], unique: true, }],
      ),
    ],
  }
  match build_plan(before, after, PostgreSQL) {
    Err(_) => fail("expected valid plan")
    Ok(plan) =>
      match render_plan(plan) {
        Err(_) => fail("expected renderable plan")
        Ok(rendered) => {
          assert_eq(rendered.sql.length(), 3)
          assert_true(rendered.sql[1].contains("CREATE TABLE \"user\""))
          assert_eq(
            rendered.sql[2],
            "CREATE UNIQUE INDEX \"user_email_idx\" ON \"user\" (\"email\");",
          )
        }
      }
  }
}

///|
test "PostgreSQL backfills nulls before adding a required constraint" {
  let before = Schema::{
    version: "1",
    tables: [test_table("users", [test_column("name")])],
  }
  let after = Schema::{
    version: "2",
    tables: [
      test_table("users", [
        test_column("name", nullable=false, default_value=Some("'anonymous'")),
      ]),
    ],
  }
  match build_plan(before, after, PostgreSQL) {
    Err(_) => fail("expected valid plan")
    Ok(plan) =>
      match render_plan(plan) {
        Err(_) => fail("expected renderable plan")
        Ok(rendered) => {
          assert_true(
            rendered.sql[1].has_prefix("UPDATE \"users\" SET \"name\""),
          )
          assert_true(rendered.sql[2].has_suffix("SET NOT NULL;"))
          assert_true(rendered.sql[3].has_suffix("SET DEFAULT 'anonymous';"))
        }
      }
  }
}

///|
test "renderer blocks unnamed key-constraint alterations" {
  let before = Schema::{
    version: "1",
    tables: [test_table("users", [test_column("email")])],
  }
  let after = Schema::{
    version: "2",
    tables: [test_table("users", [test_column("email", unique=true)])],
  }
  match build_plan(before, after, PostgreSQL) {
    Err(_) => fail("expected valid plan")
    Ok(plan) =>
      match render_plan(plan, allow_destructive=true) {
        Ok(_) => fail("expected unnamed constraint rejection")
        Err(issues) =>
          assert_true(issues[0].message.contains("constraint name"))
      }
  }
}

///|
test "SQLite uses a transactional rebuild for incompatible alteration" {
  let before = Schema::{
    version: "1",
    tables: [
      test_table("items", [
        test_column("id"),
        test_column("quantity", data_type="TEXT"),
      ]),
    ],
  }
  let after = Schema::{
    version: "2",
    tables: [
      test_table("items", [
        test_column("id"),
        test_column("quantity", data_type="INTEGER"),
      ]),
    ],
  }
  match build_plan(before, after, SQLite) {
    Err(_) => fail("expected valid plan")
    Ok(plan) => {
      assert_eq(plan.steps.length(), 1)
      assert_true(plan.steps[0].change is RebuildTable(_, _, _))
      match render_plan(plan, allow_destructive=true) {
        Err(_) => fail("expected explicit destructive render")
        Ok(rendered) => {
          assert_true(rendered.sql.any(sql => sql == "BEGIN IMMEDIATE;"))
          assert_true(
            rendered.sql.any(sql => {
              sql.contains("INSERT INTO \"__msp_new_items\"") &&
              sql.contains("SELECT \"id\", \"quantity\" FROM \"items\"")
            }),
          )
          assert_true(
            rendered.sql.any(sql => sql == "PRAGMA foreign_key_check;"),
          )
        }
      }
    }
  }
}

///|
test "schema JSON representation round trips" {
  let schema = Schema::{
    version: "1",
    tables: [
      test_table("users", [test_column("id", nullable=false, primary_key=true)]),
    ],
  }
  let encoded = schema_to_json(schema)
  inspect(
    encoded.stringify(indent=2),
    content=(
      #|{
      #|  "version": "1",
      #|  "tables": [
      #|    {
      #|      "name": "users",
      #|      "columns": [
      #|        {
      #|          "name": "id",
      #|          "data_type": "TEXT",
      #|          "nullable": false,
      #|          "primary_key": true,
      #|          "unique": false
      #|        }
      #|      ],
      #|      "indexes": [],
      #|      "foreign_keys": [],
      #|      "checks": []
      #|    }
      #|  ]
      #|}
    ),
  )
  let decoded = schema_from_json(encoded)
  assert_eq(decoded, schema)
}
