// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "jamesrobin2026/moon_schema_plan"

version = "0.1.0"

readme = "README.md"

repository = "https://github.com/jamesrobin2026/moon-schema-plan"

license = "Apache-2.0"

keywords = [ "database", "schema", "migration", "sqlite", "postgresql", "ci" ]

preferred_target = "wasm"

description = "Deterministic schema diff, migration planning, and destructive-change gates for MoonBit"

import {
  "moonbitlang/x@0.5.5",
}
