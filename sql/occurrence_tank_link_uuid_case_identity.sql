-- Occurrence tank-link identity: compare tank-session UUIDs as UUIDs, not as case-sensitive text.
--
-- Why this exists
--   The iOS app encodes TankSession.id as an UPPERCASE UUID string in public.trips.tank_sessions.
--   The occurrence journal (and the Android app) record canonical LOWERCASE UUIDs in
--   occurrence_coverage.states[*].tankSessionIds. Both occurrence authority functions compared
--   the two with exact text equality (s->>'id' = link), so an iOS-recorded tank session could
--   never be linked: every setStatus(done) carrying a tank link, and therefore Trip End, failed
--   with OCCURRENCE_TANK_LINK_CONFLICT (SQLSTATE 40001, HTTP 500 through PostgREST).
--
-- What this changes (two comparison expressions only)
--   public.guard_trip_occurrence_authority_v1()                  s->>'id'=linked      -> lower(s->>'id')=lower(linked)
--   public.apply_trip_occurrence_action_v1(uuid,uuid,bigint,bigint,jsonb)
--                                                                s->>'id'=session_id  -> lower(s->>'id')=lower(session_id)
--   Both must change together: the guard trigger re-checks every stored link on every later UPDATE
--   of the Trip (non-authority PATCH, finalise), so patching only the action would still fail there.
--
-- What this does NOT change
--   No data is read, rewritten, deleted or replayed. Stored tank_sessions ids, journal links,
--   operation receipts, Actuals (spray_tank_actuals.tank_session_id) and report joins keep their
--   exact original text. A link must still match a session recorded on the SAME Trip; a missing,
--   malformed, padded or different-by-one-digit id is still rejected, and a linked session still
--   cannot be removed or replaced. No ownership, ACL, SECURITY DEFINER/INVOKER, search_path, RLS,
--   revision or CAS behaviour is touched: CREATE OR REPLACE keeps owner and ACL.
--
-- Safety
--   * Fail closed: each function must contain the old comparison exactly once (or the new one
--     exactly once). Any other shape raises and NOTHING is changed (single atomic statement).
--   * Idempotent: an already-patched function is skipped; re-running is a no-op; a half-applied
--     state is completed.
--   * Run it as a role that may replace BOTH functions (their owners; superuser or a member of
--     the owning roles). Capture sql/occurrence_tank_link_uuid_case_identity_verify.sql before and
--     after; owner, ACL, security flag and search_path must be identical, only the hash and the two
--     comparison flags change. STOP if anything differs.
--   * Apply to a disposable non-production database first. This file is NOT applied to production
--     by any automated step; production application needs separate explicit authorisation.
do $migration$
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
begin
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
end;
$migration$;
