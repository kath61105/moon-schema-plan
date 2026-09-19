///|
fn duplicate_names(
  names : Array[String],
  path : String,
) -> Array[ValidationIssue] {
  let issues : Array[ValidationIssue] = []
  for i = 0; i < names.length(); i = i + 1 {
    if names[i] == "" {
      issues.push({ path: "\{path}[\{i}]", message: "name must not be empty", })
    }
    for j = i + 1; j < names.length(); j = j + 1 {
      if names[i] == names[j] {
        issues.push({ path, message: "duplicate name: \{names[i]}", })
        break
      }
    }
  }
  issues
}

///|
fn has_name(names : Array[String], wanted : String) -> Bool {
  names.any(name => name == wanted)
}

///|
fn unsafe_sql_fragment(value : String) -> Bool {
  value == "" ||
  value.contains(";") ||
  value.contains("--") ||
  value.contains("/*")
}

///|
fn valid_reference_action(action : String) -> Bool {
  action == "NO ACTION" ||
  action == "RESTRICT" ||
  action == "CASCADE" ||
  action == "SET NULL" ||
  action == "SET DEFAULT"
}

///|
/// Index names are database-wide in SQLite and schema-wide in PostgreSQL, so
/// two tables cannot share one. The per-table duplicate check cannot see this,
/// and the renderer would emit a `CREATE INDEX` that fails on the second table.
fn duplicate_index_names(schema : Schema) -> Array[ValidationIssue] {
  let issues : Array[ValidationIssue] = []
  let seen : Array[String] = []
  for table in schema.tables {
    for index in table.indexes {
      if index.name != "" && has_name(seen, index.name) {
        issues.push({
          path: "tables.\{table.name}.indexes.\{index.name}",
          message: "index name is already used by another table; index names are database-wide",
        })
      }
      seen.push(index.name)
    }
  }
  issues
}

///|
/// Validate structural invariants before planning. The function returns every
/// issue it can find so callers can fix a schema in one pass.
pub fn validate_schema(schema : Schema) -> Array[ValidationIssue] {
  let issues : Array[ValidationIssue] = []
  if schema.version == "" {
    issues.push({ path: "version", message: "version must not be empty", })
  }
  let table_names = schema.tables.map(table => table.name)
  issues.push_iter(duplicate_names(table_names, "tables").iter())
  issues.push_iter(duplicate_index_names(schema).iter())
  for table in schema.tables {
    let base = "tables.\{table.name}"
    if table.name.has_prefix("__msp_new_") {
      issues.push({
        path: "\{base}.name",
        message: "table name uses the reserved SQLite rebuild prefix: __msp_new_",
      })
    }
    if table.columns.is_empty() {
      issues.push({
        path: "\{base}.columns",
        message: "table must contain at least one column",
      })
    }
    let column_names = table.columns.map(column => column.name)
    issues.push_iter(duplicate_names(column_names, "\{base}.columns").iter())
    issues.push_iter(
      duplicate_names(table.indexes.map(index => index.name), "\{base}.indexes").iter(),
    )
    issues.push_iter(
      duplicate_names(
        table.foreign_keys.map(foreign_key => foreign_key.name),
        "\{base}.foreign_keys",
      ).iter(),
    )
    issues.push_iter(
      duplicate_names(table.checks.map(check => check.name), "\{base}.checks").iter(),
    )
    for check in table.checks {
      if unsafe_sql_fragment(check.expression) {
        issues.push({
          path: "\{base}.checks.\{check.name}.expression",
          message: "check expression must be non-empty and contain no SQL statement delimiter",
        })
      }
    }
    for index in table.indexes {
      if index.columns.is_empty() {
        issues.push({
          path: "\{base}.indexes.\{index.name}",
          message: "index must contain at least one column",
        })
      }
      for column in index.columns {
        if !has_name(column_names, column) {
          issues.push({
            path: "\{base}.indexes.\{index.name}",
            message: "unknown column: \{column}",
          })
        }
      }
    }
    for column in table.columns {
      if column.primary_key && column.nullable {
        issues.push({
          path: "\{base}.columns.\{column.name}.nullable",
          message: "primary-key columns must not be nullable",
        })
      }
      if unsafe_sql_fragment(column.data_type) {
        issues.push({
          path: "\{base}.columns.\{column.name}.data_type",
          message: "data type must be non-empty and contain no SQL statement delimiter",
        })
      }
      match column.default_value {
        Some(value) if unsafe_sql_fragment(value) =>
          issues.push({
            path: "\{base}.columns.\{column.name}.default_value",
            message: "default expression contains an unsafe SQL delimiter",
          })
        _ => ()
      }
    }
    for foreign_key in table.foreign_keys {
      if foreign_key.columns.is_empty() ||
        foreign_key.columns.length() != foreign_key.referenced_columns.length() {
        issues.push({
          path: "\{base}.foreign_keys.\{foreign_key.name}",
          message: "foreign key column lists must be non-empty and equally sized",
        })
      }
      for column in foreign_key.columns {
        if !has_name(column_names, column) {
          issues.push({
            path: "\{base}.foreign_keys.\{foreign_key.name}",
            message: "unknown local column: \{column}",
          })
        }
      }
      match foreign_key.on_delete {
        Some(action) if !valid_reference_action(action) =>
          issues.push({
            path: "\{base}.foreign_keys.\{foreign_key.name}.on_delete",
            message: "unsupported referential action: \{action}",
          })
        _ => ()
      }
      match foreign_key.on_update {
        Some(action) if !valid_reference_action(action) =>
          issues.push({
            path: "\{base}.foreign_keys.\{foreign_key.name}.on_update",
            message: "unsupported referential action: \{action}",
          })
        _ => ()
      }
      let referenced = schema.tables
        .iter()
        .find_first(table => table.name == foreign_key.referenced_table)
      match referenced {
        None =>
          issues.push({
            path: "\{base}.foreign_keys.\{foreign_key.name}",
            message: "unknown referenced table: \{foreign_key.referenced_table}",
          })
        Some(referenced_table) => {
          let referenced_names = referenced_table.columns.map(column => {
            column.name
          })
          for column in foreign_key.referenced_columns {
            if !has_name(referenced_names, column) {
              issues.push({
                path: "\{base}.foreign_keys.\{foreign_key.name}",
                message: "unknown referenced column: \{column}",
              })
            }
          }
        }
      }
    }
  }
  issues
}
