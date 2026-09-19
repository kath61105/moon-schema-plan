# Release and contest checklist

The 2026 MoonBit September Hackathon accepts a project on six criteria: MoonBit
as the primary language, a public repository with a continuous and traceable
commit history, a project that runs and has a clear README plus tests,
substantive new work completed during the period, an accepted open-source
licence with any porting or reference clearly attributed, and an entrant who can
explain and stand behind every technical choice even where AI assisted.

This checklist maps those criteria onto commands.

## Automated acceptance

Each item below runs in `.github/workflows/ci.yml` and can be reproduced
locally.

- `moon fmt --check`
- `moon info` followed by `git diff --exit-code -- '*.mbti'`
- `moon check --deny-warn`
- `moon test --deny-warn` on `wasm`, `wasm-gc`, `js` and `native`
- `moon build --target <backend>` for the same four backends
- `sh scripts/cli_smoke.sh` — every documented command and exit code
- `sh scripts/sqlite_e2e.sh` — generated SQL applied to a real `sqlite3`
  database, asserting that rows survive, the dropped column is gone, indexes
  are recreated, no staging table is left behind, and an unapproved destructive
  plan emits no SQL at all

Coverage is checked with `moon coverage clean && moon test --enable-coverage &&
moon coverage report -f summary`. The library stands at 607 of 613 lines; the
remaining branches are unreachable for a validated schema and are commented as
such in `diff.mbt`. The CLI is verified through `scripts/cli_smoke.sh` rather
than unit tests, because its contract is its exit status, not its internals.

## Before submission

These steps need the entrant's real identities and are deliberately not
fabricated by the codebase.

- ~~replace the placeholder module owner and repository URL~~ — done: the
  module is `jamesrobin2026/moon_schema_plan` and the repository is
  `https://github.com/jamesrobin2026/moon-schema-plan`
- create the public GitHub repository and push `main`
- confirm GitHub Actions is enabled and the CI badge is green
- register the `jamesrobin2026` account on <https://mooncakes.io> (it signs in
  with GitHub), then `moon publish` and check the rendered documentation. A
  MoonBit module name is `<owner>/<module>`, and the owner must match a
  registered account, so this has to happen before the first publish
- tag a release and attach the demonstration material
- register on the event's Feishu form with the repository URL, and join the
  official participant group — the rules state that entrants who are not in the
  group may not receive prize money
- if the project is submitted as an existing project, state plainly in the
  README or the submission which work was completed during this period

## Timeline

The September period runs from the first week of September to **30 September
2026**, which is both the registration deadline and the acceptance deadline.
Confirm the date against the official Feishu charter before submitting; the
public site notes that the charter is the binding version.
