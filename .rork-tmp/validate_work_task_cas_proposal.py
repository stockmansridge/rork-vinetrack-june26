"""Parse review SQL only. Never connects to or executes against a database."""
from pathlib import Path
from pglast import parse_sql, parse_plpgsql

for file in ("docs/work-task-cas-proposed.sql", "docs/work-task-cas-cutover-proposed.sql", "docs/work-task-cas-acceptance-proposed.sql"):
    source = Path(file).read_text()
    statements = parse_sql(source)
    # Standalone libpg_query has no live catalog to resolve %ROWTYPE fields.
    # Substitute only declarations in parser input, never the proposal files.
    parser_input = source.replace("public.work_tasks%ROWTYPE", "record").replace(
        "public.work_task_write_receipts%ROWTYPE", "record"
    )
    bodies = parse_plpgsql(parser_input)
    print(f"{file}: {len(statements)} SQL statements parsed; {len(bodies)} PL/pgSQL bodies parsed (catalog rowtypes substituted with record for syntax only)")
