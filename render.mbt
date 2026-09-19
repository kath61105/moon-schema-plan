///|
fn quote_identifier(name : String) -> String {
  let escaped = name.replace_all(old="\"", new="\"\"")
  "\"" + escaped + "\""
}

///|
fn column_definition(column : Column) -> String {
  let parts : Array[String] = [quote_identifier(column.name), column.data_type]
  if column.primary_key {
    parts.push("PRIMARY KEY")
  }
  if column.unique {
    parts.push("UNIQUE")
  }
  if !column.nullable {
    parts.push("NOT NULL")
  }
  match column.default_value {
    Some(value) => parts.push("DEFAULT \{value}")
    None => ()
  }
  parts.join(" ")
}

///|
fn foreign_key_definition(foreign_key : ForeignKey) -> String {
  let local_columns = foreign_key.columns.map(quote_identifier).join(", ")
  let referenced = foreign_key.referenced_columns
    .map(quote_identifier)
    .join(", ")
  let mut sql = "CONSTRAINT \{quote_identifier(foreign_key.name)} FOREIGN KEY (\{local_columns}) REFERENCES \{quote_identifier(foreign_key.referenced_table)} (\{referenced})"
  match foreign_key.on_delete {
    Some(action) => sql = "\{sql} ON DELETE \{action}"
    None => ()
  }
  match foreign_key.on_update {
    Some(action) => sql = "\{sql} ON UPDATE \{action}"
    None => ()
  }
  sql
}

///|
fn create_table_sql(table : Table, override_name? : String? = None) -> String {
  let definitions = table.columns.map(column_definition)
  definitions.push_iter(table.foreign_keys.map(foreign_key_definition).iter())
  let name = override_name.unwrap_or(table.name)
  let body = definitions.join(",\n  ")
  "CREATE TABLE \{quote_identifier(name)} (\n  \{body}\n);"
}

///|
fn create_index_sql(table : String, index : Index) -> String {
  let unique = if index.unique { "UNIQUE " } else { "" }
  let columns = index.columns.map(quote_identifier).join(", ")
  "CREATE \{unique}INDEX \{quote_identifier(index.name)} ON \{quote_identifier(table)} (\{columns});"
}

///|
fn add_foreign_key_sql(table : String, foreign_key : ForeignKey) -> String {
  "ALTER TABLE \{quote_identifier(table)} ADD \{foreign_key_definition(foreign_key)};"
}

///|
fn postgres_alter_column(
  table : String,
  before : Column,
  after : Column,
) -> Array[String] {
  let statements : Array[String] = []
  let prefix = "ALTER TABLE \{quote_identifier(table)} ALTER COLUMN \{quote_identifier(after.name)}"
  if before.data_type != after.data_type {
    statements.push("\{prefix} TYPE \{after.data_type};")
  }
  if before.nullable != after.nullable {
    if after.nullable {
      statements.push("\{prefix} DROP NOT NULL;")
    } else {
      match after.default_value {
        Some(value) =>
          statements.push(
            "UPDATE \{quote_identifier(table)} SET \{quote_identifier(after.name)} = COALESCE(\{quote_identifier(after.name)}, \{value}) WHERE \{quote_identifier(after.name)} IS NULL;",
          )
        None => ()
      }
      statements.push("\{prefix} SET NOT NULL;")
    }
  }
  if before.default_value != after.default_value {
    match after.default_value {
      Some(value) => statements.push("\{prefix} SET DEFAULT \{value};")
      None => statements.push("\{prefix} DROP DEFAULT;")
    }
  }
  // A primary-key or uniqueness change needs a constraint name that the IR
  // does not carry, so `render_plan` refuses the whole plan before reaching
  // here rather than emitting SQL that names a constraint it guessed.
  statements
}

///|
fn sqlite_rebuild_sql(
  before : Table,
  after : Table,
  mappings : Array[(String, String)],
) -> Array[String] {
  let temporary = "__msp_new_\{after.name}"
  let target_columns = mappings
    .map(mapping => quote_identifier(mapping.1))
    .join(", ")
  let source_expressions = mappings
    .map(mapping => {
      let source_name = quote_identifier(mapping.0)
      let source = before.columns
        .iter()
        .find_first(column => column.name == mapping.0)
      let target = after.columns
        .iter()
        .find_first(column => column.name == mapping.1)
      match (source, target) {
        (Some(source), Some(target)) if source.nullable &&
          !target.nullable &&
          target.default_value is Some(default_value) =>
          "COALESCE(\{source_name}, \{default_value})"
        _ => source_name
      }
    })
    .join(", ")
  let statements : Array[String] = [
    "PRAGMA foreign_keys=OFF;",
    "BEGIN IMMEDIATE;",
    create_table_sql(after, override_name=Some(temporary)),
  ]
  if !mappings.is_empty() {
    statements.push(
      "INSERT INTO \{quote_identifier(temporary)} (\{target_columns}) SELECT \{source_expressions} FROM \{quote_identifier(before.name)};",
    )
  }
  statements.push("DROP TABLE \{quote_identifier(before.name)};")
  statements.push(
    "ALTER TABLE \{quote_identifier(temporary)} RENAME TO \{quote_identifier(after.name)};",
  )
  for index in after.indexes {
    statements.push(create_index_sql(after.name, index))
  }
  statements.push("PRAGMA foreign_key_check;")
  statements.push("COMMIT;")
  statements.push("PRAGMA foreign_keys=ON;")
  statements
}

///|
fn render_change(change : Change, dialect : Dialect) -> Array[String] {
  match change {
    AddTable(table) => {
      let statements = [create_table_sql(table)]
      for index in table.indexes {
        statements.push(create_index_sql(table.name, index))
      }
      statements
    }
    DropTable(table) => ["DROP TABLE \{quote_identifier(table.name)};"]
    RenameTable(before, after) =>
      [
        "ALTER TABLE \{quote_identifier(before)} RENAME TO \{quote_identifier(after)};",
      ]
    AddColumn(table, column) =>
      [
        "ALTER TABLE \{quote_identifier(table)} ADD COLUMN \{column_definition(column)};",
      ]
    DropColumn(table, column) =>
      [
        "ALTER TABLE \{quote_identifier(table)} DROP COLUMN \{quote_identifier(column.name)};",
      ]
    RenameColumn(table, before, after) =>
      [
        "ALTER TABLE \{quote_identifier(table)} RENAME COLUMN \{quote_identifier(before)} TO \{quote_identifier(after)};",
      ]
    AlterColumn(table, before, after) =>
      match dialect {
        PostgreSQL => postgres_alter_column(table, before, after)
        SQLite =>
          [
            "-- internal error: SQLite alterations must be planned as a table rebuild",
          ]
      }
    AddIndex(table, index) => [create_index_sql(table, index)]
    DropIndex(_, index) => ["DROP INDEX \{quote_identifier(index.name)};"]
    AddForeignKey(table, foreign_key) =>
      [add_foreign_key_sql(table, foreign_key)]
    DropForeignKey(table, foreign_key) =>
      match dialect {
        PostgreSQL =>
          [
            "ALTER TABLE \{quote_identifier(table)} DROP CONSTRAINT \{quote_identifier(foreign_key.name)};",
          ]
        SQLite =>
          [
            "-- internal error: SQLite foreign-key changes require a table rebuild",
          ]
      }
    RebuildTable(before, after, mappings) =>
      sqlite_rebuild_sql(before, after, mappings)
  }
}

///|
/// Render a plan into SQL. Destructive plans are blocked unless the caller
/// explicitly opts in, making the safe path the default for both library and CLI.
pub fn render_plan(
  plan : Plan,
  allow_destructive? : Bool = false,
) -> Result[RenderedPlan, Array[RenderIssue]] {
  let issues : Array[RenderIssue] = []
  if !allow_destructive {
    for step in plan.steps {
      if step.risk == Destructive {
        issues.push({
          step_id: step.id,
          message: "destructive step blocked: \{step.reason}",
        })
      }
    }
  }
  for step in plan.steps {
    match step.change {
      AlterColumn(_, before, after) if before.primary_key != after.primary_key ||
        before.unique != after.unique =>
        issues.push({
          step_id: step.id,
          message: "cannot render a key constraint change without an explicit constraint name",
        })
      _ => ()
    }
  }
  guard issues.is_empty() else { return Err(issues) }
  let sql : Array[String] = []
  for step in plan.steps {
    sql.push("-- \{step.id} [\{step.risk.label()}] \{step.reason}")
    sql.push_iter(render_change(step.change, plan.dialect).iter())
  }
  Ok({ plan, sql, })
}
