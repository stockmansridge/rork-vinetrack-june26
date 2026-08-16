-- =============================================================================
-- Tests for sql/198_sync_concurrency_revisions.sql
--
-- ROLLBACK-ONLY. Nothing is committed. Run with:
--   psql "$DATABASE_URL" -f sql/tests/198_sync_concurrency_revisions_tests.sql
--
-- EVERY write test runs as `authenticated` with RLS ACTIVE. The sql/195/197
-- finding was that owner-role tests cannot see RLS-dependent defects, and this
-- migration's guard writes to an RLS-protected audit table, so an owner-role
-- suite would prove nothing about the path real clients take.
--
-- Coverage
--   T1  repair is in place (columns, triggers, trigger ORDER, SECURITY DEFINER)
--   T2  a fast clock is clamped on insert    (fast-clock defect)
--   T3  a fast clock cannot lock out later writers (fast-clock defect, e2e)
--   T4  slow clock + base_revision: valid edit ACCEPTED (slow-clock defect)
--   T5  absurd clock (3 days behind, then ahead): version still decides
--   T6  genuine stale edit (based on N, row at N+1) -> REVISION_CONFLICT
--   T7  offline edit, no server conflict -> succeeds despite slow clock
--   T8  offline edit, server conflict -> explicit conflict, not silence
--   T9  repeated sync: revision advances and the next edit on it succeeds
--   T10 portal/server-time write, then slow-clock mobile edit -> succeeds
--   T11 legacy path (no base_revision) discard is RECORDED, not silent
--   T12 base_revision is never persisted (old-client compatibility)
--   T13 clients cannot forge server_revision
--   T14 pruning_seasons has the identical contract
--   T15 pruning_yield_settings has the identical contract
--   T16 sync_discarded_writes leaks nothing across vineyards
--   T17 conflict payload discloses no foreign vineyard data
--   T18 rollback
--
-- Expected final line:
--   NOTICE: sql/198 sync concurrency tests: ALL PASSED
-- =============================================================================
begin;

-- ---------------- T1 preconditions ----------------
do $$
declare
  t text;
  v_order text;
begin
  if to_regprocedure('public.bump_server_revision()') is null then
    raise exception 'T1 FAILED: sql/198 not applied (bump_server_revision missing)';
  end if;
  if to_regprocedure('public.clamp_client_updated_at()') is null then
    raise exception 'T1 FAILED: clamp_client_updated_at missing';
  end if;
  if to_regclass('public.sync_discarded_writes') is null then
    raise exception 'T1 FAILED: sync_discarded_writes missing';
  end if;

  -- The guard writes an RLS-protected table; caller rights would silently drop
  -- the audit row for exactly the writers we need to record (the sql/197 bug).
  if not (select prosecdef from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname='public' and p.proname='reject_stale_client_write') then
    raise exception 'T1 FAILED: reject_stale_client_write() must be SECURITY DEFINER';
  end if;
  if not (select prosecdef from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname='public' and p.proname='clamp_client_updated_at') then
    raise exception 'T1 FAILED: clamp_client_updated_at() must be SECURITY DEFINER';
  end if;

  foreach t in array array['pruning_seasons','pruning_yield_settings','resistance_plans']
  loop
    if not exists (select 1 from information_schema.columns
                    where table_schema='public' and table_name=t and column_name='server_revision') then
      raise exception 'T1 FAILED: %.server_revision missing', t;
    end if;
    if not exists (select 1 from information_schema.columns
                    where table_schema='public' and table_name=t and column_name='base_revision') then
      raise exception 'T1 FAILED: %.base_revision missing', t;
    end if;

    -- The old silent guard must be GONE, or a table would carry both wirings.
    if exists (select 1 from pg_trigger g join pg_class c on c.oid=g.tgrelid
                where c.relname=t and g.tgname like '%\_stale\_write\_guard' and not g.tgisinternal) then
      raise exception 'T1 FAILED: legacy stale_write_guard still attached to %', t;
    end if;

    -- Firing order is load-bearing: clamp must precede the comparison, and the
    -- revision may only advance for a row that survived the guard.
    select string_agg(g.tgname, ',' order by g.tgname) into v_order
      from pg_trigger g join pg_class c on c.oid=g.tgrelid
     where c.relname=t and not g.tgisinternal and g.tgname like 't__\_%';
    if v_order is distinct from 't10_clamp_client_clock,t20_concurrency_guard,t30_bump_server_revision' then
      raise exception 'T1 FAILED: % trigger order is "%"', t, v_order;
    end if;
  end loop;

  raise notice 'T1 passed (sql/198 in place, trigger order correct)';
end$$;

-- ---------------- fixtures ----------------
do $$
declare
  u_a uuid; u_b uuid;
begin
  perform set_config('role', 'postgres', true);

  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated',
     'authenticated', 't198-a@test.local', 'x', now(), now(), now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated',
     'authenticated', 't198-b@test.local', 'x', now(), now(), now());

  select id into u_a from auth.users where email = 't198-a@test.local';
  select id into u_b from auth.users where email = 't198-b@test.local';

  insert into public.profiles (id, email) values
    (u_a, 't198-a@test.local'), (u_b, 't198-b@test.local')
  on conflict (id) do nothing;

  -- Vineyard 1: both users are members (multi-device conflict fixtures).
  -- Vineyard 2: neither is a member (isolation fixtures).
  insert into public.vineyards (id, name) values
    ('d8000000-0000-0000-0000-000000000001', 'T198 Home'),
    ('d8000000-0000-0000-0000-000000000002', 'T198 Foreign');

  insert into public.vineyard_members (vineyard_id, user_id, role) values
    ('d8000000-0000-0000-0000-000000000001', u_a, 'manager'),
    ('d8000000-0000-0000-0000-000000000001', u_b, 'manager');

  insert into public.paddocks (id, vineyard_id, name) values
    ('d8000000-0000-0000-0000-0000000000a1', 'd8000000-0000-0000-0000-000000000001', 'T198 Block A'),
    ('d8000000-0000-0000-0000-0000000000a2', 'd8000000-0000-0000-0000-000000000001', 'T198 Block B'),
    ('d8000000-0000-0000-0000-0000000000f1', 'd8000000-0000-0000-0000-000000000002', 'T198 Foreign Block');

  perform set_config('vinetrack.test_user_a', u_a::text, false);
  perform set_config('vinetrack.test_user_b', u_b::text, false);
end$$;

-- Helper: become one of the fixture users, with RLS enforced.
create or replace function public._t198_login(p_which text)
returns void language plpgsql as $$
declare v_uid text;
begin
  v_uid := current_setting('vinetrack.test_user_' || p_which, true);
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end$$;

-- =====================================================================
-- T2 / T3  FAST-CLOCK DEFECT
-- =====================================================================
do $$
declare
  v_plan   uuid := gen_random_uuid();
  v_stored timestamptz;
  v_rev    bigint;
begin
  perform public._t198_login('a');

  -- A device running 10 minutes AHEAD creates a plan.
  insert into public.resistance_plans (id, vineyard_id, season_id, disease, client_updated_at)
  values (v_plan, 'd8000000-0000-0000-0000-000000000001', '2026-27', 'powdery mildew',
          now() + interval '10 minutes');

  select client_updated_at, server_revision into v_stored, v_rev
    from public.resistance_plans where id = v_plan;

  if v_stored > now() then
    raise exception 'T2 FAILED: a future client_updated_at was stored (%) — clamp not applied', v_stored;
  end if;
  if v_rev <> 1 then
    raise exception 'T2 FAILED: a new row should start at server_revision 1, got %', v_rev;
  end if;
  raise notice 'T2 passed (fast clock clamped to server time on insert)';

  -- T3: the poisoning scenario end-to-end. Another writer with an HONEST clock
  -- must not be locked out. Under sql/185 the stored +10min stamp would have
  -- made every write for the next 10 minutes look stale and vanish.
  perform public._t198_login('b');
  update public.resistance_plans
     set notes = 'honest clock edit', client_updated_at = now()
   where id = v_plan;

  if not exists (select 1 from public.resistance_plans
                  where id = v_plan and notes = 'honest clock edit') then
    raise exception 'T3 FAILED: an honest-clock edit was discarded because an earlier writer had a fast clock';
  end if;
  raise notice 'T3 passed (fast clock cannot lock out later writers)';
end$$;

-- =====================================================================
-- T4 / T5  SLOW AND ABSURD CLOCKS, VERSIONED PATH
-- =====================================================================
do $$
declare
  v_plan uuid := gen_random_uuid();
  v_rev  bigint;
begin
  perform public._t198_login('a');

  insert into public.resistance_plans (id, vineyard_id, season_id, disease, client_updated_at)
  values (v_plan, 'd8000000-0000-0000-0000-000000000001', '2026-27', 'downy mildew', now());

  -- The portal then saves, with SERVER time. This is what puts a stored stamp
  -- in front of a slow device — the exact production setup that broke.
  update public.resistance_plans
     set notes = 'portal save', client_updated_at = now()
   where id = v_plan;
  select server_revision into v_rev from public.resistance_plans where id = v_plan;

  -- T4: a phone 10 MINUTES BEHIND makes a genuine new edit, correctly based on
  -- the current version. It must be accepted; its clock is irrelevant.
  update public.resistance_plans
     set notes = 'slow phone edit',
         client_updated_at = now() - interval '10 minutes',
         base_revision = v_rev
   where id = v_plan;

  if not exists (select 1 from public.resistance_plans
                  where id = v_plan and notes = 'slow phone edit') then
    raise exception 'T4 FAILED: a valid edit from a slow-clock device was discarded (slow-clock defect present)';
  end if;
  raise notice 'T4 passed (slow clock + correct base_revision accepted)';

  -- T5: absurd skew, both directions. Version still decides.
  select server_revision into v_rev from public.resistance_plans where id = v_plan;
  update public.resistance_plans
     set notes = 'three days behind',
         client_updated_at = now() - interval '3 days',
         base_revision = v_rev
   where id = v_plan;
  if not exists (select 1 from public.resistance_plans
                  where id = v_plan and notes = 'three days behind') then
    raise exception 'T5 FAILED: a 3-day-behind clock was rejected on the versioned path';
  end if;

  select server_revision into v_rev from public.resistance_plans where id = v_plan;
  update public.resistance_plans
     set notes = 'three days ahead',
         client_updated_at = now() + interval '3 days',
         base_revision = v_rev
   where id = v_plan;
  if not exists (select 1 from public.resistance_plans
                  where id = v_plan and notes = 'three days ahead') then
    raise exception 'T5 FAILED: a 3-day-ahead clock was rejected on the versioned path';
  end if;
  if (select client_updated_at from public.resistance_plans where id = v_plan) > now() then
    raise exception 'T5 FAILED: the 3-day-ahead stamp was stored unclamped';
  end if;
  raise notice 'T5 passed (absurd skew both directions: version decides, clock clamped)';
end$$;

-- =====================================================================
-- T6 / T8  GENUINE STALE EDIT IS DETECTED EXPLICITLY
-- =====================================================================
do $$
declare
  v_plan  uuid := gen_random_uuid();
  v_rev_n bigint;
  v_state text;
  v_msg   text;
begin
  perform public._t198_login('a');
  insert into public.resistance_plans (id, vineyard_id, season_id, disease, client_updated_at)
  values (v_plan, 'd8000000-0000-0000-0000-000000000001', '2026-27', 'botrytis', now());

  -- Device A reads revision N and goes offline.
  select server_revision into v_rev_n from public.resistance_plans where id = v_plan;

  -- Device B saves -> N+1.
  perform public._t198_login('b');
  update public.resistance_plans
     set notes = 'device B wins', client_updated_at = now(),
         base_revision = v_rev_n
   where id = v_plan;

  -- Device A reconnects and submits its edit based on N. Its wall clock is
  -- LATER than B's, which under sql/185 would have let it silently overwrite
  -- B's newer work. It must now be refused, loudly.
  perform public._t198_login('a');
  begin
    update public.resistance_plans
       set notes = 'device A stale replay',
           client_updated_at = now() + interval '5 minutes',
           base_revision = v_rev_n
     where id = v_plan;
  exception when others then
    v_state := sqlstate; v_msg := sqlerrm;
  end;

  if v_state is null then
    raise exception 'T6 FAILED: a genuinely stale edit (based on N, row at N+1) was ACCEPTED';
  end if;
  if v_state <> 'PT409' then
    raise exception 'T6 FAILED: expected SQLSTATE PT409, got % (%)', v_state, v_msg;
  end if;
  if v_msg not like '%REVISION_CONFLICT%' then
    raise exception 'T6 FAILED: conflict signal is not machine-readable, got "%"', v_msg;
  end if;

  -- The loser must not have damaged the winner.
  if (select notes from public.resistance_plans where id = v_plan) <> 'device B wins' then
    raise exception 'T6 FAILED: the newer edit was overwritten by the stale replay';
  end if;
  raise notice 'T6/T8 passed (stale edit -> REVISION_CONFLICT/PT409, newer edit intact)';
end$$;

-- =====================================================================
-- T7 / T9 / T10  OFFLINE WITHOUT CONFLICT, REPEATED SYNC, PORTAL WRITER
-- =====================================================================
do $$
declare
  v_plan uuid := gen_random_uuid();
  v_n    bigint;
  v_n1   bigint;
  v_n2   bigint;
begin
  perform public._t198_login('a');
  insert into public.resistance_plans (id, vineyard_id, season_id, disease, client_updated_at)
  values (v_plan, 'd8000000-0000-0000-0000-000000000001', '2026-27', 'eutypa', now());
  select server_revision into v_n from public.resistance_plans where id = v_plan;

  -- T7: read N, go offline, edit, reconnect. Nobody else wrote. Slow clock.
  update public.resistance_plans
     set notes = 'offline edit, no conflict',
         client_updated_at = now() - interval '30 minutes',
         base_revision = v_n
   where id = v_plan;
  if not exists (select 1 from public.resistance_plans
                  where id = v_plan and notes = 'offline edit, no conflict') then
    raise exception 'T7 FAILED: an uncontested offline edit was rejected';
  end if;

  -- T9: the write advanced the marker, and a second edit based on the NEW
  -- marker succeeds. Proves the token is readable, advancing and reusable.
  select server_revision into v_n1 from public.resistance_plans where id = v_plan;
  if v_n1 <= v_n then
    raise exception 'T9 FAILED: server_revision did not advance (% -> %)', v_n, v_n1;
  end if;
  update public.resistance_plans
     set notes = 'second valid edit', client_updated_at = now(), base_revision = v_n1
   where id = v_plan;
  select server_revision into v_n2 from public.resistance_plans where id = v_plan;
  if v_n2 <= v_n1 or (select notes from public.resistance_plans where id = v_plan) <> 'second valid edit' then
    raise exception 'T9 FAILED: repeated sync broke (% -> %)', v_n1, v_n2;
  end if;
  raise notice 'T7/T9 passed (uncontested offline edit applies; revision advances and is reusable)';

  -- T10: a SERVER-TIME writer (portal / PostgREST / external API, sql/186)
  -- saves, then a slow-clock mobile edit based on the current version. This is
  -- the mixed-clock pairing the original contract could not express.
  perform set_config('role', 'postgres', true);
  update public.resistance_plans
     set notes = 'portal server-time write', client_updated_at = now()
   where id = v_plan;
  select server_revision into v_n2 from public.resistance_plans where id = v_plan;

  perform public._t198_login('b');
  update public.resistance_plans
     set notes = 'mobile after portal',
         client_updated_at = now() - interval '10 minutes',
         base_revision = v_n2
   where id = v_plan;
  if (select notes from public.resistance_plans where id = v_plan) <> 'mobile after portal' then
    raise exception 'T10 FAILED: a slow-clock mobile edit based on the current version lost to a server-time write';
  end if;
  raise notice 'T10 passed (server-time writer then slow-clock mobile edit: accepted)';
end$$;

-- =====================================================================
-- T11 / T12  LEGACY PATH: RECORDED, AND NOT MADE STICKY
-- =====================================================================
do $$
declare
  v_plan  uuid := gen_random_uuid();
  v_t0    timestamptz := now() - interval '1 minute';
  v_cnt   integer;
  v_audit jsonb;
begin
  perform public._t198_login('a');
  insert into public.resistance_plans (id, vineyard_id, season_id, disease, notes, client_updated_at)
  values (v_plan, 'd8000000-0000-0000-0000-000000000001', '2026-27', 'powdery mildew',
          'stored newer', now());

  -- An OLD client (no base_revision) replays an older edit. Still skipped, so a
  -- late replay cannot overwrite newer work — but no longer invisible.
  update public.resistance_plans
     set notes = 'legacy stale replay', client_updated_at = v_t0
   where id = v_plan;

  if (select notes from public.resistance_plans where id = v_plan) <> 'stored newer' then
    raise exception 'T11 FAILED: the legacy path let a stale replay overwrite newer data';
  end if;

  select count(*) into v_cnt from public.sync_discarded_writes
   where table_name = 'resistance_plans' and row_id = v_plan
     and reason = 'stale_client_updated_at';
  if v_cnt <> 1 then
    raise exception 'T11 FAILED: the discarded write was not recorded (% audit rows) — loss is still silent', v_cnt;
  end if;

  -- The grower's lost edit must be RECOVERABLE, not merely counted.
  select attempted_payload into v_audit from public.sync_discarded_writes
   where table_name = 'resistance_plans' and row_id = v_plan limit 1;
  if v_audit->>'notes' <> 'legacy stale replay' then
    raise exception 'T11 FAILED: the audit row does not preserve the rejected payload';
  end if;
  raise notice 'T11 passed (legacy discard is recorded with a recoverable payload)';

  -- T12: base_revision must NEVER persist. If it stuck, a later old-client
  -- upsert (which omits the column under merge-duplicates) would inherit a
  -- stale number and be refused a write that is perfectly valid. This is the
  -- hinge of old-client compatibility.
  update public.resistance_plans
     set notes = 'versioned write',
         client_updated_at = now(),
         base_revision = (select server_revision from public.resistance_plans where id = v_plan)
   where id = v_plan;

  if (select base_revision from public.resistance_plans where id = v_plan) is not null then
    raise exception 'T12 FAILED: base_revision was persisted — an old client would inherit it and be locked out';
  end if;

  -- Prove the consequence directly: an old-style write with no base_revision
  -- and a fresh timestamp still works after a versioned write.
  update public.resistance_plans
     set notes = 'old client after new client', client_updated_at = now()
   where id = v_plan;
  if (select notes from public.resistance_plans where id = v_plan) <> 'old client after new client' then
    raise exception 'T12 FAILED: an old client was broken by a preceding versioned write';
  end if;
  raise notice 'T12 passed (base_revision is transient; old clients unaffected)';
end$$;

-- =====================================================================
-- T13  THE TOKEN IS SERVER-ISSUED, NOT CLIENT-ASSERTED
-- =====================================================================
do $$
declare
  v_plan uuid := gen_random_uuid();
  v_rev  bigint;
begin
  perform public._t198_login('a');
  insert into public.resistance_plans (id, vineyard_id, season_id, disease, client_updated_at, server_revision)
  values (v_plan, 'd8000000-0000-0000-0000-000000000001', '2026-27', 'downy mildew', now(), 999999);

  select server_revision into v_rev from public.resistance_plans where id = v_plan;
  if v_rev <> 1 then
    raise exception 'T13 FAILED: a client forged server_revision on insert (stored %)', v_rev;
  end if;

  update public.resistance_plans
     set notes = 'forge attempt', client_updated_at = now(),
         server_revision = 5000, base_revision = 1
   where id = v_plan;
  select server_revision into v_rev from public.resistance_plans where id = v_plan;
  if v_rev <> 2 then
    raise exception 'T13 FAILED: a client forged server_revision on update (stored %, expected 2)', v_rev;
  end if;
  raise notice 'T13 passed (server_revision is server-issued and unforgeable)';
end$$;

-- =====================================================================
-- T14 / T15  THE PRUNING TABLES GET THE SAME CONTRACT
-- Resistance Plans safe while pruning stayed vulnerable would be the whole
-- point of the task missed.
-- =====================================================================
do $$
declare
  v_season uuid := gen_random_uuid();
  v_rev    bigint;
  v_state  text;
begin
  perform public._t198_login('a');

  insert into public.pruning_seasons (id, vineyard_id, paddock_id, season_year, client_updated_at)
  values (v_season, 'd8000000-0000-0000-0000-000000000001',
          'd8000000-0000-0000-0000-0000000000a1', 2026, now());

  select server_revision into v_rev from public.pruning_seasons where id = v_season;

  -- Slow clock, correct version -> accepted.
  update public.pruning_seasons
     set assigned_crew = 'slow clock crew',
         client_updated_at = now() - interval '10 minutes',
         base_revision = v_rev
   where id = v_season;
  if (select assigned_crew from public.pruning_seasons where id = v_season) <> 'slow clock crew' then
    raise exception 'T14 FAILED: pruning_seasons rejected a valid slow-clock edit';
  end if;

  -- Stale version -> explicit conflict.
  begin
    update public.pruning_seasons
       set assigned_crew = 'stale', client_updated_at = now(), base_revision = v_rev
     where id = v_season;
  exception when others then
    v_state := sqlstate;
  end;
  if v_state is distinct from 'PT409' then
    raise exception 'T14 FAILED: pruning_seasons stale edit gave % not PT409', coalesce(v_state,'<accepted>');
  end if;
  raise notice 'T14 passed (pruning_seasons on the same contract)';
end$$;

do $$
declare
  v_id    uuid;
  v_rev   bigint;
  v_state text;
begin
  perform public._t198_login('a');

  insert into public.pruning_yield_settings (vineyard_id, paddock_id, client_updated_at)
  values ('d8000000-0000-0000-0000-000000000001',
          'd8000000-0000-0000-0000-0000000000a2', now())
  returning id, server_revision into v_id, v_rev;

  update public.pruning_yield_settings
     set bunches_per_bud = 2.25,
         client_updated_at = now() - interval '10 minutes',
         base_revision = v_rev
   where id = v_id;
  if (select bunches_per_bud from public.pruning_yield_settings where id = v_id) <> 2.25 then
    raise exception 'T15 FAILED: pruning_yield_settings rejected a valid slow-clock edit';
  end if;

  begin
    update public.pruning_yield_settings
       set bunches_per_bud = 9.99, client_updated_at = now(), base_revision = v_rev
     where id = v_id;
  exception when others then
    v_state := sqlstate;
  end;
  if v_state is distinct from 'PT409' then
    raise exception 'T15 FAILED: pruning_yield_settings stale edit gave % not PT409', coalesce(v_state,'<accepted>');
  end if;
  raise notice 'T15 passed (pruning_yield_settings on the same contract)';
end$$;

-- =====================================================================
-- T16 / T17  NO CROSS-VINEYARD LEAK FROM THE NEW SURFACES
-- =====================================================================
do $$
declare
  v_foreign uuid := gen_random_uuid();
  v_cnt     integer;
  v_msg     text;
begin
  -- Manufacture a discarded write in a vineyard our users do NOT belong to.
  perform set_config('role', 'postgres', true);
  insert into public.resistance_plans (id, vineyard_id, season_id, disease, notes, client_updated_at)
  values (v_foreign, 'd8000000-0000-0000-0000-000000000002', '2026-27', 'botrytis',
          'foreign secret', now());
  update public.resistance_plans
     set notes = 'foreign stale attempt', client_updated_at = now() - interval '1 hour'
   where id = v_foreign;

  if not exists (select 1 from public.sync_discarded_writes where row_id = v_foreign) then
    raise exception 'T16 FAILED: precondition — the foreign discard was not recorded';
  end if;

  perform public._t198_login('a');
  select count(*) into v_cnt from public.sync_discarded_writes where row_id = v_foreign;
  if v_cnt <> 0 then
    raise exception 'T16 FAILED: a non-member can read % discarded-write row(s) from another vineyard', v_cnt;
  end if;

  -- The audit trail carries whole payloads, so a leak here would expose row
  -- data, not just metadata. Confirm the member sees only their own.
  select count(*) into v_cnt from public.sync_discarded_writes
   where vineyard_id = 'd8000000-0000-0000-0000-000000000002';
  if v_cnt <> 0 then
    raise exception 'T16 FAILED: foreign vineyard discard rows are visible';
  end if;
  raise notice 'T16 passed (sync_discarded_writes is vineyard-scoped)';

  -- T17: the conflict error itself must not disclose anything about the row or
  -- vineyard beyond the caller's own submitted revision numbers.
  perform set_config('role', 'postgres', true);
  update public.resistance_plans set notes = 'foreign secret v2', client_updated_at = now()
   where id = v_foreign;

  perform public._t198_login('a');
  begin
    update public.resistance_plans set notes = 'probe', base_revision = 1 where id = v_foreign;
    v_msg := '<no error>';
  exception when others then
    v_msg := sqlerrm;
  end;
  if v_msg like '%foreign secret%' or v_msg like '%T198 Foreign%' then
    raise exception 'T17 FAILED: the conflict error leaked row content: %', v_msg;
  end if;
  raise notice 'T17 passed (conflict signal discloses no row or vineyard content)';
end$$;

do $$
begin
  perform set_config('role', 'postgres', true);
  drop function if exists public._t198_login(text);
  raise notice 'sql/198 sync concurrency tests: ALL PASSED';
end$$;

-- ---------------- T18 discard everything ----------------
rollback;
