// Cases that exercise the planning, validation and rendering paths the first
// test suite left uncovered: foreign keys on existing tables, referential
// actions, cyclic dependencies, SQLite rebuild triggers, and every validation
// message that a schema or a rename hint can produce.

///|
fn tbl(
  name : String,
  columns : Array[@moon_schema_plan.Column],
  indexes? : Array[@moon_schema_plan.Index] = [],
  foreign_keys? : Array[@moon_schema_plan.ForeignKey] = [],
) -> @moon_schema_plan.Table {
  { name, columns, indexes, foreign_keys, }
}

///|
fn sch(
  version : String,
  tables : Array[@moon_schema_plan.Table],
) -> @moon_schema_plan.Schema {
  { version, tables, }
}

///|
fn id_column() -> @moon_schema_plan.Column {
  column("id", "INTEGER", nullable=false, primary_key=true)
}

///|
fn foreign_key(
  name : String,
  column~ : String,
  references~ : String,
  on~ : String,
  on_delete? : String? = None,
  on_update? : String? = None,
) -> @moon_schema_plan.ForeignKey {
  {
    name,
    columns: [column],
    referenced_table: references,
    referenced_columns: [on],
    on_delete,
    on_update,
  }
}

///|
fn planned(
  before : @moon_schema_plan.Schema,
  after : @moon_schema_plan.Schema,
  dialect : @moon_schema_plan.Dialect,
  hints? : @moon_schema_plan.RenameHints = @moon_schema_plan.RenameHints::empty(),
) -> @moon_schema_plan.Plan {
  match @moon_schema_plan.build_plan(before, after, dialect, hints~) {
    Ok(plan) => plan
    Err(issues) =>
      abort("expected a valid plan, got \{issues.length()} validation issues")
  }
}

///|
fn rejected(
  before : @moon_schema_plan.Schema,
  after : @moon_schema_plan.Schema,
  dialect : @moon_schema_plan.Dialect,
  hints? : @moon_schema_plan.RenameHints = @moon_schema_plan.RenameHints::empty(),
) -> Array[@moon_schema_plan.ValidationIssue] {
  match @moon_schema_plan.build_plan(before, after, dialect, hints~) {
    Ok(_) => abort("expected validation to reject this input")
    Err(issues) => issues
  }
}

///|
fn sql_for(plan : @moon_schema_plan.Plan) -> String {
  match @moon_schema_plan.render_plan(plan, allow_destructive=true) {
    Ok(rendered) => rendered.sql.join("\n")
    Err(_) => abort("expected an approved plan to render")
  }
}

///|
fn reported(issues : Array[@moon_schema_plan.ValidationIssue]) -> String {
  issues.map(issue => "\{issue.path}: \{issue.message}").join("\n")
}

///|
/// The character offset of `needle`, so ordering assertions fail with the text
/// they were looking for instead of a bare index comparison.
fn offset_of(haystack : String, needle : String) -> Int {
  match haystack.find(needle) {
    Some(index) => index
    None => abort("expected the SQL to contain: \{needle}")
  }
}

///|
fn risk_of(
  plan : @moon_schema_plan.Plan,
  id : String,
) -> @moon_schema_plan.Risk {
  match plan.steps.iter().find_first(step => step.id == id) {
    Some(step) => step.risk
    None => abort("plan has no step \{id}")
  }
}

///|
test "a non-null column without a default needs review, not a safe pass" {
  let before = sch("1", [tbl("t", [id_column()])])
  let after = sch("2", [
    tbl("t", [id_column(), column("code", "TEXT", nullable=false)]),
  ])
  let plan = planned(before, after, @moon_schema_plan.PostgreSQL)
  assert_eq(plan.max_risk(), @moon_schema_plan.Review)
  assert_true(plan.steps[0].reason.contains("may reject existing rows"))
}

///|
test "a column type change is destructive" {
  let before = sch("1", [tbl("t", [id_column(), column("v", "TEXT")])])
  let after = sch("2", [tbl("t", [id_column(), column("v", "INTEGER")])])
  let plan = planned(before, after, @moon_schema_plan.PostgreSQL)
  assert_eq(plan.max_risk(), @moon_schema_plan.Destructive)
  assert_true(sql_for(plan).contains("ALTER COLUMN \"v\" TYPE INTEGER;"))
}

///|
test "a default-only change is a reviewable alteration" {
  let before = sch("1", [
    tbl("t", [id_column(), column("v", "TEXT", default_value=Some("'a'"))]),
  ])
  let after = sch("2", [
    tbl("t", [id_column(), column("v", "TEXT", default_value=Some("'b'"))]),
  ])
  let plan = planned(before, after, @moon_schema_plan.PostgreSQL)
  assert_eq(plan.max_risk(), @moon_schema_plan.Review)
  assert_true(plan.steps[0].reason.contains("require database review"))
  assert_true(sql_for(plan).contains("SET DEFAULT 'b';"))
}

///|
test "dropping a default and a not-null constraint renders both statements" {
  let before = sch("1", [
    tbl("t", [
      id_column(),
      column("v", "TEXT", nullable=false, default_value=Some("'a'")),
    ]),
  ])
  let after = sch("2", [tbl("t", [id_column(), column("v", "TEXT")])])
  let sql = sql_for(planned(before, after, @moon_schema_plan.PostgreSQL))
  assert_true(sql.contains("ALTER COLUMN \"v\" DROP NOT NULL;"))
  assert_true(sql.contains("ALTER COLUMN \"v\" DROP DEFAULT;"))
}

///|
test "dropping an index needs review and renders DROP INDEX" {
  let indexed = tbl("t", [id_column(), column("v", "TEXT")], indexes=[
    { name: "t_v_idx", columns: ["v"], unique: false, },
  ])
  let before = sch("1", [indexed])
  let after = sch("2", [tbl("t", [id_column(), column("v", "TEXT")])])
  let plan = planned(before, after, @moon_schema_plan.PostgreSQL)
  assert_eq(plan.max_risk(), @moon_schema_plan.Review)
  assert_true(plan.steps[0].reason.contains("degrade query performance"))
  assert_true(sql_for(plan).contains("DROP INDEX \"t_v_idx\";"))
}

///|
test "a changed index is dropped and recreated in that order" {
  let index_of = (unique : Bool) => {
    tbl("t", [id_column(), column("v", "TEXT")], indexes=[
      { name: "t_v_idx", columns: ["v"], unique, },
    ])
  }
  let plan = planned(
    sch("1", [index_of(false)]),
    sch("2", [index_of(true)]),
    @moon_schema_plan.PostgreSQL,
  )
  assert_eq(plan.steps.length(), 2)
  assert_true(plan.steps[0].change.describe().has_prefix("drop index"))
  assert_true(plan.steps[1].change.describe().has_prefix("create index"))
  assert_true(sql_for(plan).contains("CREATE UNIQUE INDEX \"t_v_idx\""))
}

///|
test "foreign keys on an existing table are dropped, added and replaced" {
  let parent = tbl("parent", [id_column()])
  let child_columns = [id_column(), column("parent_id", "INTEGER")]
  let stale = foreign_key(
    "child_parent_fk",
    column="parent_id",
    references="parent",
    on="id",
  )
  let replaced = foreign_key(
    "child_parent_fk",
    column="parent_id",
    references="parent",
    on="id",
    on_delete=Some("CASCADE"),
    on_update=Some("RESTRICT"),
  )
  let before = sch("1", [
    parent,
    tbl("child", child_columns, foreign_keys=[stale]),
  ])
  let after = sch("2", [
    parent,
    tbl("child", child_columns, foreign_keys=[replaced]),
  ])
  let plan = planned(before, after, @moon_schema_plan.PostgreSQL)
  assert_eq(plan.steps.length(), 2)
  assert_eq(risk_of(plan, "step-1"), @moon_schema_plan.Review)
  assert_true(plan.steps[0].change.describe().has_prefix("drop foreign key"))
  assert_true(plan.steps[0].reason.contains("removes referential protection"))
  assert_true(plan.steps[1].change.describe().has_prefix("add foreign key"))
  let sql = sql_for(plan)
  assert_true(sql.contains("DROP CONSTRAINT \"child_parent_fk\";"))
  assert_true(sql.contains("ON DELETE CASCADE"))
  assert_true(sql.contains("ON UPDATE RESTRICT"))
  assert_true(
    sql.contains("FOREIGN KEY (\"parent_id\") REFERENCES \"parent\" (\"id\")"),
  )
}

///|
test "a new table with unique and default columns renders its definitions" {
  let before = sch("1", [])
  let after = sch("2", [
    tbl(
      "t",
      [
        id_column(),
        column("email", "TEXT", unique=true),
        column("state", "TEXT", nullable=false, default_value=Some("'new'")),
      ],
      indexes=[{ name: "t_state_idx", columns: ["state"], unique: false, }],
    ),
  ])
  let sql = sql_for(planned(before, after, @moon_schema_plan.SQLite))
  assert_true(sql.contains("\"email\" TEXT UNIQUE"))
  assert_true(sql.contains("\"state\" TEXT NOT NULL DEFAULT 'new'"))
  assert_true(
    sql.contains("CREATE INDEX \"t_state_idx\" ON \"t\" (\"state\");"),
  )
}

///|
test "cyclic foreign keys still produce a deterministic plan" {
  let a = tbl("a", [id_column(), column("b_id", "INTEGER")], foreign_keys=[
    foreign_key("a_b_fk", column="b_id", references="b", on="id"),
  ])
  let b = tbl("b", [id_column(), column("a_id", "INTEGER")], foreign_keys=[
    foreign_key("b_a_fk", column="a_id", references="a", on="id"),
  ])
  let empty = sch("1", [])
  let cyclic = sch("2", [a, b])
  let plan = planned(empty, cyclic, @moon_schema_plan.PostgreSQL)
  assert_eq(
    plan.to_markdown(),
    planned(empty, sch("2", [b, a]), @moon_schema_plan.PostgreSQL).to_markdown(),
  )
  let sql = sql_for(plan)
  let first_constraint = offset_of(sql, "ADD CONSTRAINT")
  let last_create = offset_of(sql, "CREATE TABLE \"b\"")
  assert_true(first_constraint > last_create)
}

///|
test "dropped tables are removed in reverse dependency order" {
  let parent = tbl("parent", [id_column()])
  let child = tbl("child", [id_column(), column("parent_id", "INTEGER")], foreign_keys=[
    foreign_key(
      "child_parent_fk",
      column="parent_id",
      references="parent",
      on="id",
    ),
  ])
  let plan = planned(
    sch("1", [parent, child]),
    sch("2", []),
    @moon_schema_plan.PostgreSQL,
  )
  let sql = sql_for(plan)
  assert_true(
    offset_of(sql, "DROP TABLE \"child\"") <
    offset_of(sql, "DROP TABLE \"parent\""),
  )
}

///|
test "SQLite rebuilds a table when a column is dropped" {
  let before = sch("1", [
    tbl("t", [id_column(), column("keep", "TEXT"), column("gone", "TEXT")]),
  ])
  let after = sch("2", [tbl("t", [id_column(), column("keep", "TEXT")])])
  let plan = planned(before, after, @moon_schema_plan.SQLite)
  assert_eq(plan.steps.length(), 1)
  assert_eq(plan.max_risk(), @moon_schema_plan.Destructive)
  let sql = sql_for(plan)
  assert_true(sql.contains("__msp_new_t"))
  assert_false(sql.contains("\"gone\""))
}

///|
test "SQLite rebuilds a table when a unique column is added" {
  let before = sch("1", [tbl("t", [id_column()])])
  let after = sch("2", [
    tbl("t", [id_column(), column("email", "TEXT", unique=true)]),
  ])
  let plan = planned(before, after, @moon_schema_plan.SQLite)
  assert_eq(plan.steps.length(), 1)
  assert_true(plan.steps[0].change.describe() == "rebuild table t")
  assert_eq(plan.max_risk(), @moon_schema_plan.Review)
}

///|
test "SQLite rebuilds a table when a foreign key changes" {
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
  let sql = sql_for(planned(before, after, @moon_schema_plan.SQLite))
  assert_true(sql.contains("__msp_new_child"))
  assert_true(sql.contains("PRAGMA foreign_key_check;"))
}

///|
test "a SQLite rebuild backfills with the target default and recreates indexes" {
  let before = sch("1", [tbl("t", [id_column(), column("v", "TEXT")])])
  let after = sch("2", [
    tbl(
      "t",
      [
        id_column(),
        column("v", "TEXT", nullable=false, default_value=Some("'fallback'")),
      ],
      indexes=[{ name: "t_v_idx", columns: ["v"], unique: false, }],
    ),
  ])
  let sql = sql_for(planned(before, after, @moon_schema_plan.SQLite))
  assert_true(sql.contains("COALESCE(\"v\", 'fallback')"))
  assert_true(sql.contains("CREATE INDEX \"t_v_idx\" ON \"t\" (\"v\");"))
  assert_true(sql.contains("BEGIN IMMEDIATE;"))
  assert_true(sql.contains("COMMIT;"))
}

///|
test "table and column drops and renames render their own statements" {
  let before = sch("1", [tbl("old", [id_column(), column("gone", "TEXT")])])
  let after = sch("2", [tbl("new", [id_column()])])
  let hints = @moon_schema_plan.RenameHints::{
    tables: [("old", "new")],
    columns: [],
  }
  let sql = sql_for(
    planned(before, after, @moon_schema_plan.PostgreSQL, hints~),
  )
  assert_true(sql.contains("ALTER TABLE \"old\" RENAME TO \"new\";"))
  assert_true(sql.contains("ALTER TABLE \"new\" DROP COLUMN \"gone\";"))
  let dropped = planned(before, sch("2", []), @moon_schema_plan.PostgreSQL)
  assert_true(sql_for(dropped).contains("DROP TABLE \"old\";"))
}

///|
test "a hand-built SQLite alteration reports the planner invariant it broke" {
  let plan = @moon_schema_plan.Plan::{
    from_version: "1",
    to_version: "2",
    dialect: @moon_schema_plan.SQLite,
    steps: [
      {
        id: "step-1",
        risk: @moon_schema_plan.Review,
        reason: "constructed directly rather than by build_plan",
        change: @moon_schema_plan.AlterColumn(
          "t",
          column("v", "TEXT"),
          column("v", "TEXT", default_value=Some("'x'")),
        ),
      },
      {
        id: "step-2",
        risk: @moon_schema_plan.Review,
        reason: "constructed directly rather than by build_plan",
        change: @moon_schema_plan.DropForeignKey(
          "t",
          foreign_key("t_fk", column="v", references="u", on="id"),
        ),
      },
    ],
  }
  let sql = sql_for(plan)
  assert_true(sql.contains("-- internal error: SQLite alterations"))
  assert_true(sql.contains("-- internal error: SQLite foreign-key changes"))
}

///|
test "empty table and column names are reported" {
  let before = sch("1", [])
  let after = sch("2", [tbl("", [column("", "TEXT")])])
  let report = reported(rejected(before, after, @moon_schema_plan.SQLite))
  assert_true(report.contains("tables[0]: name must not be empty"))
  assert_true(report.contains("name must not be empty"))
}

///|
test "an empty version is reported" {
  let schema = sch("", [])
  assert_true(
    reported(rejected(schema, schema, @moon_schema_plan.SQLite)).contains(
      "version: version must not be empty",
    ),
  )
}

///|
test "mismatched foreign key column lists are reported" {
  let parent = tbl("parent", [id_column()])
  let broken = tbl("child", [id_column(), column("parent_id", "INTEGER")], foreign_keys=[
    {
      name: "child_parent_fk",
      columns: ["parent_id"],
      referenced_table: "parent",
      referenced_columns: [],
      on_delete: None,
      on_update: None,
    },
  ])
  let after = sch("2", [parent, broken])
  let report = reported(rejected(sch("1", []), after, @moon_schema_plan.SQLite))
  assert_true(report.contains("non-empty and equally sized"))
}

///|
test "unsupported referential actions are reported" {
  let parent = tbl("parent", [id_column()])
  let child = tbl("child", [id_column(), column("parent_id", "INTEGER")], foreign_keys=[
    foreign_key(
      "child_parent_fk",
      column="parent_id",
      references="parent",
      on="id",
      on_delete=Some("DROP EVERYTHING"),
      on_update=Some("MAYBE"),
    ),
  ])
  let report = reported(
    rejected(sch("1", []), sch("2", [parent, child]), @moon_schema_plan.SQLite),
  )
  assert_true(
    report.contains("unsupported referential action: DROP EVERYTHING"),
  )
  assert_true(report.contains("unsupported referential action: MAYBE"))
}

///|
test "column rename hints must be one-to-one within a table" {
  let before = sch("1", [
    tbl("t", [id_column(), column("a", "TEXT"), column("b", "TEXT")]),
  ])
  let after = sch("2", [tbl("t", [id_column(), column("c", "TEXT")])])
  let hints = @moon_schema_plan.RenameHints::{
    tables: [],
    columns: [("t", "a", "c"), ("t", "b", "c")],
  }
  let report = reported(
    rejected(before, after, @moon_schema_plan.PostgreSQL, hints~),
  )
  assert_true(report.contains("one-to-one within a table"))
}

///|
test "a column rename onto an existing source column is rejected" {
  let before = sch("1", [
    tbl("t", [id_column(), column("a", "TEXT"), column("b", "TEXT")]),
  ])
  let after = sch("2", [tbl("t", [id_column(), column("b", "TEXT")])])
  let hints = @moon_schema_plan.RenameHints::{
    tables: [],
    columns: [("t", "a", "b")],
  }
  let report = reported(
    rejected(before, after, @moon_schema_plan.PostgreSQL, hints~),
  )
  assert_true(report.contains("already exists in the source table: b"))
}

///|
test "column rename hints naming an unknown table or column are rejected" {
  let before = sch("1", [tbl("t", [id_column(), column("a", "TEXT")])])
  let after = sch("2", [tbl("t", [id_column(), column("a", "TEXT")])])
  let unknown_table = @moon_schema_plan.RenameHints::{
    tables: [],
    columns: [("absent", "a", "b")],
  }
  let report = reported(
    rejected(before, after, @moon_schema_plan.PostgreSQL, hints=unknown_table),
  )
  assert_true(report.contains("unknown source table"))
  assert_true(report.contains("unknown target table"))
  let unknown_column = @moon_schema_plan.RenameHints::{
    tables: [],
    columns: [("t", "a", "absent")],
  }
  assert_true(
    reported(
      rejected(
        before,
        after,
        @moon_schema_plan.PostgreSQL,
        hints=unknown_column,
      ),
    ).contains("unknown target column: absent"),
  )
}

///|
test "plans and rendered plans serialise to JSON" {
  let before = sch("1", [tbl("t", [id_column()])])
  let after = sch("2", [tbl("t", [id_column(), column("v", "TEXT")])])
  let plan = planned(before, after, @moon_schema_plan.PostgreSQL)
  let plan_json = @moon_schema_plan.plan_to_json(plan).stringify()
  assert_true(plan_json.contains("\"from_version\":\"1\""))
  assert_true(plan_json.contains("\"to_version\":\"2\""))
  match @moon_schema_plan.render_plan(plan) {
    Err(_) => fail("expected a safe plan to render")
    Ok(rendered) => {
      let rendered_json = @moon_schema_plan.rendered_plan_to_json(rendered).stringify()
      assert_true(rendered_json.contains("\"sql\":["))
      assert_true(rendered_json.contains("ADD COLUMN"))
    }
  }
}

///|
test "schema JSON survives a round trip through the public helpers" {
  let schema = sch("7", [
    tbl("t", [id_column(), column("v", "TEXT", default_value=Some("'x'"))], indexes=[
      { name: "t_v_idx", columns: ["v"], unique: true, },
    ]),
  ])
  let json = @moon_schema_plan.schema_to_json(schema)
  let restored = @moon_schema_plan.schema_from_json(json) catch {
    _ => abort("expected the derived JSON encoding to round trip")
  }
  assert_eq(restored, schema)
}
