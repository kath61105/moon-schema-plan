///|
/// Usage, file, JSON or schema-validation failure. Nothing was rendered.
const EXIT_USAGE : Int = 1

///|
/// The plan is well formed but contains a step above the configured ceiling.
const EXIT_POLICY : Int = 2

///|
fn usage() -> String {
  (
    #|moon-schema-plan: deterministic schema diff and safe SQL planning
    #|
    #|Usage:
    #|  moon-schema-plan plan   <sqlite|postgresql> [options]
    #|  moon-schema-plan verify <sqlite|postgresql> [options]
    #|  moon-schema-plan demo
    #|  moon-schema-plan help
    #|
    #|Schema input (choose one form per schema):
    #|  --before <path>         read the source schema from a JSON file
    #|  --after <path>          read the target schema from a JSON file
    #|  --hints <path>          read explicit rename hints from a JSON file
    #|  --before-json <text>    pass the source schema as inline JSON
    #|  --after-json <text>     pass the target schema as inline JSON
    #|  --hints-json <text>     pass rename hints as inline JSON
    #|
    #|The first three positional arguments after the dialect are still accepted
    #|as inline before, after and hints JSON.
    #|
    #|Options:
    #|  --max-risk <safe|review|destructive>
    #|                          highest risk the run may contain (default: review)
    #|  --allow-destructive     alias for --max-risk destructive
    #|  --format <sql|json|markdown>
    #|                          plan output format (default: sql)
    #|                          verify accepts text, json or markdown (default: text)
    #|  --out <path>            write the output to a file instead of stdout
    #|
    #|Exit codes:
    #|  0  success, and for verify the plan satisfies the risk policy
    #|  1  usage, file, JSON or schema-validation error
    #|  2  the plan contains a step above --max-risk
    #|
    #|Run `moon-schema-plan demo` for a complete executable SQLite example.
  )
}

///|
/// `@sys.exit` does not return, but its MoonBit signature does. The `abort`
/// keeps the type checker honest without adding a reachable failure path.
fn[T] exit_with(code : Int) -> T {
  @sys.exit(code)
  abort("moon-schema-plan: the process failed to exit")
}

///|
fn[T] fail_cli(message : String) -> T {
  println(message)
  exit_with(EXIT_USAGE)
}

///|
fn read_file(path : String) -> String {
  @fs.read_file_to_string(path) catch {
    @fs.IOError(message) => fail_cli("cannot read \{path}: \{message}")
  }
}

///|
fn write_output(text : String, out : String?) -> Unit {
  match out {
    None => println(text)
    Some(path) =>
      @fs.write_string_to_file(path, text + "\n") catch {
        @fs.IOError(message) => fail_cli("cannot write \{path}: \{message}")
      }
  }
}

///|
fn parse_dialect(value : String) -> @lib.Dialect {
  match @lib.Dialect::parse(value) {
    Some(dialect) => dialect
    None => fail_cli("unsupported dialect: \{value}\n\{usage()}")
  }
}

///|
fn parse_max_risk(value : String) -> @lib.Risk {
  match @lib.Risk::parse(value) {
    Some(risk) => risk
    None => fail_cli("unsupported risk level: \{value}\n\{usage()}")
  }
}

///|
fn parse_schema(source : String, origin : String) -> @lib.Schema {
  let json = @json.parse(source) catch {
    err => fail_cli("invalid JSON in \{origin}: \{err}")
  }
  @lib.schema_from_json(json) catch {
    err => fail_cli("invalid schema in \{origin}: \{err}")
  }
}

///|
fn parse_hints(source : String, origin : String) -> @lib.RenameHints {
  let json = @json.parse(source) catch {
    err => fail_cli("invalid JSON in \{origin}: \{err}")
  }
  @json.from_json(json) catch {
    err => fail_cli("invalid rename hints in \{origin}: \{err}")
  }
}

///|
/// One schema argument, kept together with where it came from so that every
/// diagnostic can name the file or flag the operator actually used.
struct Source {
  text : String
  origin : String
}

///|
struct Options {
  mut before : Source?
  mut after : Source?
  mut hints : Source?
  mut max_risk : @lib.Risk
  mut format : String?
  mut out : String?
}

///|
fn Options::new() -> Options {
  {
    before: None,
    after: None,
    hints: None,
    max_risk: Review,
    format: None,
    out: None,
  }
}

///|
fn Options::assign(
  self : Options,
  slot : String,
  value : Source,
  command : String,
) -> Unit {
  let existing = match slot {
    "before" => self.before
    "after" => self.after
    _ => self.hints
  }
  if existing is Some(previous) {
    fail_cli(
      "the \{slot} schema was given twice: \{previous.origin} and \{value.origin}\n\{command}",
    )
  }
  match slot {
    "before" => self.before = Some(value)
    "after" => self.after = Some(value)
    _ => self.hints = Some(value)
  }
}

///|
/// Read the value that follows a flag, failing with the flag's own name rather
/// than a generic index error when it is missing.
fn flag_value(args : Array[String], index : Int) -> String {
  if index >= args.length() {
    fail_cli("\{args[index - 1]} requires a value\n\{usage()}")
  }
  args[index]
}

///|
fn parse_options(args : Array[String]) -> Options {
  let options = Options::new()
  let positional = ["before", "after", "hints"]
  let mut next_positional = 0
  let mut i = 3
  while i < args.length() {
    let argument = args[i]
    match argument {
      "--before" | "--after" | "--hints" => {
        let path = flag_value(args, i + 1)
        let slot = argument[2:].to_owned()
        options.assign(slot, { text: read_file(path), origin: path, }, usage())
        i = i + 2
      }
      "--before-json" | "--after-json" | "--hints-json" => {
        let text = flag_value(args, i + 1)
        let slot = argument[2:argument.length() - 5].to_owned()
        options.assign(slot, { text, origin: argument, }, usage())
        i = i + 2
      }
      "--max-risk" => {
        options.max_risk = parse_max_risk(flag_value(args, i + 1))
        i = i + 2
      }
      "--allow-destructive" => {
        options.max_risk = Destructive
        i = i + 1
      }
      "--format" => {
        options.format = Some(flag_value(args, i + 1))
        i = i + 2
      }
      "--out" => {
        options.out = Some(flag_value(args, i + 1))
        i = i + 2
      }
      value => {
        if value.has_prefix("--") {
          fail_cli("unknown option: \{value}\n\{usage()}")
        }
        if next_positional >= positional.length() {
          fail_cli("unexpected argument: \{value}\n\{usage()}")
        }
        let slot = positional[next_positional]
        next_positional = next_positional + 1
        options.assign(
          slot,
          { text: value, origin: "<\{slot} argument>", },
          usage(),
        )
        i = i + 1
      }
    }
  }
  options
}

///|
fn build_plan_from(args : Array[String]) -> (@lib.Plan, Options) {
  guard args.length() >= 3 else { fail_cli(usage()) }
  let dialect = parse_dialect(args[2])
  let options = parse_options(args)
  let before = match options.before {
    Some(source) => parse_schema(source.text, source.origin)
    None => fail_cli("the source schema is required; use --before\n\{usage()}")
  }
  let after = match options.after {
    Some(source) => parse_schema(source.text, source.origin)
    None => fail_cli("the target schema is required; use --after\n\{usage()}")
  }
  let hints = match options.hints {
    Some(source) => parse_hints(source.text, source.origin)
    None => @lib.RenameHints::empty()
  }
  match @lib.build_plan(before, after, dialect, hints~) {
    Ok(plan) => (plan, options)
    Err(issues) => fail_cli(ToJson::to_json(issues).stringify(indent=2))
  }
}

///|
/// Report the steps a policy rejects and leave with `EXIT_POLICY`. Printing the
/// offending steps is the whole point: an operator must see why CI failed.
fn[T] reject_policy(plan : @lib.Plan, max_risk : @lib.Risk) -> T {
  let violations = plan.steps_above(max_risk)
  println("migration policy violated: --max-risk is \{max_risk.label()}")
  for step in violations {
    println(
      "  \{step.id} [\{step.risk.label()}] \{step.change.describe()}: \{step.reason}",
    )
  }
  exit_with(EXIT_POLICY)
}

///|
fn run_plan(args : Array[String]) -> Unit {
  let (plan, options) = build_plan_from(args)
  if !plan.steps_above(options.max_risk).is_empty() {
    reject_policy(plan, options.max_risk)
  }
  let allow_destructive = options.max_risk == Destructive
  let rendered = match @lib.render_plan(plan, allow_destructive~) {
    Ok(rendered) => rendered
    Err(issues) => fail_cli(ToJson::to_json(issues).stringify(indent=2))
  }
  let output = match options.format.unwrap_or("sql") {
    "sql" => rendered.sql.join("\n")
    "json" => @lib.rendered_plan_to_json(rendered).stringify(indent=2)
    "markdown" => rendered.to_markdown()
    other => fail_cli("unsupported plan format: \{other}\n\{usage()}")
  }
  write_output(output, options.out)
}

///|
fn verify_text(plan : @lib.Plan, max_risk : @lib.Risk) -> String {
  let summary = plan.summary()
  let lines = [
    "schema \{plan.from_version} -> \{plan.to_version} (\{plan.dialect.label()})",
    "steps: \{summary.total} (safe \{summary.safe}, review \{summary.review}, destructive \{summary.destructive})",
    "highest risk: \{plan.max_risk().label()}",
    "policy: --max-risk \{max_risk.label()}",
  ]
  for step in plan.steps {
    lines.push("  \{step.id} [\{step.risk.label()}] \{step.change.describe()}")
  }
  lines.join("\n")
}

///|
/// `verify` never renders SQL. It answers one question for CI: may this
/// migration proceed under the configured policy?
fn run_verify(args : Array[String]) -> Unit {
  let (plan, options) = build_plan_from(args)
  let output = match options.format.unwrap_or("text") {
    "text" => verify_text(plan, options.max_risk)
    "json" => @lib.plan_to_json(plan).stringify(indent=2)
    "markdown" => plan.to_markdown()
    other => fail_cli("unsupported verify format: \{other}\n\{usage()}")
  }
  write_output(output, options.out)
  if !plan.steps_above(options.max_risk).is_empty() {
    reject_policy(plan, options.max_risk)
  }
}

///|
fn demo() -> String {
  let before = @lib.Schema::{
    version: "1",
    tables: [
      {
        name: "users",
        columns: [
          {
            name: "id",
            data_type: "INTEGER",
            nullable: false,
            default_value: None,
            primary_key: true,
            unique: false,
          },
          {
            name: "nickname",
            data_type: "TEXT",
            nullable: true,
            default_value: None,
            primary_key: false,
            unique: false,
          },
        ],
        indexes: [],
        foreign_keys: [],
        checks: [],
      },
    ],
  }
  let after = @lib.Schema::{
    version: "2",
    tables: [
      {
        name: "users",
        columns: [
          {
            name: "id",
            data_type: "INTEGER",
            nullable: false,
            default_value: None,
            primary_key: true,
            unique: false,
          },
          {
            name: "display_name",
            data_type: "TEXT",
            nullable: false,
            default_value: Some("'anonymous'"),
            primary_key: false,
            unique: false,
          },
        ],
        indexes: [
          {
            name: "users_display_name_idx",
            columns: ["display_name"],
            unique: false,
          },
        ],
        foreign_keys: [],
        checks: [],
      },
    ],
  }
  let hints = @lib.RenameHints::{
    tables: [],
    columns: [("users", "nickname", "display_name")],
  }
  let plan = match @lib.build_plan(before, after, @lib.SQLite, hints~) {
    Ok(plan) => plan
    Err(issues) => fail_cli(ToJson::to_json(issues).stringify(indent=2))
  }
  match @lib.render_plan(plan, allow_destructive=true) {
    Err(issues) => fail_cli(ToJson::to_json(issues).stringify(indent=2))
    Ok(rendered) => rendered.sql.join("\n")
  }
}

///|
fn main {
  let args = @env.args()
  if args.length() < 2 {
    println(usage())
    exit_with(EXIT_USAGE)
  }
  match args[1] {
    "plan" => run_plan(args)
    "verify" => run_verify(args)
    "demo" => println(demo())
    "help" | "--help" | "-h" => println(usage())
    command => fail_cli("unknown command: \{command}\n\{usage()}")
  }
}
