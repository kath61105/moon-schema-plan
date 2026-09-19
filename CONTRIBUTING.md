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
scripts/sqlite_e2e.sh
```

Commit messages should describe one meaningful engineering change. Do not split
work into empty or mechanical commits merely to increase the count.
