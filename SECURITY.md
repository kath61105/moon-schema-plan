# Security policy

Please report security-sensitive issues privately to the repository owner after
the public repository is created. Until an owner contact is published, do not
include production credentials, private schemas, or exploit details in an issue.

The planner does not connect to a database or execute generated SQL. Schema JSON
is trusted configuration: SQL type and default-expression fields are validated
for statement delimiters but are not a full SQL sandbox. Review generated plans,
back up data, and rehearse production migrations in staging.
