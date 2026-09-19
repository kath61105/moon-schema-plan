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
  sort_issues(issues)
}

///|
/// Issues are collected in whatever order the schema happens to list its
/// tables, which would make a validation report change when a table moves
/// within a file. Sorting them makes the report canonical, the same way the
/// planner canonicalises its steps.
fn sort_issues(issues : Array[ValidationIssue]) -> Array[ValidationIssue] {
  issues.sort_by((left, right) => {
    let by_path = left.path.lexical_compare(right.path)
    if by_path != 0 {
      by_path
    } else {
      left.message.lexical_compare(right.message)
    }
  })
  issues
}

///|
fn same_column_set(left : Array[String], right : Array[String]) -> Bool {
  left.length() == right.length() &&
  left.iter().all(name => has_name(right, name)) &&
  right.iter().all(name => has_name(left, name))
}

///|
/// Whether a table guarantees at most one row per value of `columns`. Both
/// PostgreSQL and SQLite require a foreign key's referenced columns to be
/// backed by such a guarantee; without one, PostgreSQL refuses the constraint
/// and SQLite reports a foreign key mismatch when rows are written.
fn uniquely_constrained(table : Table, columns : Array[String]) -> Bool {
  let primary_key = table.columns
    .filter(column => column.primary_key)
    .map(column => column.name)
  if !primary_key.is_empty() && same_column_set(primary_key, columns) {
    return true
  }
  if columns.length() == 1 &&
    table.columns.any(column => column.name == columns[0] && column.unique) {
    return true
  }
  table.indexes.any(index => {
    index.unique && same_column_set(index.columns, columns)
  })
}

///|
fn has_name(names : Array[String], wanted : String) -> Bool {
  names.any(name => name == wanted)
}

///|
/// Reject a fragment that could end the statement it is embedded in.
///
/// A default or check expression legitimately contains a string literal, and
/// `'a--b'` or `'x;y'` are ordinary values, so the scan tracks quoting and
/// judges only what falls outside a literal. An unterminated literal is
/// rejected as well, because it would swallow whatever the renderer appends
/// after it.
fn unsafe_sql_fragment(value : String) -> Bool {
  if value.is_empty() {
    return true
  }
  let characters = value.to_array()
  let mut index = 0
  let mut inside_literal = false
  while index < characters.length() {
    let current = characters[index]
    let next = if index + 1 < characters.length() {
      Some(characters[index + 1])
    } else {
      None
    }
    if inside_literal {
      if current == '\'' {
        // Two quotes inside a literal are an escaped quote, not its end.
        if next is Some('\'') {
          index = index + 1
        } else {
          inside_literal = false
        }
      }
    } else if current == '\'' {
      inside_literal = true
    } else if current == ';' {
      return true
    } else if current == '-' && next is Some('-') {
      return true
    } else if current == '/' && next is Some('*') {
      return true
    }
    index = index + 1
  }
  inside_literal
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
    if table.name.has_prefix("__msp_") {
      issues.push({
        path: "\{base}.name",
        message: "table name uses the reserved SQLite rebuild prefix: __msp_",
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
          if foreign_key.referenced_columns
            .iter()
            .all(column => has_name(referenced_names, column)) &&
            !uniquely_constrained(
              referenced_table,
              foreign_key.referenced_columns,
            ) {
            issues.push({
              path: "\{base}.foreign_keys.\{foreign_key.name}",
              message: "referenced columns must be a primary key or covered by a unique index in \{foreign_key.referenced_table}",
            })
          }
        }
      }
    }
  }
  sort_issues(issues)
}
