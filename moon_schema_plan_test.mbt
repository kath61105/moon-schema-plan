///|
test "public API plans and renders a safe table creation" {
  let before = @moon_schema_plan.Schema::{
    version: "1",
    tables: [],
    views: [],
  }
  let after = @moon_schema_plan.Schema::{
    version: "2",
    tables: [
      {
        name: "events",
        columns: [
          {
            name: "id",
            data_type: "INTEGER",
            nullable: false,
            default_value: None,
            primary_key: true,
            unique: false,
          },
        ],
        indexes: [],
        foreign_keys: [],
        checks: [],
        triggers: [],
      },
    ],
    views: [],
  }
  match @moon_schema_plan.build_plan(before, after, @moon_schema_plan.SQLite) {
    Err(_) => fail("expected public planner to accept the schema")
    Ok(plan) =>
      match @moon_schema_plan.render_plan(plan) {
        Err(_) => fail("expected safe plan to render")
        Ok(rendered) =>
          assert_true(rendered.sql.any(sql => sql.contains("CREATE TABLE")))
      }
  }
}
