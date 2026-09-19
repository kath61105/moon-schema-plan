# Contributing

Contributions should preserve the project's conservative safety model:

- add or update tests for every planner or renderer behavior change;
- never infer renames without an explicit hint;
- keep output deterministic across input ordering;
- return an actionable issue instead of silently emitting partial SQL;
- document any dialect-specific behavior or unsupported operation.

Before opening a pull request, run:

```sh
moon fmt --check
moon info
moon check --deny-warn
moon test --deny-warn
sh scripts/cli_smoke.sh
sh scripts/sqlite_e2e.sh
sh scripts/postgres_e2e.sh
```

`scripts/cli_smoke.sh` asserts every command and exit code the README
documents, so a change to the CLI must update the README and that script
together. `scripts/sqlite_e2e.sh` needs the `sqlite3` binary on `PATH`, and
`scripts/postgres_e2e.sh` needs `psql` and a server described by the usual
libpq environment variables. Both execute generated SQL rather than comparing
it to expected strings, which is how every renderer defect so far was found.

`scripts/project_stats.sh` recomputes the commit, diff, test and coverage
figures that `README.md` and `docs/proposal.zh-CN.md` quote. Run it if you
change any of them.

`docs/design-decisions.md` and `docs/design-decisions.zh-CN.md` are the same
document in two languages. Change both, or neither.

Commit messages should describe one meaningful engineering change. Do not split
work into empty or mechanical commits merely to increase the count.
