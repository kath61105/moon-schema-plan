///|
/// The SQL dialect used when a migration plan is rendered.
pub(all) enum Dialect {
  SQLite
  PostgreSQL
} derive(Eq, Debug, ToJson, FromJson)

///|
/// A conservative risk classification for a migration step.
pub(all) enum Risk {
  Safe
  Review
  Destructive
} derive(Eq, Debug, ToJson, FromJson)

///|
/// A portable column description. `data_type` is intentionally retained as a
/// dialect-level string: the planner compares it deterministically without
/// pretending that PostgreSQL and SQLite type systems are interchangeable.
pub(all) struct Column {
  name : String
  data_type : String
  nullable : Bool
  default_value : String?
  primary_key : Bool
  unique : Bool
} derive(Eq, Debug, ToJson, FromJson)

///|
pub(all) struct Index {
  name : String
  columns : Array[String]
  unique : Bool
} derive(Eq, Debug, ToJson, FromJson)

///|
pub(all) struct ForeignKey {
  name : String
  columns : Array[String]
  referenced_table : String
  referenced_columns : Array[String]
  on_delete : String?
  on_update : String?
} derive(Eq, Debug, ToJson, FromJson)

///|
/// A table-level `CHECK` constraint. The expression is a dialect SQL fragment
/// held under the same rules as a column default: validated for statement
/// delimiters, emitted verbatim, never parsed.
pub(all) struct CheckConstraint {
  name : String
  expression : String
} derive(Eq, Debug, ToJson, FromJson)

///|
/// A trigger on a table.
///
/// `timing` and `event` are validated against a fixed set because they are the
/// portable part. `action` is everything after `ON <table>` and is a
/// dialect-specific fragment: SQLite inlines statements between BEGIN and END,
/// while PostgreSQL executes a function. It is the one fragment the delimiter
/// check does not apply to, because a SQLite trigger body legitimately contains
/// semicolons.
pub(all) struct Trigger {
  name : String
  timing : String
  event : String
  action : String
} derive(Eq, Debug, ToJson, FromJson)

///|
/// A view. `definition` is the body after `AS`, held opaquely like a check
/// expression.
pub(all) struct View {
  name : String
  definition : String
} derive(Eq, Debug, ToJson, FromJson)

///|
pub(all) struct Table {
  name : String
  columns : Array[Column]
  indexes : Array[Index]
  foreign_keys : Array[ForeignKey]
  checks : Array[CheckConstraint]
  triggers : Array[Trigger]
} derive(Eq, Debug, ToJson)

///|
fn[T : @json.FromJson] required_field(
  fields : Map[String, Json],
  key : String,
  path : @json.JsonPath,
) -> T raise @json.JsonDecodeError {
  match fields.get(key) {
    Some(value) => @json.from_json(value, path=path.add_key(key))
    None => raise @json.JsonDecodeError((path, "Missing field \{key}"))
  }
}

///|
/// `checks` arrived after 0.2.0. A schema file written against that release
/// omits it, and refusing to read those files on upgrade would break every
/// stored schema over a field whose absence simply means "no check
/// constraints". Decoding therefore treats it as optional; encoding always
/// writes it, so a round trip normalises the document.
pub impl @json.FromJson for Table with fn from_json(json, path) {
  guard json is Object(fields) else {
    raise @json.JsonDecodeError((path, "expected an object describing a table"))
  }
  {
    name: required_field(fields, "name", path),
    columns: required_field(fields, "columns", path),
    indexes: required_field(fields, "indexes", path),
    foreign_keys: required_field(fields, "foreign_keys", path),
    checks: match fields.get("checks") {
      Some(value) => @json.from_json(value, path=path.add_key("checks"))
      None => []
    },
    triggers: match fields.get("triggers") {
      Some(value) => @json.from_json(value, path=path.add_key("triggers"))
      None => []
    },
  }
}

///|
pub(all) struct Schema {
  version : String
  tables : Array[Table]
  views : Array[View]
} derive(Eq, Debug, ToJson)

///|
/// `views` arrived after 0.3.0 and is optional for the same reason `checks`
/// was: a stored schema written against an earlier release omits it, and its
/// absence simply means the schema declares no views.
pub impl @json.FromJson for Schema with fn from_json(json, path) {
  guard json is Object(fields) else {
    raise @json.JsonDecodeError(
      (path, "expected an object describing a schema"),
    )
  }
  {
    version: required_field(fields, "version", path),
    tables: required_field(fields, "tables", path),
    views: match fields.get("views") {
      Some(value) => @json.from_json(value, path=path.add_key("views"))
      None => []
    },
  }
}

///|
/// Explicit rename hints prevent the planner from making unsafe guesses.
pub(all) struct RenameHints {
  tables : Array[(String, String)]
  columns : Array[(String, String, String)]
} derive(Eq, Debug, ToJson, FromJson)

///|
pub fn RenameHints::empty() -> RenameHints {
  { tables: [], columns: [], }
}

///|
pub(all) enum Change {
  AddTable(Table)
  DropTable(Table)
  RenameTable(String, String)
  AddColumn(String, Column)
  DropColumn(String, Column)
  RenameColumn(String, String, String)
  AlterColumn(String, Column, Column)
  AddIndex(String, Index)
  DropIndex(String, Index)
  AddForeignKey(String, ForeignKey)
  DropForeignKey(String, ForeignKey)
  AddCheck(String, CheckConstraint)
  DropCheck(String, CheckConstraint)
  AddTrigger(String, Trigger)
  DropTrigger(String, Trigger)
  AddView(View)
  DropView(View)
  RebuildTable(Table, Table, Array[(String, String)])
} derive(Eq, Debug, ToJson, FromJson)

///|
pub(all) struct MigrationStep {
  id : String
  risk : Risk
  reason : String
  change : Change
} derive(Eq, Debug, ToJson, FromJson)

///|
pub(all) struct Plan {
  from_version : String
  to_version : String
  dialect : Dialect
  steps : Array[MigrationStep]
} derive(Eq, Debug, ToJson, FromJson)

///|
pub(all) struct ValidationIssue {
  path : String
  message : String
} derive(Eq, Debug, ToJson, FromJson)

///|
pub(all) struct RenderedPlan {
  plan : Plan
  sql : Array[String]
} derive(Eq, Debug, ToJson, FromJson)

///|
pub(all) struct RenderIssue {
  step_id : String
  message : String
} derive(Eq, Debug, ToJson, FromJson)
