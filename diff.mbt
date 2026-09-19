///|
fn find_table(tables : Array[Table], name : String) -> Table? {
  tables.iter().find_first(table => table.name == name)
}

///|
fn find_column(columns : Array[Column], name : String) -> Column? {
  columns.iter().find_first(column => column.name == name)
}

///|
fn find_index(indexes : Array[Index], name : String) -> Index? {
  indexes.iter().find_first(index => index.name == name)
}

///|
fn find_foreign_key(
  foreign_keys : Array[ForeignKey],
  name : String,
) -> ForeignKey? {
  foreign_keys.iter().find_first(foreign_key => foreign_key.name == name)
}

///|
fn find_check(
  checks : Array[CheckConstraint],
  name : String,
) -> CheckConstraint? {
  checks.iter().find_first(check => check.name == name)
}

///|
fn find_trigger(triggers : Array[Trigger], name : String) -> Trigger? {
  triggers.iter().find_first(trigger => trigger.name == name)
}

///|
fn find_view(views : Array[View], name : String) -> View? {
  views.iter().find_first(view => view.name == name)
}

///|
fn renamed_table_target(hints : RenameHints, source : String) -> String? {
  for pair in hints.tables {
    if pair.0 == source {
      return Some(pair.1)
    }
  }
  None
}

///|
fn renamed_table_source(hints : RenameHints, target : String) -> String? {
  for pair in hints.tables {
    if pair.1 == target {
      return Some(pair.0)
    }
  }
  None
}

///|
fn renamed_column_target(
  hints : RenameHints,
  table : String,
  source : String,
) -> String? {
  for hint in hints.columns {
    if hint.0 == table && hint.1 == source {
      return Some(hint.2)
    }
  }
  None
}

///|
fn renamed_column_source(
  hints : RenameHints,
  table : String,
  target : String,
) -> String? {
  for hint in hints.columns {
    if hint.0 == table && hint.2 == target {
      return Some(hint.1)
    }
  }
  None
}

///|
fn change_sort_key(change : Change) -> String {
  match change {
    DropView(view) => "05:\{view.name}"
    RenameTable(from, to) => "00:\{from}:\{to}"
    AddTable(table) => "10:\{table.name}"
    DropForeignKey(table, foreign_key) => "20:\{table}:\{foreign_key.name}"
    DropIndex(table, index) => "21:\{table}:\{index.name}"
    RenameColumn(table, from, to) => "30:\{table}:\{from}:\{to}"
    AddColumn(table, column) => "40:\{table}:\{column.name}"
    AlterColumn(table, _, after) => "41:\{table}:\{after.name}"
    DropColumn(table, column) => "42:\{table}:\{column.name}"
    AddIndex(table, index) => "50:\{table}:\{index.name}"
    AddForeignKey(table, foreign_key) => "51:\{table}:\{foreign_key.name}"
    DropCheck(table, check) => "22:\{table}:\{check.name}"
    DropTrigger(table, trigger) => "23:\{table}:\{trigger.name}"
    AddTrigger(table, trigger) => "53:\{table}:\{trigger.name}"
    AddView(view) => "60:\{view.name}"
    AddCheck(table, check) => "52:\{table}:\{check.name}"
    RebuildTable(_, after, _) => "45:\{after.name}"
    DropTable(table) => "90:\{table.name}"
  }
}

///|
fn change_phase(change : Change) -> Int {
  match change {
    RenameTable(_, _) => 0
    AddTable(_) => 10
    DropForeignKey(_, _) => 20
    DropIndex(_, _) => 21
    RenameColumn(_, _, _) => 30
    AddColumn(_, _) => 40
    AlterColumn(_, _, _) => 41
    DropColumn(_, _) => 42
    RebuildTable(_, _, _) => 45
    AddIndex(_, _) => 50
    AddForeignKey(_, _) => 51
    DropCheck(_, _) => 22
    DropView(_) => 5
    DropTrigger(_, _) => 23
    AddTrigger(_, _) => 53
    AddView(_) => 60
    AddCheck(_, _) => 52
    DropTable(_) => 90
  }
}

///|
fn dependency_depth(
  table : Table,
  schema : Schema,
  visiting : Array[String],
) -> Int {
  if visiting.any(name => name == table.name) {
    return 0
  }
  let next_visiting = visiting.map(name => name)
  next_visiting.push(table.name)
  let mut depth = 0
  for foreign_key in table.foreign_keys {
    match find_table(schema.tables, foreign_key.referenced_table) {
      Some(dependency) => {
        let candidate = dependency_depth(dependency, schema, next_visiting) + 1
        if candidate > depth {
          depth = candidate
        }
      }
      // Unreachable for a validated schema: `validate_schema` rejects a
      // foreign key whose referenced table is missing, and `build_plan` runs
      // validation first. Treating it as depth zero keeps the sort total if a
      // future caller ever reaches this function another way.
      None => ()
    }
  }
  depth
}

///|
fn compare_changes(
  left : Change,
  right : Change,
  before : Schema,
  after : Schema,
) -> Int {
  let left_phase = change_phase(left)
  let right_phase = change_phase(right)
  if left_phase != right_phase {
    return left_phase - right_phase
  }
  match (left, right) {
    (AddTable(left_table), AddTable(right_table)) => {
      let by_depth = dependency_depth(left_table, after, []) -
        dependency_depth(right_table, after, [])
      if by_depth != 0 {
        return by_depth
      }
    }
    (DropTable(left_table), DropTable(right_table)) => {
      let by_depth = dependency_depth(right_table, before, []) -
        dependency_depth(left_table, before, [])
      if by_depth != 0 {
        return by_depth
      }
    }
    _ => ()
  }
  change_sort_key(left).lexical_compare(change_sort_key(right))
}

///|
fn risk_for(change : Change) -> (Risk, String) {
  match change {
    AddTable(_) => (Safe, "creates a new table without changing existing data")
    DropTable(_) => (Destructive, "drops a table and all data stored in it")
    RenameTable(_, _) =>
      (
        Review,
        "explicit rename hint supplied; dependent raw SQL may still need updates",
      )
    AddColumn(_, column) =>
      if column.nullable || column.default_value is Some(_) {
        (Safe, "new column accepts existing rows")
      } else {
        (Review, "non-null column has no default and may reject existing rows")
      }
    DropColumn(_, _) => (Destructive, "drops all values stored in the column")
    RenameColumn(_, _, _) =>
      (
        Review,
        "explicit rename hint supplied; dependent raw SQL may still need updates",
      )
    AlterColumn(_, before, after) =>
      if before.data_type != after.data_type {
        (Destructive, "column type conversion can fail or lose information")
      } else if before.primary_key != after.primary_key ||
        before.unique != after.unique {
        (Destructive, "key or uniqueness semantics change")
      } else if before.nullable && !after.nullable {
        (Review, "existing null values can make the new constraint fail")
      } else {
        (Review, "column constraint or default changes require database review")
      }
    AddIndex(_, _) =>
      (Review, "index creation may lock or scan a populated table")
    DropIndex(_, _) =>
      (Review, "dropping an index can degrade query performance")
    AddForeignKey(_, _) =>
      (Review, "existing rows must satisfy the new referential constraint")
    DropForeignKey(_, _) => (Review, "removes referential protection")
    AddCheck(_, _) =>
      (Review, "existing rows must already satisfy the new check constraint")
    DropCheck(_, _) => (Review, "removes a data-integrity constraint")
    AddView(_) => (Safe, "creates a view without changing stored data")
    DropView(_) => (Review, "removes a view that queries may depend on")
    AddTrigger(_, _) =>
      (Review, "a trigger changes what every later write to the table does")
    DropTrigger(_, _) =>
      (Review, "removes behaviour that later writes relied on")
    RebuildTable(before, after, mappings) =>
      if before.columns.any(column => {
          !mappings.any(mapping => mapping.0 == column.name)
        }) ||
        mappings.any(mapping => {
          let source = find_column(before.columns, mapping.0)
          let target = find_column(after.columns, mapping.1)
          match (source, target) {
            (Some(source), Some(target)) => source.data_type != target.data_type
            // Unreachable: every mapping is built from a column that exists in
            // both tables. A missing side cannot be judged, so it is not
            // treated as evidence of data loss.
            _ => false
          }
        }) {
        (
          Destructive,
          "SQLite table rebuild drops a column or converts stored values; declared triggers are recreated, but any the schema does not declare are lost",
        )
      } else {
        (
          Review,
          "SQLite requires an auditable table rebuild for this schema change; declared triggers are recreated, but any the schema does not declare are lost",
        )
      }
  }
}

///|
fn validate_hints(
  before : Schema,
  after : Schema,
  hints : RenameHints,
) -> Array[ValidationIssue] {
  let issues : Array[ValidationIssue] = []
  for i = 0; i < hints.tables.length(); i = i + 1 {
    for j = i + 1; j < hints.tables.length(); j = j + 1 {
      if hints.tables[i].0 == hints.tables[j].0 ||
        hints.tables[i].1 == hints.tables[j].1 {
        issues.push({
          path: "hints.tables",
          message: "table rename hints must be one-to-one",
        })
      }
    }
  }
  for i = 0; i < hints.columns.length(); i = i + 1 {
    for j = i + 1; j < hints.columns.length(); j = j + 1 {
      if hints.columns[i].0 == hints.columns[j].0 &&
        (
          hints.columns[i].1 == hints.columns[j].1 ||
          hints.columns[i].2 == hints.columns[j].2
        ) {
        issues.push({
          path: "hints.columns.\{hints.columns[i].0}",
          message: "column rename hints must be one-to-one within a table",
        })
      }
    }
  }
  for pair in hints.tables {
    let (source, target) = pair
    if find_table(before.tables, source) is None {
      issues.push({
        path: "hints.tables.\{source}",
        message: "unknown source table",
      })
    }
    if find_table(after.tables, target) is None {
      issues.push({
        path: "hints.tables.\{source}",
        message: "unknown target table: \{target}",
      })
    }
    if source != target && find_table(before.tables, target) is Some(_) {
      issues.push({
        path: "hints.tables.\{source}",
        message: "rename target already exists in the source schema: \{target}",
      })
    }
  }
  for hint in hints.columns {
    let (table, source, target) = hint
    let source_table_name = renamed_table_source(hints, table).unwrap_or(table)
    match find_table(before.tables, source_table_name) {
      None =>
        issues.push({
          path: "hints.columns.\{table}",
          message: "unknown source table",
        })
      Some(source_table) => {
        if find_column(source_table.columns, source) is None {
          issues.push({
            path: "hints.columns.\{table}.\{source}",
            message: "unknown source column",
          })
        }
        if source != target &&
          find_column(source_table.columns, target) is Some(_) {
          issues.push({
            path: "hints.columns.\{table}.\{source}",
            message: "rename target already exists in the source table: \{target}",
          })
        }
      }
    }
    match find_table(after.tables, table) {
      None =>
        issues.push({
          path: "hints.columns.\{table}",
          message: "unknown target table",
        })
      Some(target_table) =>
        if find_column(target_table.columns, target) is None {
          issues.push({
            path: "hints.columns.\{table}.\{source}",
            message: "unknown target column: \{target}",
          })
        }
    }
  }
  issues
}

///|
fn validate_dialect_transition(
  before : Schema,
  after : Schema,
  hints : RenameHints,
  dialect : Dialect,
) -> Array[ValidationIssue] {
  let issues : Array[ValidationIssue] = []
  if dialect == SQLite {
    // SQLite keeps triggers in the same schema-wide namespace as tables and
    // indexes, so two tables cannot each have a trigger of the same name.
    // PostgreSQL scopes a trigger to its table and is not restricted here.
    let seen : Array[String] = []
    for table in after.tables {
      for trigger in table.triggers {
        if has_name(seen, trigger.name) {
          issues.push({
            path: "tables.\{table.name}.triggers.\{trigger.name}",
            message: "trigger name is already used elsewhere; SQLite trigger names are database-wide",
          })
        }
        seen.push(trigger.name)
      }
    }
    for target_table in after.tables {
      let source_name = renamed_table_source(hints, target_table.name).unwrap_or(
        target_table.name,
      )
      match find_table(before.tables, source_name) {
        None => ()
        Some(source_table) =>
          for column in target_table.columns {
            let source_column = renamed_column_source(
              hints,
              target_table.name,
              column.name,
            ).unwrap_or(column.name)
            match find_column(source_table.columns, source_column) {
              None =>
                if !column.nullable && column.default_value is None {
                  issues.push({
                    path: "tables.\{target_table.name}.columns.\{column.name}",
                    message: "SQLite cannot populate a new non-null column without a default",
                  })
                }
              Some(source) =>
                if source.nullable &&
                  !column.nullable &&
                  column.default_value is None {
                  issues.push({
                    path: "tables.\{target_table.name}.columns.\{column.name}",
                    message: "SQLite cannot make a nullable column required without a backfill default",
                  })
                }
            }
          }
      }
    }
  }
  if dialect == PostgreSQL {
    issues.push_iter(validate_identifier_lengths(after).iter())
    // `ALTER TABLE ... ADD COLUMN x ... PRIMARY KEY` only works while the table
    // has no primary key; otherwise PostgreSQL refuses the statement outright.
    // Reshaping an existing key needs the constraint's name, which this IR does
    // not carry, so the transition is rejected here rather than rendered into
    // SQL that fails. SQLite reaches this through a table rebuild instead.
    for target_table in after.tables {
      let source_name = renamed_table_source(hints, target_table.name).unwrap_or(
        target_table.name,
      )
      match find_table(before.tables, source_name) {
        None => ()
        Some(source_table) => {
          let had_key = source_table.columns.any(column => column.primary_key)
          if had_key {
            for column in target_table.columns {
              let source_column = renamed_column_source(
                hints,
                target_table.name,
                column.name,
              ).unwrap_or(column.name)
              if column.primary_key &&
                find_column(source_table.columns, source_column) is None {
                issues.push({
                  path: "tables.\{target_table.name}.columns.\{column.name}",
                  message: "PostgreSQL cannot add a primary-key column to a table that already has a primary key; the constraint name is needed and the schema does not carry it",
                })
              }
            }
          }
        }
      }
    }
  }
  issues
}

///|
fn diff_existing_table(
  before : Table,
  after : Table,
  hints : RenameHints,
  dialect : Dialect,
  changes : Array[Change],
) -> Unit {
  let table_name = after.name
  if dialect == SQLite {
    let mappings : Array[(String, String)] = []
    let mut rebuild = before.foreign_keys != after.foreign_keys ||
      before.checks != after.checks
    for column in before.columns {
      let target_name = renamed_column_target(hints, table_name, column.name).unwrap_or(
        column.name,
      )
      match find_column(after.columns, target_name) {
        None => rebuild = true
        Some(target) => {
          mappings.push((column.name, target_name))
          let comparable = Column::{ ..column, name: target_name, }
          if comparable != target {
            rebuild = true
          }
        }
      }
    }
    for column in after.columns {
      let source_name = renamed_column_source(hints, table_name, column.name).unwrap_or(
        column.name,
      )
      if find_column(before.columns, source_name) is None &&
        (column.primary_key || column.unique) {
        rebuild = true
      }
    }
    if rebuild {
      changes.push(
        RebuildTable(Table::{ ..before, name: table_name, }, after, mappings),
      )
      return
    }
  }
  for foreign_key in before.foreign_keys {
    match find_foreign_key(after.foreign_keys, foreign_key.name) {
      None => changes.push(DropForeignKey(table_name, foreign_key))
      Some(target) if target != foreign_key => {
        changes.push(DropForeignKey(table_name, foreign_key))
        changes.push(AddForeignKey(table_name, target))
      }
      _ => ()
    }
  }
  for check in before.checks {
    match find_check(after.checks, check.name) {
      None => changes.push(DropCheck(table_name, check))
      Some(target) if target != check => {
        changes.push(DropCheck(table_name, check))
        changes.push(AddCheck(table_name, target))
      }
      _ => ()
    }
  }
  for check in after.checks {
    if find_check(before.checks, check.name) is None {
      changes.push(AddCheck(table_name, check))
    }
  }
  for trigger in before.triggers {
    match find_trigger(after.triggers, trigger.name) {
      None => changes.push(DropTrigger(table_name, trigger))
      Some(target) if target != trigger => {
        changes.push(DropTrigger(table_name, trigger))
        changes.push(AddTrigger(table_name, target))
      }
      _ => ()
    }
  }
  for trigger in after.triggers {
    if find_trigger(before.triggers, trigger.name) is None {
      changes.push(AddTrigger(table_name, trigger))
    }
  }
  for index in before.indexes {
    match find_index(after.indexes, index.name) {
      None => changes.push(DropIndex(table_name, index))
      Some(target) if target != index => {
        changes.push(DropIndex(table_name, index))
        changes.push(AddIndex(table_name, target))
      }
      _ => ()
    }
  }
  for column in before.columns {
    let target_name = renamed_column_target(hints, table_name, column.name).unwrap_or(
      column.name,
    )
    match find_column(after.columns, target_name) {
      None => changes.push(DropColumn(table_name, column))
      Some(target) => {
        if target_name != column.name {
          changes.push(RenameColumn(table_name, column.name, target_name))
        }
        let comparable = Column::{ ..column, name: target_name, }
        if comparable != target {
          changes.push(AlterColumn(table_name, comparable, target))
        }
      }
    }
  }
  for column in after.columns {
    let source_name = renamed_column_source(hints, table_name, column.name).unwrap_or(
      column.name,
    )
    if find_column(before.columns, source_name) is None {
      changes.push(AddColumn(table_name, column))
    }
  }
  for index in after.indexes {
    if find_index(before.indexes, index.name) is None {
      changes.push(AddIndex(table_name, index))
    }
  }
  for foreign_key in after.foreign_keys {
    if find_foreign_key(before.foreign_keys, foreign_key.name) is None {
      changes.push(AddForeignKey(table_name, foreign_key))
    }
  }
}

///|
fn collect_changes(
  before : Schema,
  after : Schema,
  hints : RenameHints,
  dialect : Dialect,
) -> Array[Change] {
  let changes : Array[Change] = []
  for pair in hints.tables {
    let (source, target) = pair
    if source != target {
      changes.push(RenameTable(source, target))
    }
  }
  for source_table in before.tables {
    let target_name = renamed_table_target(hints, source_table.name).unwrap_or(
      source_table.name,
    )
    match find_table(after.tables, target_name) {
      None => changes.push(DropTable(source_table))
      Some(target_table) =>
        diff_existing_table(source_table, target_table, hints, dialect, changes)
    }
  }
  for target_table in after.tables {
    let source_name = renamed_table_source(hints, target_table.name).unwrap_or(
      target_table.name,
    )
    if find_table(before.tables, source_name) is None {
      if dialect == PostgreSQL && !target_table.foreign_keys.is_empty() {
        changes.push(AddTable(Table::{ ..target_table, foreign_keys: [], }))
        for foreign_key in target_table.foreign_keys {
          changes.push(AddForeignKey(target_table.name, foreign_key))
        }
      } else {
        changes.push(AddTable(target_table))
      }
    }
  }
  for view in before.views {
    match find_view(after.views, view.name) {
      None => changes.push(DropView(view))
      Some(target) if target != view => {
        changes.push(DropView(view))
        changes.push(AddView(target))
      }
      _ => ()
    }
  }
  for view in after.views {
    if find_view(before.views, view.name) is None {
      changes.push(AddView(view))
    }
  }
  // A SQLite rebuild drops and recreates the table, and `ALTER TABLE ... RENAME
  // TO` refuses to run while any view in the schema references a table that is
  // momentarily missing. Every declared view is therefore dropped before the
  // rebuild and recreated after it, whether or not its definition changed. The
  // churn is visible in the plan rather than hidden inside one step, which is
  // the point: an operator can see that the views go away and come back.
  if dialect == SQLite &&
    changes.iter().any(change => change is RebuildTable(_)) {
    for view in before.views {
      if !changes
        .iter()
        .any(change => change is DropView({ name, .. }) && name == view.name) {
        changes.push(DropView(view))
      }
    }
    for view in after.views {
      if !changes
        .iter()
        .any(change => change is AddView({ name, .. }) && name == view.name) {
        changes.push(AddView(view))
      }
    }
    // Triggers need the same bracket, and for the same reason. A trigger that
    // reads another table blocks a rebuild of *that* table, not only of its
    // own: SQLite revalidates every trigger while altering the schema, and one
    // pointing at a table that is momentarily missing fails the statement. The
    // trigger on the rebuilt table would also be lost with `DROP TABLE`, so
    // both cases are covered by dropping every declared trigger first and
    // recreating it afterwards.
    for table in before.tables {
      for trigger in table.triggers {
        if !changes
          .iter()
          .any(change => {
            change is DropTrigger(_, { name, .. }) && name == trigger.name
          }) {
          changes.push(DropTrigger(table.name, trigger))
        }
      }
    }
    for table in after.tables {
      for trigger in table.triggers {
        if !changes
          .iter()
          .any(change => {
            change is AddTrigger(_, { name, .. }) && name == trigger.name
          }) {
          changes.push(AddTrigger(table.name, trigger))
        }
      }
    }
  }
  changes.sort_by((left, right) => compare_changes(left, right, before, after))
  changes
}

///|
/// Build a deterministic, auditable migration plan. Invalid schemas and stale
/// rename hints are returned together instead of producing partial SQL.
pub fn build_plan(
  before : Schema,
  after : Schema,
  dialect : Dialect,
  hints? : RenameHints = RenameHints::empty(),
) -> Result[Plan, Array[ValidationIssue]] {
  let issues = validate_schema(before)
  issues.push_iter(validate_schema(after).iter())
  issues.push_iter(validate_hints(before, after, hints).iter())
  issues.push_iter(
    validate_dialect_transition(before, after, hints, dialect).iter(),
  )
  issues.push_iter(validate_check_references(before, after, hints).iter())
  guard issues.is_empty() else { return Err(sort_issues(issues)) }
  let changes = collect_changes(before, after, hints, dialect)
  let steps = changes.mapi((index, change) => {
    let (risk, reason) = risk_for(change)
    { id: "step-\{index + 1}", risk, reason, change, }
  })
  Ok({
    from_version: before.version,
    to_version: after.version,
    dialect,
    steps,
  })
}

///|
pub fn Plan::has_destructive_changes(self : Plan) -> Bool {
  self.steps.any(step => step.risk == Destructive)
}
