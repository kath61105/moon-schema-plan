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
pub(all) struct Table {
  name : String
  columns : Array[Column]
  indexes : Array[Index]
  foreign_keys : Array[ForeignKey]
} derive(Eq, Debug, ToJson, FromJson)

///|
pub(all) struct Schema {
  version : String
  tables : Array[Table]
} derive(Eq, Debug, ToJson, FromJson)

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
