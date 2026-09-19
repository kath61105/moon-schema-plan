///|
/// The identifier-looking tokens in a SQL fragment, with string literals
/// skipped and quoted identifiers unwrapped.
///
/// This is not a SQL parser and does not try to be one: it cannot tell a column
/// from a function or a keyword. It exists so that one narrow question can be
/// answered — does this expression still name something the schema just removed
/// — which needs only that the tokens be recognised, not understood.
fn identifier_tokens(expression : String) -> Array[String] {
  let tokens : Array[String] = []
  let characters = expression.to_array()
  let current = StringBuilder()
  let mut index = 0
  fn flush() {
    if current.to_string() != "" {
      tokens.push(current.to_string())
      current.reset()
    }
  }

  while index < characters.length() {
    let character = characters[index]
    if character == '\'' {
      // A string literal names nothing; skip to its end, honouring '' escapes.
      flush()
      index = index + 1
      while index < characters.length() {
        if characters[index] == '\'' {
          if index + 1 < characters.length() && characters[index + 1] == '\'' {
            index = index + 2
          } else {
            index = index + 1
            break
          }
        } else {
          index = index + 1
        }
      }
    } else if character == '"' {
      // A quoted identifier is a reference like any other.
      flush()
      index = index + 1
      let quoted = StringBuilder()
      while index < characters.length() {
        if characters[index] == '"' {
          if index + 1 < characters.length() && characters[index + 1] == '"' {
            quoted.write_char('"')
            index = index + 2
          } else {
            index = index + 1
            break
          }
        } else {
          quoted.write_char(characters[index])
          index = index + 1
        }
      }
      if quoted.to_string() != "" {
        tokens.push(quoted.to_string())
      }
    } else if character.is_ascii_alphabetic() ||
      character.is_ascii_digit() ||
      character == '_' {
      current.write_char(character)
      index = index + 1
    } else {
      flush()
      index = index + 1
    }
  }
  flush()
  tokens
}

///|
/// Report a check constraint that still names a column the change removes.
///
/// A table-level `CHECK` may only reference columns of its own table, so a name
/// that was a column here before and is not one now is a reference the
/// migration would break. `CREATE TABLE` or `ADD CONSTRAINT` would then fail,
/// which is worth saying while planning rather than discovering mid-migration.
///
/// Matching is exact. A name spelled in a different case is missed rather than
/// guessed at, because a false positive here blocks a migration that would have
/// worked.
fn validate_check_references(
  before : Schema,
  after : Schema,
  hints : RenameHints,
) -> Array[ValidationIssue] {
  let issues : Array[ValidationIssue] = []
  for target_table in after.tables {
    if target_table.checks.is_empty() {
      continue
    }
    let source_name = renamed_table_source(hints, target_table.name).unwrap_or(
      target_table.name,
    )
    match find_table(before.tables, source_name) {
      None => ()
      Some(source_table) => {
        // A source column name is no longer valid in the target table if no
        // column of that name survives there, which covers a drop and a rename
        // alike: after a rename the old name is gone just the same.
        let removed = source_table.columns
          .map(column => column.name)
          .filter(name => find_column(target_table.columns, name) is None)
        for check in target_table.checks {
          for token in identifier_tokens(check.expression) {
            if has_name(removed, token) {
              issues.push({
                path: "tables.\{target_table.name}.checks.\{check.name}.expression",
                message: "references a column this change removes: \{token}",
              })
            }
          }
        }
      }
    }
  }
  issues
}

///|
/// The length of a string in UTF-8 bytes, which is the unit PostgreSQL counts
/// identifiers in. MoonBit strings are UTF-16, so the width is derived from
/// each code point rather than from the string's own length.
fn utf8_length(text : String) -> Int {
  let mut total = 0
  for character in text {
    let code = character.to_int()
    total = total +
      (if code < 0x80 {
        1
      } else if code < 0x800 {
        2
      } else if code < 0x10000 {
        3
      } else {
        4
      })
  }
  total
}

///|
/// PostgreSQL truncates an identifier longer than 63 bytes instead of refusing
/// it. Two names that differ only past that point therefore become one object,
/// silently, which is exactly the kind of surprise this planner exists to keep
/// out of a migration.
fn validate_identifier_lengths(schema : Schema) -> Array[ValidationIssue] {
  let issues : Array[ValidationIssue] = []
  fn check_name(path : String, kind : String, name : String) {
    let length = utf8_length(name)
    if length > 63 {
      issues.push({
        path,
        message: "PostgreSQL truncates an identifier over 63 bytes; this \{kind} is \{length} bytes",
      })
    }
  }

  for table in schema.tables {
    let base = "tables.\{table.name}"
    check_name("\{base}.name", "table name", table.name)
    for column in table.columns {
      check_name("\{base}.columns.\{column.name}", "column name", column.name)
    }
    for index in table.indexes {
      check_name("\{base}.indexes.\{index.name}", "index name", index.name)
    }
    for foreign_key in table.foreign_keys {
      check_name(
        "\{base}.foreign_keys.\{foreign_key.name}",
        "constraint name",
        foreign_key.name,
      )
    }
    for check in table.checks {
      check_name("\{base}.checks.\{check.name}", "constraint name", check.name)
    }
  }
  issues
}
