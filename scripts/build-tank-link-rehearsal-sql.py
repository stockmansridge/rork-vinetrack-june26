#!/usr/bin/env python3
"""Derive sql/occurrence_tank_link_uuid_case_identity_rehearsal.sql from the repair itself.

There is no non-production Supabase project for VineTrack. The substitute proof is a rehearsal that is
run against the REAL deployed catalog and is incapable of committing: it is ONE statement that performs
the exact repair logic (same fail-closed checks, same function rewrite), reads the catalog before and
after, and then ends in an exception. PostgreSQL rolls back every change of a failed statement, so there
is nothing to forget to roll back and nothing that can persist, even in an auto-commit SQL editor.

The rehearsal is generated, never hand-edited, so it cannot drift from the repair.

    python3 scripts/build-tank-link-rehearsal-sql.py           # rewrite the file
    python3 scripts/build-tank-link-rehearsal-sql.py --check   # exit 1 if the committed file is stale
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'sql/occurrence_tank_link_uuid_case_identity.sql'
TARGET = ROOT / 'sql/occurrence_tank_link_uuid_case_identity_rehearsal.sql'

HEADER = """-- REHEARSAL ONLY - GENERATED from sql/occurrence_tank_link_uuid_case_identity.sql by
-- scripts/build-tank-link-rehearsal-sql.py. Do not edit by hand.
--
-- Purpose
--   VineTrack has no non-production database. This proves, against the real deployed functions, that the
--   tank-link repair would apply cleanly - without applying it.
--
-- Why it cannot change production
--   It is a single statement. It runs the same checks and the same function rewrite as the repair, reads
--   the catalog before and after, and then ALWAYS raises an exception. PostgreSQL discards every change
--   made by a statement that raises, including the rewritten functions. There is no COMMIT to forget.
--   No table is read or written. No customer row, Trip, Spray Record or Actual is touched.
--
-- What you will see (THE RED ERROR IS THE EXPECTED, SUCCESSFUL RESULT)
--   REHEARSAL_PASSED_NOTHING_CHANGED: {...}    the repair would apply; copy the whole message back.
--   Occurrence tank-link comparison changed in ...   the live function differs from the repository;
--                                              the real repair would ALSO refuse. STOP and send it.
--   REHEARSAL_FAILED_CATALOG_IDENTITY_CHANGED  owner, ACL, security flag or search_path would change. STOP.
--   permission denied / must be owner          the role you used cannot replace the functions. STOP.
--
-- Afterwards run sql/occurrence_tank_link_uuid_case_identity_verify.sql (read only) and confirm the
-- md5 values are the same as in "catalog_before": nothing was kept.
"""

BEFORE = """  -- Never wait on a lock behind live traffic, never run long.
  perform set_config('lock_timeout', '3s', true);
  perform set_config('statement_timeout', '30s', true);
  before_report := (
    select jsonb_agg(jsonb_build_object(
      'function', p.oid::regprocedure::text,
      'owner', pg_get_userbyid(p.proowner),
      'security_definer', p.prosecdef,
      'acl', p.proacl::text,
      'search_path', coalesce((select s from unnest(p.proconfig) s where s like 'search_path=%'), ''),
      'definition_md5', md5(pg_get_functiondef(p.oid))) order by p.oid::regprocedure::text)
    from pg_proc p
    where p.oid in (guard_signature::oid, action_signature::oid));
"""

AFTER = """  -- Rehearsal only: report, then ALWAYS fail so that nothing can be committed.
  after_report := (
    select jsonb_agg(jsonb_build_object(
      'function', p.oid::regprocedure::text,
      'owner', pg_get_userbyid(p.proowner),
      'security_definer', p.prosecdef,
      'acl', p.proacl::text,
      'search_path', coalesce((select s from unnest(p.proconfig) s where s like 'search_path=%'), ''),
      'definition_md5', md5(pg_get_functiondef(p.oid))) order by p.oid::regprocedure::text)
    from pg_proc p
    where p.oid in (guard_signature::oid, action_signature::oid));
  if (select jsonb_agg(e - 'definition_md5') from jsonb_array_elements(before_report) e)
     is distinct from (select jsonb_agg(e - 'definition_md5') from jsonb_array_elements(after_report) e) then
    raise exception 'REHEARSAL_FAILED_CATALOG_IDENTITY_CHANGED: before=% after=%', before_report, after_report;
  end if;
  raise exception 'REHEARSAL_PASSED_NOTHING_CHANGED: %', jsonb_build_object(
    'live_state_before_repair', jsonb_build_object('guard', guard_state, 'action', action_state),
    'catalog_before', before_report,
    'catalog_after_inside_this_statement', after_report,
    'note', 'This statement ends in an error on purpose; PostgreSQL rolled back every change in it. Nothing was committed.'
  )::text using errcode = 'P0001';
"""


def build() -> str:
    text = SOURCE.read_text()
    marker = 'do $migration$'
    assert text.count(marker) == 1, 'the repair must contain exactly one DO block'
    body = text[text.index(marker):].rstrip()
    assert body.endswith('$migration$;'), 'the repair must end with its DO block'
    body = body.replace(marker, 'do $rehearsal$', 1)[:-len('$migration$;')] + '$rehearsal$;'
    assert body.count('\nbegin\n') == 1, 'unexpected repair shape: begin'
    body = body.replace('\nbegin\n', '\n  before_report jsonb;\n  after_report jsonb;\nbegin\n' + BEFORE, 1)
    tail = '\nend;\n$rehearsal$;'
    assert body.endswith(tail), 'unexpected repair shape: end'
    body = body[:-len(tail)] + '\n' + AFTER + 'end;\n$rehearsal$;\n'
    return HEADER + body


def main() -> int:
    generated = build()
    if '--check' in sys.argv:
        if not TARGET.exists() or TARGET.read_text() != generated:
            print(f'STALE: {TARGET.relative_to(ROOT)} does not match the repair. Run: python3 scripts/build-tank-link-rehearsal-sql.py')
            return 1
        print('rehearsal file is derived from the current repair')
        return 0
    TARGET.write_text(generated)
    print(f'wrote {TARGET.relative_to(ROOT)}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
