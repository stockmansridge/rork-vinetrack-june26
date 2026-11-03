-- VineTrack: repair the iOS Trip End failure (OCCURRENCE_TANK_LINK_CONFLICT). APPLY + VERIFY in ONE run.
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

create or replace function pg_temp.vinetrack_session_facts(p_functions oid[])
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

create or replace function pg_temp.vinetrack_apply_tank_link_repair()
returns jsonb
language plpgsql
as $apply$
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

  -- A function that is neither the original nor the repaired text is never rewritten blind: say so, with the lines.
  if guard_state = 'unexpected' or action_state = 'unexpected' then
    return jsonb_build_object(
      'result', 'NOT_APPLIED_LIVE_FUNCTION_DIFFERS',
      'changed', false,
      'next', 'NOTHING was changed. A live function is neither the original text nor the repaired text this repair knows, so it will not be rewritten blind. Send back this whole details cell.',
      'live_state_before', jsonb_build_object('guard', guard_state, 'action', action_state),
      'live_comparison_lines', jsonb_build_object(
        'guard', (select coalesce(jsonb_agg(left(btrim(x.l), 160)), '[]'::jsonb)
                  from (select l from regexp_split_to_table(guard_def, E'\n') l where l like '%->>''id''%' limit 12) x),
        'action', (select coalesce(jsonb_agg(left(btrim(x.l), 160)), '[]'::jsonb)
                   from (select l from regexp_split_to_table(action_def, E'\n') l where l like '%->>''id''%' limit 12) x)),
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
end;
$apply$;

create or replace function pg_temp.vinetrack_trip_readback(p_trip uuid)
returns jsonb
language plpgsql
as $readback$
declare
  trip_part jsonb;
  operations_part jsonb;
  actuals_part jsonb;
  spray_part jsonb;
begin
  -- Every section is guarded on its own: a missing table or column is reported, never raised.
  begin
    execute $q$
      select jsonb_build_object(
        'found', true,
        'vineyard_id', t.vineyard_id,
        'is_active', t.is_active,
        'end_time', t.end_time,
        'deleted_at', t.deleted_at,
        'sync_version', t.sync_version,
        'updated_at', t.updated_at,
        'tank_session_ids', coalesce((
            select jsonb_agg(s ->> 'id' order by s ->> 'id')
            from jsonb_array_elements(case when jsonb_typeof(t.tank_sessions) = 'array'
                                           then t.tank_sessions else '[]'::jsonb end) s), '[]'::jsonb),
        'occurrence_revision', t.occurrence_coverage ->> 'revision',
        'occurrence_status_counts', coalesce((
            select jsonb_object_agg(x.k, x.c) from (
              select coalesce(e.v ->> 'status', 'unknown') as k, count(*) as c
              from jsonb_each(case when jsonb_typeof(t.occurrence_coverage -> 'states') = 'object'
                                   then t.occurrence_coverage -> 'states' else '{}'::jsonb end) as e(id, v)
              group by 1) x), '{}'::jsonb),
        'occurrence_linked_tank_session_ids', coalesce((
            select jsonb_agg(l.link order by l.link)
            from jsonb_each(case when jsonb_typeof(t.occurrence_coverage -> 'states') = 'object'
                                 then t.occurrence_coverage -> 'states' else '{}'::jsonb end) as e(id, v),
                 jsonb_array_elements_text(case when jsonb_typeof(e.v -> 'tankSessionIds') = 'array'
                                                then e.v -> 'tankSessionIds' else '[]'::jsonb end) as l(link)), '[]'::jsonb))
      from public.trips t
      where t.id = $1
    $q$ into trip_part using p_trip;
    trip_part := coalesce(trip_part, jsonb_build_object('found', false));
  exception when others then
    trip_part := jsonb_build_object('readback_error', sqlerrm, 'sqlstate', sqlstate);
  end;

  begin
    execute $q$
      select jsonb_build_object(
        'count', count(*),
        'accepted', coalesce(jsonb_agg(jsonb_build_object(
            'operation_id', o.operation_id,
            'kind', coalesce(o.request ->> 'kind', o.request #>> '{action,kind}'),
            'occurrence_id', o.occurrence_id,
            'accepted_at', o.accepted_at,
            'to_status', o.request #>> '{action,toStatus}',
            'resulting_status', o.resulting_state ->> 'status',
            'linked_tank_session_ids', o.resulting_state -> 'tankSessionIds',
            'requested_end_time', o.request #>> '{end,endTime}',
            'result_end_time', o.result ->> 'endTime',
            'result_is_active', o.result ->> 'isActive') order by o.accepted_at, o.operation_id), '[]'::jsonb))
      from public.trip_occurrence_operations o
      where o.trip_id = $1
    $q$ into operations_part using p_trip;
  exception when others then
    operations_part := jsonb_build_object('readback_error', sqlerrm, 'sqlstate', sqlstate);
  end;

  begin
    execute $q$
      select jsonb_build_object(
        'count', count(*),
        'rows', coalesce(jsonb_agg(jsonb_build_object(
            'id', a.id,
            'spray_record_id', a.spray_record_id,
            'tank_session_id', a.tank_session_id,
            'tank_number', a.tank_number,
            'water_volume_l', a.water_volume_l,
            'confirmed_at', a.confirmed_at,
            'sync_version', a.sync_version) order by a.tank_number, a.id), '[]'::jsonb))
      from public.spray_tank_actuals a
      where a.trip_id = $1 and a.deleted_at is null
    $q$ into actuals_part using p_trip;
  exception when others then
    actuals_part := jsonb_build_object('readback_error', sqlerrm, 'sqlstate', sqlstate);
  end;

  begin
    execute $q$
      select jsonb_build_object(
        'count', count(*),
        'completed_count', count(*) filter (where r.end_time is not null and r.deleted_at is null),
        'rows', coalesce(jsonb_agg(jsonb_build_object(
            'id', r.id,
            'completed', r.end_time is not null,
            'end_time', r.end_time,
            'deleted_at', r.deleted_at,
            'sync_version', r.sync_version) order by r.created_at, r.id), '[]'::jsonb))
      from public.spray_records r
      where r.trip_id = $1 and not r.is_template
    $q$ into spray_part using p_trip;
  exception when others then
    spray_part := jsonb_build_object('readback_error', sqlerrm, 'sqlstate', sqlstate);
  end;

  return jsonb_build_object(
    'trip_id', p_trip,
    'trip', trip_part,
    'occurrence_operations', operations_part,
    'tank_actuals', actuals_part,
    'spray_records', spray_part,
    'summary', jsonb_build_object(
      'trip_ended_on_server', coalesce(
        (trip_part ->> 'is_active') = 'false' and (trip_part ->> 'end_time') is not null and (trip_part ->> 'deleted_at') is null, false),
      'tank_session_count', coalesce(jsonb_array_length(trip_part -> 'tank_session_ids'), 0),
      'tank_actual_count', coalesce((actuals_part ->> 'count')::int, -1),
      'spray_completed_count', coalesce((spray_part ->> 'completed_count')::int, -1)));
exception when others then
  return jsonb_build_object('trip_id', p_trip, 'readback_error', sqlerrm, 'sqlstate', sqlstate);
end;
$readback$;

-- The one result: "result" says what happened, "details" is what to copy back.
select r ->> 'result' as result,
       jsonb_pretty(jsonb_build_object(
         'repair', r,
         'original_trip_readback', pg_temp.vinetrack_trip_readback('492ebafc-b996-4ec4-8ea9-4261a3056810'::uuid))) as details
from (select pg_temp.vinetrack_apply_tank_link_repair() as r) as repaired;
