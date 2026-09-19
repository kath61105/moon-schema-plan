///|
fn fragment_accepted(expression : String) -> Bool {
  let table = tbl("t", [
    id_column(),
    column("v", "TEXT", default_value=Some(expression)),
  ])
  @moon_schema_plan.validate_schema(sch("1", [table])).is_empty()
}

///|
test "a delimiter inside a quoted literal is not a statement terminator" {
  // These were rejected before: a string literal may legitimately contain any
  // of the three delimiters, and cannot end the statement it sits in.
  assert_true(fragment_accepted("'a--b'"))
  assert_true(fragment_accepted("'x;y'"))
  assert_true(fragment_accepted("'/* not a comment */'"))
  assert_true(fragment_accepted("'it''s quoted'"))
  assert_true(fragment_accepted("'-- dashes -- everywhere'"))
}

///|
test "a delimiter outside a literal is still rejected" {
  assert_false(fragment_accepted("0; DROP TABLE t"))
  assert_false(fragment_accepted("0 -- trailing comment"))
  assert_false(fragment_accepted("0 /* block comment */"))
  assert_false(fragment_accepted("'closed' ; DROP TABLE t"))
  assert_false(fragment_accepted(""))
}

///|
test "an unterminated literal is rejected" {
  // It would swallow whatever the renderer appends after the fragment.
  assert_false(fragment_accepted("'unterminated"))
  assert_false(fragment_accepted("'escaped'' but never closed"))
}

///|
test "ordinary expressions are unaffected" {
  assert_true(fragment_accepted("0"))
  assert_true(fragment_accepted("CURRENT_TIMESTAMP"))
  assert_true(fragment_accepted("(1 + 2) * 3"))
  assert_true(fragment_accepted("'anonymous'"))
}

///|
test "check expressions and data types use the same rule" {
  let with_check = tbl("t", [id_column()], checks=[
    { name: "c", expression: "note <> 'a--b'", },
  ])
  assert_true(
    @moon_schema_plan.validate_schema(sch("1", [with_check])).is_empty(),
  )
  let bad_type = tbl("t", [column("v", "TEXT; DROP TABLE t")])
  assert_false(
    @moon_schema_plan.validate_schema(sch("1", [bad_type])).is_empty(),
  )
}
