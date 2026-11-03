#!/usr/bin/env python3
"""Derive the production SQL runners from the repair itself, so they can never drift from it.

  sql/occurrence_tank_link_uuid_case_identity_rehearsal.sql   proves the repair would apply, cannot commit
  sql/occurrence_tank_link_uuid_case_identity_apply.sql       applies the repair AND verifies it, in one paste

There is no non-production Supabase project for VineTrack. The substitute proof is a rehearsal that is
run against the REAL deployed catalog and is incapable of committing: it is ONE statement that performs
the exact repair logic (same fail-closed checks, same function rewrite), reads the catalog before and
after, and then ends in an exception. PostgreSQL rolls back every change of a failed statement, so there
is nothing to forget to roll back and nothing that can persist, even in an auto-commit SQL editor.

The apply script is the same repair logic wrapped so that one paste into the SQL editor both applies it and
reports the result. It is a single atomic statement: it validates BOTH functions before changing either.
Every refusal is a NORMAL result row that changes nothing and carries its own evidence, so one run is
enough to decide the next step:

  NOT_APPLIED_LIVE_FUNCTION_DIFFERS           a function is not in one of the two expected shapes; the live
                                              comparison lines and definition hashes are returned
  NOT_APPLIED_ROLE_CANNOT_REPLACE_FUNCTIONS   the session may not replace the functions (they belong to a
                                              restricted role); session, owner and membership facts are returned

It still raises - rolling everything back - if owner, ACL, SECURITY DEFINER or search_path would differ
afterwards or the post-condition fails. It also embeds the read-only, never-raising Trip readback from
sql/trip_end_recovery_readback.sql so one run reports the original Trip's server state as well.

Both are generated, never hand-edited.

    python3 scripts/build-tank-link-rehearsal-sql.py           # rewrite the files
    python3 scripts/build-tank-link-rehearsal-sql.py --check   # exit 1 if a committed file is stale
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'sql/occurrence_tank_link_uuid_case_identity.sql'
READBACK = ROOT / 'sql/trip_end_recovery_readback.sql'
TARGET = ROOT / 'sql/occurrence_tank_link_uuid_case_identity_rehearsal.sql'
APPLY = ROOT / 'sql/occurrence_tank_link_uuid_case_identity_apply.sql'
INCIDENT_TRIP = '492ebafc-b996-4ec4-8ea9-4261a3056810'

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

TIMEOUTS = """  -- Never wait on a lock behind live traffic, never run long.
  perform set_config('lock_timeout', '3s', true);
  perform set_config('statement_timeout', '30s', true);
"""


def capture(target: str) -> str:
    """Read owner, security flag, ACL, search_path and a definition hash of exactly the two repaired functions."""
    return f"""  {target} := (
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


IDENTITY_UNCHANGED = """(select jsonb_agg(e - 'definition_md5') from jsonb_array_elements(before_report) e)
     is distinct from (select jsonb_agg(e - 'definition_md5') from jsonb_array_elements(after_report) e)"""

BEFORE = TIMEOUTS + capture('before_report')

AFTER = ("  -- Rehearsal only: report, then ALWAYS fail so that nothing can be committed.\n"
         + capture('after_report')
         + f"""  if {IDENTITY_UNCHANGED} then
    raise exception 'REHEARSAL_FAILED_CATALOG_IDENTITY_CHANGED: before=% after=%', before_report, after_report;
  end if;
  raise exception 'REHEARSAL_PASSED_NOTHING_CHANGED: %', jsonb_build_object(
    'live_state_before_repair', jsonb_build_object('guard', guard_state, 'action', action_state),
    'catalog_before', before_report,
    'catalog_after_inside_this_statement', after_report,
    'note', 'This statement ends in an error on purpose; PostgreSQL rolled back every change in it. Nothing was committed.'
  )::text using errcode = 'P0001';
""")

APPLY_HEADER = """-- VineTrack: repair the iOS Trip End failure (OCCURRENCE_TANK_LINK_CONFLICT). APPLY + VERIFY in ONE run.
-- GENERATED from sql/occurrence_tank_link_uuid_case_identity.sql and sql/trip_end_recovery_readback.sql by
-- scripts/build-tank-link-rehearsal-sql.py. Do not edit by hand.
--
-- HOW: paste ALL of this into the Supabase SQL editor of the PRODUCTION project and press Run once. Then copy
-- the whole "details" cell back, WHATEVER "result" says. Nothing else is needed. (One exception: a red error
-- means PostgreSQL rolled everything back; copy the whole error back instead.)
--
-- WHY: the iPhone stores a tank-session id in UPPERCASE and the occurrence journal links it in lowercase. The
-- server compared the raw text, so every iPhone Trip that recorded a tank session was refused at Trip End.
--
-- WHAT: it rewrites two functions so the comparison ignores letter case:
--   public.guard_trip_occurrence_authority_v1()
--   public.apply_trip_occurrence_action_v1(uuid, uuid, bigint, bigint, jsonb)
-- Everything else about them is kept: owner, grants, SECURITY DEFINER, search_path, revision and ownership checks.
-- A tank-session link must still match a session recorded on the SAME Trip; a missing, malformed, padded or
-- different id is still refused.
--
-- SAFE: no table is written and no Trip, Spray Record, Actual or operation row is changed or replayed. It is ONE
-- statement: if any check fails, PostgreSQL discards all of it and nothing changes. It never rewrites a function
-- whose text is not exactly what the repository expects, and it does not try when this session is not allowed to
-- replace the functions. It fails, changing nothing, if owner, grants, security flag or search_path would differ
-- afterwards. Running it twice is harmless: the second run says ALREADY_APPLIED.
--
-- RESULT (the "result" column; "details" always holds the evidence to send back):
--   APPLIED                                    both functions were rewritten and verified in this run.
--   ALREADY_APPLIED                            both were already repaired; nothing was changed.
--   NOT_APPLIED_ROLE_CANNOT_REPLACE_FUNCTIONS  this session is not allowed to replace the functions (they belong
--                                              to a restricted role). NOTHING was changed; "details" says why.
--   NOT_APPLIED_LIVE_FUNCTION_DIFFERS          a live function is neither the original nor the repaired text.
--                                              NOTHING was changed; the live comparison lines are in "details".
-- "details" also holds a read-only snapshot of the original Trip as the server holds it right now.
"""

# Facts that explain a refusal: who this session is, who owns the functions, and how the roles are related.
# Every section reports its own error instead of raising, so the refusal row is always produced.
# Role NAMES and privilege flags only: no password, no secret, no customer data.
SESSION_FACTS_FUNCTION = """create or replace function pg_temp.vinetrack_session_facts(p_functions oid[])
returns jsonb
language plpgsql
as $facts$
declare
  facts jsonb;
  piece jsonb;
begin
  begin
    facts := jsonb_build_object(
      'current_user', current_user,
      'session_user', session_user,
      'is_superuser', current_setting('is_superuser', true),
      'server_version', current_setting('server_version', true),
      'server_version_num', current_setting('server_version_num', true),
      'database', current_database(),
      'may_create_in_schema_public', has_schema_privilege(current_user, 'public', 'CREATE'));
  exception when others then
    facts := jsonb_build_object('session_error', sqlstate || ' ' || sqlerrm);
  end;

  begin
    select jsonb_build_object(
             'rolsuper', r.rolsuper, 'rolcreaterole', r.rolcreaterole, 'rolinherit', r.rolinherit,
             'rolcanlogin', r.rolcanlogin, 'rolbypassrls', r.rolbypassrls)
      into piece
      from pg_roles r
     where r.rolname = current_user;
    facts := facts || jsonb_build_object('current_role_attributes', piece);
  exception when others then
    facts := facts || jsonb_build_object('current_role_attributes_error', sqlstate || ' ' || sqlerrm);
  end;

  begin
    select coalesce(jsonb_agg(jsonb_build_object(
             'function', p.oid::regprocedure::text,
             'owner', o.rolname,
             'owner_is_superuser', o.rolsuper,
             'owner_can_login', o.rolcanlogin,
             'owner_inherits_privileges', o.rolinherit,
             'session_is_member_of_owner', pg_has_role(current_user, p.proowner, 'MEMBER'),
             'session_has_owner_privileges', pg_has_role(current_user, p.proowner, 'USAGE'))
           order by p.oid::regprocedure::text), '[]'::jsonb)
      into piece
      from pg_proc p
      join pg_roles o on o.oid = p.proowner
     where p.oid = any (p_functions);
    facts := facts || jsonb_build_object('functions', piece);
  exception when others then
    facts := facts || jsonb_build_object('functions_error', sqlstate || ' ' || sqlerrm);
  end;

  -- PostgreSQL 16 added a separate SET privilege; an older server rejects the word, which is reported, not raised.
  begin
    select coalesce(jsonb_agg(distinct jsonb_build_object(
             'owner', pg_get_userbyid(p.proowner),
             'session_can_set_role_to_owner', pg_has_role(current_user, p.proowner, 'SET'))), '[]'::jsonb)
      into piece
      from pg_proc p
     where p.oid = any (p_functions);
    facts := facts || jsonb_build_object('set_role_to_owner', piece);
  exception when others then
    facts := facts || jsonb_build_object('set_role_to_owner', 'not_reported_before_postgresql_16');
  end;

  -- Membership rows that involve an owner role. Columns that exist only on newer servers come along as they are.
  begin
    select coalesce(jsonb_agg((jsonb_build_object(
                'role', pg_get_userbyid(m.roleid),
                'member', pg_get_userbyid(m.member),
                'grantor', pg_get_userbyid(m.grantor))
              || (to_jsonb(m) - 'oid' - 'roleid' - 'member' - 'grantor'))
           order by pg_get_userbyid(m.roleid), pg_get_userbyid(m.member)), '[]'::jsonb)
      into piece
      from pg_auth_members m
     where m.roleid in (select p.proowner from pg_proc p where p.oid = any (p_functions))
        or m.member in (select p.proowner from pg_proc p where p.oid = any (p_functions));
    facts := facts || jsonb_build_object('owner_role_memberships', piece);
  exception when others then
    facts := facts || jsonb_build_object('owner_role_memberships_error', sqlstate || ' ' || sqlerrm);
  end;

  -- The roles this session itself belongs to.
  begin
    select coalesce(jsonb_agg(pg_get_userbyid(m.roleid) order by pg_get_userbyid(m.roleid)), '[]'::jsonb)
      into piece
      from pg_auth_members m
     where m.member = (select r.oid from pg_roles r where r.rolname = current_user);
    facts := facts || jsonb_build_object('session_role_memberships', piece);
  exception when others then
    facts := facts || jsonb_build_object('session_role_memberships_error', sqlstate || ' ' || sqlerrm);
  end;

  -- Who owns the sibling occurrence functions.
  begin
    select coalesce(jsonb_agg(jsonb_build_object(
             'function', p.oid::regprocedure::text,
             'owner', pg_get_userbyid(p.proowner),
             'security_definer', p.prosecdef)
           order by p.oid::regprocedure::text), '[]'::jsonb)
      into piece
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname like '%occurrence%';
    facts := facts || jsonb_build_object('occurrence_functions', piece);
  exception when others then
    facts := facts || jsonb_build_object('occurrence_functions_error', sqlstate || ' ' || sqlerrm);
  end;

  return facts;
exception when others then
  return coalesce(facts, '{}'::jsonb) || jsonb_build_object('facts_error', sqlstate || ' ' || sqlerrm);
end;
$facts$;
"""

BEFORE_APPLY = TIMEOUTS + capture('before_report')

# Placed after both states are known and before anything is validated or changed. Each refusal RETURNS a normal
# result row (nothing has been changed at this point), so the person running it never has to guess or rerun.
CHECK_APPLICABLE = """  -- A function that is neither the original nor the repaired text is never rewritten blind: say so, with the lines.
  if guard_state = 'unexpected' or action_state = 'unexpected' then
    return jsonb_build_object(
      'result', 'NOT_APPLIED_LIVE_FUNCTION_DIFFERS',
      'changed', false,
      'next', 'NOTHING was changed. A live function is neither the original text nor the repaired text this repair knows, so it will not be rewritten blind. Send back this whole details cell.',
      'live_state_before', jsonb_build_object('guard', guard_state, 'action', action_state),
      'live_comparison_lines', jsonb_build_object(
        'guard', (select coalesce(jsonb_agg(left(btrim(x.l), 160)), '[]'::jsonb)
                  from (select l from regexp_split_to_table(guard_def, E'\\n') l where l like '%->>''id''%' limit 12) x),
        'action', (select coalesce(jsonb_agg(left(btrim(x.l), 160)), '[]'::jsonb)
                   from (select l from regexp_split_to_table(action_def, E'\\n') l where l like '%->>''id''%' limit 12) x)),
      'definition_md5', jsonb_build_object('guard', md5(guard_def), 'action', md5(action_def)),
      'catalog_before', before_report,
      'database', current_database(),
      'role', current_user);
  end if;

  -- Replacing a function needs the privileges of its owner (and CREATE on its schema). Only the functions that
  -- still need the repair count: an already repaired one is never touched.
  if exists (select 1 from pg_proc p
             where ((p.oid = guard_signature::oid and guard_state = 'unpatched')
                 or (p.oid = action_signature::oid and action_state = 'unpatched'))
               and (not pg_has_role(current_user, p.proowner, 'USAGE')
                    or not has_schema_privilege(current_user, p.pronamespace, 'CREATE'))) then
    return jsonb_build_object(
      'result', 'NOT_APPLIED_ROLE_CANNOT_REPLACE_FUNCTIONS',
      'changed', false,
      'next', 'NOTHING was changed. Only the owner of a function, a role that has the owner role privileges, or a superuser may replace it, and this session is none of those. Send back this whole details cell.',
      'live_state_before', jsonb_build_object('guard', guard_state, 'action', action_state),
      'catalog_before', before_report,
      'session', pg_temp.vinetrack_session_facts(array[guard_signature::oid, action_signature::oid]),
      'database', current_database(),
      'role', current_user);
  end if;
"""

AFTER_APPLY = (capture('after_report')
               + f"""  if {IDENTITY_UNCHANGED} then
    raise exception 'Occurrence tank-link repair would change owner, grants, security flag or search_path. NOTHING was committed. before=% after=%', before_report, after_report;
  end if;
  return jsonb_build_object(
    'result', case when guard_state = 'patched' and action_state = 'patched' then 'ALREADY_APPLIED' else 'APPLIED' end,
    'changed', not (guard_state = 'patched' and action_state = 'patched'),
    'live_state_before', jsonb_build_object('guard', guard_state, 'action', action_state),
    'catalog_before', before_report,
    'catalog_after', after_report,
    'identity_unchanged', true,
    'database', current_database(),
    'role', current_user);
""")

APPLY_FINAL_SELECT = f"""
-- The one result: "result" says what happened, "details" is what to copy back.
select r ->> 'result' as result,
       jsonb_pretty(jsonb_build_object(
         'repair', r,
         'original_trip_readback', pg_temp.vinetrack_trip_readback('{INCIDENT_TRIP}'::uuid))) as details
from (select pg_temp.vinetrack_apply_tank_link_repair() as r) as repaired;
"""


def repair_body() -> str:
    """The repair's DO block body: 'declare ... begin ... end;' without the DO wrapper."""
    text = SOURCE.read_text()
    marker = 'do $migration$'
    assert text.count(marker) == 1, 'the repair must contain exactly one DO block'
    body = text[text.index(marker):].rstrip()
    assert body.endswith('$migration$;'), 'the repair must end with its DO block'
    return body[len(marker):-len('$migration$;')]


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


def readback_function() -> str:
    text = READBACK.read_text()
    begin, end = '-- BEGIN READBACK FUNCTION\n', '-- END READBACK FUNCTION\n'
    assert text.count(begin) == 1 and text.count(end) == 1, 'the readback must delimit its function exactly once'
    function = text[text.index(begin) + len(begin):text.index(end)]
    assert function.lstrip().startswith('create or replace function pg_temp.vinetrack_trip_readback('), 'unexpected readback shape'
    return function.rstrip() + '\n'


def build_apply() -> str:
    inner = repair_body()
    assert inner.startswith('\ndeclare\n') and inner.endswith('\nend;\n'), 'unexpected repair shape: declare/end'
    assert inner.count('\nbegin\n') == 1, 'unexpected repair shape: begin'
    inner = inner.replace('\nbegin\n', '\n  before_report jsonb;\n  after_report jsonb;\nbegin\n' + BEFORE_APPLY, 1)
    validate = '\n  -- Validate BOTH before changing EITHER.\n'
    assert inner.count(validate) == 1, 'unexpected repair shape: validation marker'
    inner = inner.replace(validate, '\n' + CHECK_APPLICABLE + validate, 1)
    inner = inner[:-len('end;\n')] + '\n' + AFTER_APPLY + 'end;\n'
    return (APPLY_HEADER
            + '\n' + SESSION_FACTS_FUNCTION
            + '\ncreate or replace function pg_temp.vinetrack_apply_tank_link_repair()\n'
            + 'returns jsonb\nlanguage plpgsql\nas $apply$' + inner + '$apply$;\n\n'
            + readback_function()
            + APPLY_FINAL_SELECT)


def targets() -> dict:
    return {TARGET: build(), APPLY: build_apply()}


def main() -> int:
    generated = targets()
    if '--check' in sys.argv:
        stale = [path for path, text in generated.items() if not path.exists() or path.read_text() != text]
        for path in stale:
            print(f'STALE: {path.relative_to(ROOT)} does not match the repair. Run: python3 scripts/build-tank-link-rehearsal-sql.py')
        if stale:
            return 1
        print('rehearsal and apply files are derived from the current repair and readback')
        return 0
    for path, text in generated.items():
        path.write_text(text)
        print(f'wrote {path.relative_to(ROOT)}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
