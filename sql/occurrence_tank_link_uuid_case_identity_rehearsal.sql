-- REHEARSAL ONLY - GENERATED from sql/occurrence_tank_link_uuid_case_identity.sql by
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
do $rehearsal$
declare
  guard_signature constant regprocedure := 'public.guard_trip_occurrence_authority_v1()'::regprocedure;
  action_signature constant regprocedure := 'public.apply_trip_occurrence_action_v1(uuid,uuid,bigint,bigint,jsonb)'::regprocedure;
  guard_needle constant text := $old$s->>'id'=linked$old$;
  guard_replacement constant text := $new$lower(s->>'id')=lower(linked)$new$;
  action_needle constant text := $old$s->>'id'=session_id$old$;
  action_replacement constant text := $new$lower(s->>'id')=lower(session_id)$new$;
  guard_def text;
  action_def text;
  guard_state text;
  action_state text;
  before_report jsonb;
  after_report jsonb;
begin
  -- Never wait on a lock behind live traffic, never run long.
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
  guard_def := pg_get_functiondef(guard_signature);
  action_def := pg_get_functiondef(action_signature);

  -- 'unpatched': old text exactly once, new text absent. 'patched': new text exactly once, old text absent.
  guard_state := case
    when (length(guard_def) - length(replace(guard_def, guard_needle, ''))) / length(guard_needle) = 1
     and (length(guard_def) - length(replace(guard_def, guard_replacement, ''))) / length(guard_replacement) = 0 then 'unpatched'
    when (length(guard_def) - length(replace(guard_def, guard_needle, ''))) / length(guard_needle) = 0
     and (length(guard_def) - length(replace(guard_def, guard_replacement, ''))) / length(guard_replacement) = 1 then 'patched'
    else 'unexpected' end;
  action_state := case
    when (length(action_def) - length(replace(action_def, action_needle, ''))) / length(action_needle) = 1
     and (length(action_def) - length(replace(action_def, action_replacement, ''))) / length(action_replacement) = 0 then 'unpatched'
    when (length(action_def) - length(replace(action_def, action_needle, ''))) / length(action_needle) = 0
     and (length(action_def) - length(replace(action_def, action_replacement, ''))) / length(action_replacement) = 1 then 'patched'
    else 'unexpected' end;

  -- Validate BOTH before changing EITHER.
  if guard_state = 'unexpected' then
    raise exception 'Occurrence tank-link comparison changed in guard_trip_occurrence_authority_v1; review the live function before applying this repair.';
  end if;
  if action_state = 'unexpected' then
    raise exception 'Occurrence tank-link comparison changed in apply_trip_occurrence_action_v1; review the live function before applying this repair.';
  end if;

  if guard_state = 'unpatched' then
    execute replace(guard_def, guard_needle, guard_replacement);
  end if;
  if action_state = 'unpatched' then
    execute replace(action_def, action_needle, action_replacement);
  end if;

  -- Post-condition: both functions now carry the case-insensitive comparison and no exact-text one.
  guard_def := pg_get_functiondef(guard_signature);
  action_def := pg_get_functiondef(action_signature);
  if strpos(guard_def, guard_replacement) = 0 or strpos(guard_def, guard_needle) > 0
     or strpos(action_def, action_replacement) = 0 or strpos(action_def, action_needle) > 0 then
    raise exception 'Occurrence tank-link repair did not produce the expected function definitions; nothing was committed.';
  end if;
  -- Rehearsal only: report, then ALWAYS fail so that nothing can be committed.
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
end;
$rehearsal$;
