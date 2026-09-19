///|
/// Severity order used when a caller compares risks or configures a policy
/// threshold. `Safe` is `0`, `Review` is `1`, `Destructive` is `2`.
pub fn Risk::severity(self : Risk) -> Int {
  match self {
    Safe => 0
    Review => 1
    Destructive => 2
  }
}

///|
/// The stable lowercase spelling used in SQL comments, reports and the CLI.
pub fn Risk::label(self : Risk) -> String {
  match self {
    Safe => "safe"
    Review => "review"
    Destructive => "destructive"
  }
}

///|
/// Parse the spelling produced by `Risk::label`. Unknown input returns `None`
/// rather than silently selecting a weaker policy.
pub fn Risk::parse(text : String) -> Risk? {
  match text {
    "safe" => Some(Safe)
    "review" => Some(Review)
    "destructive" => Some(Destructive)
    _ => None
  }
}

///|
/// The stable lowercase spelling of a dialect.
pub fn Dialect::label(self : Dialect) -> String {
  match self {
    SQLite => "sqlite"
    PostgreSQL => "postgresql"
  }
}

///|
/// Parse a dialect name. `postgres` is accepted as an alias for `postgresql`
/// because both spellings are common in tooling.
pub fn Dialect::parse(text : String) -> Dialect? {
  match text {
    "sqlite" => Some(SQLite)
    "postgres" | "postgresql" => Some(PostgreSQL)
    _ => None
  }
}

///|
/// Step counts per risk level, used for policy decisions and for the headline
/// of a review report.
pub(all) struct PlanSummary {
  total : Int
  safe : Int
  review : Int
  destructive : Int
} derive(Eq, Debug, ToJson, FromJson)

///|
pub fn Plan::summary(self : Plan) -> PlanSummary {
  let mut safe = 0
  let mut review = 0
  let mut destructive = 0
  for step in self.steps {
    match step.risk {
      Safe => safe = safe + 1
      Review => review = review + 1
      Destructive => destructive = destructive + 1
    }
  }
  { total: self.steps.length(), safe, review, destructive, }
}

///|
/// The highest risk present in the plan. An empty plan is `Safe`.
pub fn Plan::max_risk(self : Plan) -> Risk {
  let mut highest = Risk::Safe
  for step in self.steps {
    if step.risk.severity() > highest.severity() {
      highest = step.risk
    }
  }
  highest
}

///|
/// Every step whose risk exceeds `max_risk`. An empty result means the plan
/// satisfies the policy.
pub fn Plan::steps_above(self : Plan, max_risk : Risk) -> Array[MigrationStep] {
  self.steps.filter(step => step.risk.severity() > max_risk.severity())
}

///|
/// A short, stable description of a change, suitable for a report table or a
/// commit message. It never includes SQL.
pub fn Change::describe(self : Change) -> String {
  match self {
    AddTable(table) => "create table \{table.name}"
    DropTable(table) => "drop table \{table.name}"
    RenameTable(before, after) => "rename table \{before} to \{after}"
    AddColumn(table, column) => "add column \{table}.\{column.name}"
    DropColumn(table, column) => "drop column \{table}.\{column.name}"
    RenameColumn(table, before, after) =>
      "rename column \{table}.\{before} to \{table}.\{after}"
    AlterColumn(table, _, after) => "alter column \{table}.\{after.name}"
    AddIndex(table, index) => "create index \{index.name} on \{table}"
    DropIndex(table, index) => "drop index \{index.name} on \{table}"
    AddForeignKey(table, foreign_key) =>
      "add foreign key \{foreign_key.name} on \{table}"
    DropForeignKey(table, foreign_key) =>
      "drop foreign key \{foreign_key.name} on \{table}"
    AddCheck(table, check) => "add check \{check.name} on \{table}"
    DropCheck(table, check) => "drop check \{check.name} on \{table}"
    AddTrigger(table, trigger) => "add trigger \{trigger.name} on \{table}"
    DropTrigger(table, trigger) => "drop trigger \{trigger.name} on \{table}"
    AddView(view) => "create view \{view.name}"
    DropView(view) => "drop view \{view.name}"
    RebuildTable(_, after, _) => "rebuild table \{after.name}"
  }
}

///|
/// Escape the characters that would otherwise break a GitHub-flavoured
/// Markdown table cell. Identifiers come from configuration, not from a
/// database, but a review artefact still must not be corrupted by them.
fn markdown_cell(text : String) -> String {
  text.replace_all(old="\\", new="\\\\").replace_all(old="|", new="\\|")
}

///|
fn summary_rows(plan : Plan) -> Array[String] {
  let summary = plan.summary()
  [
    "| Risk | Steps |",
    "| --- | --- |",
    "| safe | \{summary.safe} |",
    "| review | \{summary.review} |",
    "| destructive | \{summary.destructive} |",
    "| **total** | **\{summary.total}** |",
  ]
}

///|
/// Render a plan as a deterministic Markdown review document. The output is
/// intended to be attached to a pull request so that a human approves the
/// migration before any SQL runs.
pub fn Plan::to_markdown(self : Plan) -> String {
  let lines : Array[String] = [
    "# Migration plan",
    "",
    "| Field | Value |",
    "| --- | --- |",
    "| From version | `\{markdown_cell(self.from_version)}` |",
    "| To version | `\{markdown_cell(self.to_version)}` |",
    "| Dialect | `\{self.dialect.label()}` |",
    "| Highest risk | `\{self.max_risk().label()}` |",
    "",
    "## Risk summary",
    "",
  ]
  lines.push_iter(summary_rows(self).iter())
  lines.push("")
  lines.push("## Steps")
  lines.push("")
  if self.steps.is_empty() {
    lines.push("No schema changes were detected.")
  } else {
    lines.push("| Step | Risk | Change | Reason |")
    lines.push("| --- | --- | --- | --- |")
    for step in self.steps {
      let id = markdown_cell(step.id)
      let risk = step.risk.label()
      let change = markdown_cell(step.change.describe())
      let reason = markdown_cell(step.reason)
      lines.push("| \{id} | \{risk} | \{change} | \{reason} |")
    }
  }
  lines.push("")
  lines.join("\n")
}

///|
/// Render a plan together with the SQL that was approved for it.
pub fn RenderedPlan::to_markdown(self : RenderedPlan) -> String {
  let lines : Array[String] = [self.plan.to_markdown(), "## SQL", "", "```sql"]
  lines.push_iter(self.sql.iter())
  lines.push("```")
  lines.push("")
  lines.join("\n")
}
