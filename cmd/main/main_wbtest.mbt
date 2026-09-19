// Argument parsing decides what the tool will do, so it is worth testing
// directly rather than only through the CLI smoke script. `parse_options`
// performs no I/O and exits no process, which is what makes these reachable.
//
// The first three arguments are the program name, the command and the dialect,
// so every case below starts with three placeholders.

///|
fn parsed(rest : Array[String]) -> Options {
  let args = ["moon-schema-plan", "plan", "postgresql"]
  args.push_iter(rest.iter())
  match parse_options(args) {
    Ok(options) => options
    Err(message) => abort("expected these arguments to parse: \{message}")
  }
}

///|
fn rejected_args(rest : Array[String]) -> String {
  let args = ["moon-schema-plan", "plan", "postgresql"]
  args.push_iter(rest.iter())
  match parse_options(args) {
    Ok(_) => abort("expected these arguments to be rejected")
    Err(message) => message
  }
}

///|
test "no arguments leaves every option at its default" {
  let options = parsed([])
  assert_eq(options.before, None)
  assert_eq(options.after, None)
  assert_eq(options.hints, None)
  assert_eq(options.max_risk, @lib.Review)
  assert_eq(options.format, None)
  assert_eq(options.out, None)
}

///|
test "each file flag records its path against the right slot" {
  let options = parsed([
    "--before", "a.json", "--after", "b.json", "--hints", "h.json",
  ])
  assert_eq(
    options.before,
    Some({ kind: File, value: "a.json", origin: "a.json", }),
  )
  assert_eq(
    options.after,
    Some({ kind: File, value: "b.json", origin: "b.json", }),
  )
  assert_eq(
    options.hints,
    Some({ kind: File, value: "h.json", origin: "h.json", }),
  )
}

///|
test "each inline flag records its text and names itself as the origin" {
  let options = parsed([
    "--before-json", "{}", "--after-json", "[]", "--hints-json", "null",
  ])
  assert_eq(
    options.before,
    Some({ kind: Inline, value: "{}", origin: "--before-json", }),
  )
  assert_eq(
    options.after,
    Some({ kind: Inline, value: "[]", origin: "--after-json", }),
  )
  assert_eq(
    options.hints,
    Some({ kind: Inline, value: "null", origin: "--hints-json", }),
  )
}

///|
test "positional arguments fill before, after and hints in order" {
  let options = parsed(["{\"a\":1}", "{\"b\":2}", "{\"c\":3}"])
  assert_eq(
    options.before,
    Some({ kind: Inline, value: "{\"a\":1}", origin: "<before argument>", }),
  )
  assert_eq(
    options.after,
    Some({ kind: Inline, value: "{\"b\":2}", origin: "<after argument>", }),
  )
  assert_eq(
    options.hints,
    Some({ kind: Inline, value: "{\"c\":3}", origin: "<hints argument>", }),
  )
}

///|
test "a fourth positional argument is rejected" {
  assert_true(
    rejected_args(["a", "b", "c", "d"]).contains("unexpected argument: d"),
  )
}

///|
test "a slot given twice is rejected, naming both origins" {
  let message = rejected_args(["--before", "a.json", "--before-json", "{}"])
  assert_true(message.contains("the before schema was given twice"))
  assert_true(message.contains("a.json"))
  assert_true(message.contains("--before-json"))
  // The positional and flag forms collide the same way.
  assert_true(
    rejected_args(["{}", "--before", "a.json"]).contains(
      "the before schema was given twice",
    ),
  )
}

///|
test "max-risk accepts each level and rejects anything else" {
  assert_eq(parsed(["--max-risk", "safe"]).max_risk, @lib.Safe)
  assert_eq(parsed(["--max-risk", "review"]).max_risk, @lib.Review)
  assert_eq(parsed(["--max-risk", "destructive"]).max_risk, @lib.Destructive)
  assert_true(
    rejected_args(["--max-risk", "reckless"]).contains(
      "unsupported risk level: reckless",
    ),
  )
}

///|
test "allow-destructive is exactly max-risk destructive" {
  assert_eq(
    parsed(["--allow-destructive"]).max_risk,
    parsed(["--max-risk", "destructive"]).max_risk,
  )
}

///|
test "the last risk setting wins" {
  assert_eq(
    parsed(["--allow-destructive", "--max-risk", "safe"]).max_risk,
    @lib.Safe,
  )
  assert_eq(
    parsed(["--max-risk", "safe", "--allow-destructive"]).max_risk,
    @lib.Destructive,
  )
}

///|
test "format and out are recorded verbatim" {
  let options = parsed(["--format", "markdown", "--out", "plan.md"])
  assert_eq(options.format, Some("markdown"))
  assert_eq(options.out, Some("plan.md"))
}

///|
test "every value-taking flag reports itself when its value is missing" {
  for
    flag in [
      "--before", "--after", "--hints", "--before-json", "--after-json", "--hints-json",
      "--max-risk", "--format", "--out",
    ] {
    let message = rejected_args([flag])
    assert_true(message.contains(flag))
    assert_true(message.contains("requires a value"))
  }
}

///|
test "an unknown option is rejected rather than treated as positional" {
  assert_true(rejected_args(["--colour"]).contains("unknown option: --colour"))
  assert_true(rejected_args(["--"]).contains("unknown option: --"))
}

///|
test "a value that looks like a flag is still consumed as the flag's value" {
  // `--out --format` is a mistake, but the parser has no way to know that, and
  // guessing would be worse than taking the argument at its word.
  assert_eq(parsed(["--out", "--format"]).out, Some("--format"))
}

///|
test "flags may appear in any order" {
  let one = parsed([
    "--before", "a.json", "--max-risk", "safe", "--after", "b.json",
  ])
  let two = parsed([
    "--max-risk", "safe", "--after", "b.json", "--before", "a.json",
  ])
  assert_eq(one.before, two.before)
  assert_eq(one.after, two.after)
  assert_eq(one.max_risk, two.max_risk)
}

///|
test "an inline source resolves to itself" {
  assert_eq(
    resolve({ kind: Inline, value: "{}", origin: "--before-json", }),
    "{}",
  )
}
