# Release and contest checklist

## Automated acceptance

- `moon fmt --check`
- `moon info`
- `moon check --deny-warn`
- `moon test --deny-warn`
- `scripts/sqlite_e2e.sh`
- compile for `wasm`, `wasm-gc`, `js`, and `native`
- run tests on the default, JavaScript, and native targets
- run the CLI example for both SQLite and PostgreSQL
- verify destructive SQL is rejected without `--allow-destructive`

## Before submission

- replace the `local` MoonBit module owner and repository placeholder
- create the public GitHub repository under the participant's account
- retain at least ten meaningful development commits
- enable GitHub Actions and confirm the CI badge is green
- publish the MoonBit package and verify its public documentation
- create a versioned release and attach the final demonstration material
- submit the repository URL before 2026-09-24 23:59 China Standard Time

The account-specific items are intentionally not fabricated by the codebase;
they must be completed using the entrant's real GitHub and MoonBit identities.
