///|
fn usage() -> String {
  (
    #|moon-schema-plan: deterministic schema diff and safe SQL planning
    #|
    #|Usage:
    #|  moon run cmd/main -- plan <sqlite|postgresql> <before-json> <after-json> [hints-json] [--allow-destructive] [--json]
    #|
    #|The schema and optional hints use the library's derived JSON representation.
    #|Run `moon run cmd/main -- demo` for a complete executable example.
  )
}

///|
fn[T] fail_cli(message : String) -> T {
  println(message)
  abort("moon-schema-plan failed")
}

///|
fn parse_dialect(value : String) -> @lib.Dialect {
  match value {
    "sqlite" => @lib.SQLite
    "postgres" | "postgresql" => @lib.PostgreSQL
    _ => fail_cli("unsupported dialect: \{value}")
  }
}

///|
fn parse_schema(value : String) -> @lib.Schema {
  let json = @json.parse(value) catch {
    err => fail_cli("invalid JSON: \{err}")
  }
  @lib.schema_from_json(json) catch {
    err => fail_cli("invalid schema: \{err}")
  }
}

///|
fn parse_hints(value : String) -> @lib.RenameHints {
  let json = @json.parse(value) catch {
    err => fail_cli("invalid hints JSON: \{err}")
  }
  @json.from_json(json) catch {
    err => fail_cli("invalid rename hints: \{err}")
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
fn run_plan(args : Array[String]) -> String {
  guard args.length() >= 5 else { fail_cli(usage()) }
  let dialect = parse_dialect(args[2])
  let before = parse_schema(args[3])
  let after = parse_schema(args[4])
  let mut hint_arg : String? = None
  let mut allow_destructive = false
  let mut json_output = false
  for i = 5; i < args.length(); i = i + 1 {
    match args[i] {
      "--allow-destructive" => allow_destructive = true
      "--json" => json_output = true
      value =>
        match hint_arg {
          None => hint_arg = Some(value)
          Some(_) => fail_cli("unexpected argument: \{value}\n\{usage()}")
        }
    }
  }
  let hints = hint_arg.map(parse_hints).unwrap_or(@lib.RenameHints::empty())
  let plan = match @lib.build_plan(before, after, dialect, hints~) {
    Ok(plan) => plan
    Err(issues) => fail_cli(ToJson::to_json(issues).stringify(indent=2))
  }
  match @lib.render_plan(plan, allow_destructive~) {
    Err(issues) => fail_cli(ToJson::to_json(issues).stringify(indent=2))
    Ok(rendered) =>
      if json_output {
        @lib.rendered_plan_to_json(rendered).stringify(indent=2)
      } else {
        rendered.sql.join("\n")
      }
  }
}

///|
fn main {
  let args = @env.args()
  let output = if args.length() >= 2 {
    match args[1] {
      "plan" => run_plan(args)
      "demo" => demo()
      "help" | "--help" | "-h" => usage()
      command => fail_cli("unknown command: \{command}\n\{usage()}")
    }
  } else {
    usage()
  }
  println(output)
}
