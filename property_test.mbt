// Property-based checks of the invariants the project actually claims.
//
// Determinism, the destructive gate and the empty-diff identity were each
// covered by one or two hand-written cases. Those cases prove the property
// holds for the shapes someone thought of. These run the same claims across
// generated schemas.
//
// Generation is seeded rather than driven by `@quickcheck.check`, because a
// schema has to be valid by construction — random text is rejected by
// validation before any interesting property is reached — and because a failing
// seed is printed, which is what makes a counterexample reproducible.

///|
let generated_data_types : Array[String] = ["INTEGER", "TEXT", "BIGINT"]

///|
fn below(rng : @splitmix.RandomState, bound : Int) -> Int {
  rng.next_positive_int() % bound
}

///|
fn chance(rng : @splitmix.RandomState, one_in : Int) -> Bool {
  below(rng, one_in) == 0
}

///|
/// Every structural rule the validator enforces is respected here: names are
/// unique, key columns are not nullable, index and check names are unique
/// across the whole schema, and SQL fragments carry no statement delimiter.
fn generated_table(
  rng : @splitmix.RandomState,
  index : Int,
) -> @moon_schema_plan.Table {
  let columns : Array[@moon_schema_plan.Column] = []
  let column_count = 1 + below(rng, 4)
  for i = 0; i < column_count; i = i + 1 {
    let is_key = i == 0 || (i == 1 && chance(rng, 4))
    columns.push({
      name: "c\{i}",
      data_type: generated_data_types[below(rng, generated_data_types.length())],
      nullable: if is_key {
        false
      } else {
        chance(rng, 2)
      },
      default_value: if chance(rng, 3) {
        Some("0")
      } else {
        None
      },
      primary_key: is_key,
      unique: !is_key && chance(rng, 5),
    })
  }
  let indexes : Array[@moon_schema_plan.Index] = []
  if chance(rng, 2) {
    indexes.push({
      name: "t\{index}_idx0",
      columns: ["c0"],
      unique: chance(rng, 2),
    })
  }
  let checks : Array[@moon_schema_plan.CheckConstraint] = []
  if chance(rng, 3) {
    checks.push({ name: "t\{index}_chk0", expression: "c0 IS NOT NULL", })
  }
  { name: "t\{index}", columns, indexes, foreign_keys: [], checks, }
}

///|
fn generated_schema(
  rng : @splitmix.RandomState,
  version : String,
  table_count : Int,
) -> @moon_schema_plan.Schema {
  let tables : Array[@moon_schema_plan.Table] = []
  for i = 0; i < table_count; i = i + 1 {
    tables.push(generated_table(rng, i))
  }
  // Foreign keys are added once every table exists, and only ever point at an
  // earlier table's primary key, so references are always resolvable.
  for i = 1; i < table_count; i = i + 1 {
    if chance(rng, 3) {
      let target = below(rng, i)
      tables[i].foreign_keys.push({
        name: "t\{i}_fk\{target}",
        columns: ["c0"],
        referenced_table: "t\{target}",
        referenced_columns: ["c0"],
        on_delete: None,
        on_update: None,
      })
    }
  }
  { version, tables, }
}

///|
/// The same schema with its tables in a different order. Column order is left
/// alone: it is semantic, because it decides the column order of a created
/// table, so permuting it would not be an equivalent schema.
fn shuffled_tables(
  rng : @splitmix.RandomState,
  schema : @moon_schema_plan.Schema,
) -> @moon_schema_plan.Schema {
  let tables = schema.tables.copy()
  for i = tables.length() - 1; i > 0; i = i - 1 {
    tables.swap(i, below(rng, i + 1))
  }
  { version: schema.version, tables, }
}

///|
/// A complete, comparable rendering of a planning outcome. `Plan` derives
/// `Debug` rather than `Show`, and the JSON encoding loses nothing, so this is
/// what the properties compare.
fn plan_signature(
  result : Result[
    @moon_schema_plan.Plan,
    Array[@moon_schema_plan.ValidationIssue],
  ],
) -> String {
  match result {
    Ok(plan) => @moon_schema_plan.plan_to_json(plan).stringify()
    Err(issues) => ToJson::to_json(issues).stringify()
  }
}

///|
fn each_dialect() -> Array[@moon_schema_plan.Dialect] {
  [@moon_schema_plan.SQLite, @moon_schema_plan.PostgreSQL]
}

///|
test "property: a schema never differs from itself" {
  for seed = 0; seed < 200; seed = seed + 1 {
    let rng = @splitmix.new(seed=seed.to_uint64())
    let schema = generated_schema(rng, "1", 1 + below(rng, 4))
    for dialect in each_dialect() {
      match @moon_schema_plan.build_plan(schema, schema, dialect) {
        Err(issues) =>
          fail(
            "seed \{seed} produced an invalid schema: \{ToJson::to_json(issues).stringify()}",
          )
        Ok(plan) =>
          if plan.steps.length() != 0 {
            fail(
              "seed \{seed} diffed a schema against itself: \{plan.to_markdown()}",
            )
          }
      }
    }
  }
}

///|
test "property: table declaration order does not change the plan" {
  for seed = 0; seed < 200; seed = seed + 1 {
    let rng = @splitmix.new(seed=seed.to_uint64())
    let count = 1 + below(rng, 4)
    let before = generated_schema(rng, "1", count)
    let after = generated_schema(rng, "2", count)
    for dialect in each_dialect() {
      let direct = @moon_schema_plan.build_plan(before, after, dialect)
      let permuted = @moon_schema_plan.build_plan(
        shuffled_tables(rng, before),
        shuffled_tables(rng, after),
        dialect,
      )
      let direct_signature = plan_signature(direct)
      let permuted_signature = plan_signature(permuted)
      if direct_signature != permuted_signature {
        fail(
          "seed \{seed} changed its plan when tables were reordered; direct=\{direct_signature} permuted=\{permuted_signature}",
        )
      }
    }
  }
}

///|
test "property: a destructive plan is never rendered by default" {
  for seed = 0; seed < 200; seed = seed + 1 {
    let rng = @splitmix.new(seed=seed.to_uint64())
    let count = 1 + below(rng, 4)
    let before = generated_schema(rng, "1", count)
    let after = generated_schema(rng, "2", count)
    for dialect in each_dialect() {
      match @moon_schema_plan.build_plan(before, after, dialect) {
        Err(_) => ()
        Ok(plan) =>
          if plan.has_destructive_changes() {
            if !(@moon_schema_plan.render_plan(plan) is Err(_)) {
              fail("seed \{seed} rendered a destructive plan without approval")
            }
            if plan.max_risk() != @moon_schema_plan.Destructive {
              fail("seed \{seed} disagreed with itself about the highest risk")
            }
          }
      }
    }
  }
}

///|
test "property: rendering is deterministic and covers every step" {
  for seed = 0; seed < 200; seed = seed + 1 {
    let rng = @splitmix.new(seed=seed.to_uint64())
    let count = 1 + below(rng, 4)
    let before = generated_schema(rng, "1", count)
    let after = generated_schema(rng, "2", count)
    for dialect in each_dialect() {
      match @moon_schema_plan.build_plan(before, after, dialect) {
        Err(_) => ()
        Ok(plan) =>
          match @moon_schema_plan.render_plan(plan, allow_destructive=true) {
            // A key-constraint change is refused whatever the approval, which
            // is a separate rule from the risk policy.
            Err(_) => ()
            Ok(rendered) => {
              let again = match
                @moon_schema_plan.render_plan(plan, allow_destructive=true) {
                Ok(second) => second.sql.join("\n")
                Err(_) => abort("seed \{seed} rendered inconsistently")
              }
              if rendered.sql.join("\n") != again {
                fail("seed \{seed} rendered the same plan differently")
              }
              // Each step contributes exactly one leading comment line.
              let comments = rendered.sql.filter(line => {
                line.has_prefix("-- step-")
              })
              if comments.length() != plan.steps.length() {
                fail(
                  "seed \{seed} lost a step between plan and SQL: \{comments.length()} comments for \{plan.steps.length()} steps",
                )
              }
            }
          }
      }
    }
  }
}

///|
test "validation issues are reported in a canonical order" {
  // Found by the reordering property above: issues were collected in table
  // declaration order, so moving a table within a file changed the report
  // without changing its meaning.
  let broken = (name : String) => tbl(name, [column("v", "")])
  let first = sch("1", [broken("alpha"), broken("beta")])
  let second = sch("1", [broken("beta"), broken("alpha")])
  let render = (schema : @moon_schema_plan.Schema) => {
    @moon_schema_plan.validate_schema(schema)
    .map(issue => "\{issue.path}: \{issue.message}")
    .join("\n")
  }
  assert_eq(render(first), render(second))
  assert_true(render(first).has_prefix("tables.alpha"))
}
