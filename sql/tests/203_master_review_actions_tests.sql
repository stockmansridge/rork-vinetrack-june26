-- =============================================================================
-- Tests for sql/203_master_review_actions.sql (Stage 2 R2-A)
--
-- ROLLBACK-ONLY. Nothing is committed. Run with:
--   psql "$DATABASE_URL" -f sql/tests/203_master_review_actions_tests.sql
--
-- RPC tests run as `authenticated` with RLS active and real JWT claims (the
-- sql/195/197 lesson). Fixture setup and state assertions run as postgres.
--
-- Coverage (required R2-A scenarios -> tests)
--   T1  migration in place (tables, RPCs, RLS, single SELECT-only policy each,
--       write privileges revoked for client roles)
--   T2  non-admin denial on all four RPCs + review tables invisible to
--       non-admins under RLS
--   T3  reason required on all four RPCs (empty/whitespace/null)
--   T4  preview ownership: another SYSTEM ADMIN cannot apply someone else's
--       preview (ownership binding beats admin status)
--   T5  preview/master mismatch refused
--   T6  expired preview refused
--   T7  patch-contract violation (forbidden key AND wrong value type) refused;
--       nothing written, preview not consumed
--   T8  happy apply: exact stored patch applied, revision bump, version-row
--       attribution (changed_by + change_reason), append-only action row,
--       preview consumed — all atomic
--   T9  consumed preview / idempotent double-tap -> already_applied, no second
--       write, no second action row
--   T10 revision mismatch on apply (stale stored preview), adjudicate,
--       correct and rekey
--   T11 adjudicate stored: conflict retired VERBATIM into the audit row,
--       values untouched, manual_entry source appended, status stays conflict
--       while other conflicts remain
--   T12 adjudicate superseded_by_refresh: last conflict retired, status caps
--       at partially_verified (never verified)
--   T13 authoritative -> typed_handler_missing (empty registry, fail closed);
--       registration conflict -> identity_not_adjudicable (either selection);
--       vanished conflict -> conflict_not_found; target row byte-untouched
--   T14 correct: whitelist applies + canonicalised aliases; canonical
--       correction appends manual_entry source + bumps; notes-only correction
--       bumps nothing and appends no source; authority keys refused
--   T15 rekey: duplicate identity refused; invalid identity refused;
--       approved row refused; linked row refused; happy rekey re-keys a
--       clean candidate with old/new audit
--   T16 no direct INSERT/UPDATE/DELETE on audit/previews for any client role
--       (privilege matrix + live attempts as an admin)
--   T17 saved chemicals and spray snapshots byte-untouched by every review op
--
-- Expected final line:
--   NOTICE: sql/203 master review stage-2 tests: ALL PASSED
-- =============================================================================
begin;

-- ---------------- T1 preconditions ----------------
do $$
begin
  if to_regclass('public.master_review_previews') is null then
    raise exception 'T1 FAILED: master_review_previews missing (apply sql/203 first)';
  end if;
  if to_regclass('public.master_chemical_review_actions') is null then
    raise exception 'T1 FAILED: master_chemical_review_actions missing (apply sql/203 first)';
  end if;
  if to_regprocedure('public.master_review_apply(uuid, uuid, text)') is null then
    raise exception 'T1 FAILED: master_review_apply(uuid,uuid,text) missing';
  end if;
  if to_regprocedure('public.master_review_adjudicate(uuid, integer, text, jsonb, text, text)') is null then
    raise exception 'T1 FAILED: master_review_adjudicate missing';
  end if;
  if to_regprocedure('public.master_review_correct(uuid, integer, jsonb, text)') is null then
    raise exception 'T1 FAILED: master_review_correct missing';
  end if;
  if to_regprocedure('public.master_review_rekey(uuid, integer, text, text, text, text)') is null then
    raise exception 'T1 FAILED: master_review_rekey missing';
  end if;
  if not (select relrowsecurity from pg_class where relname = 'master_review_previews') then
    raise exception 'T1 FAILED: RLS not enabled on master_review_previews';
  end if;
  if not (select relrowsecurity from pg_class where relname = 'master_chemical_review_actions') then
    raise exception 'T1 FAILED: RLS not enabled on master_chemical_review_actions';
  end if;

  -- Exactly one policy per table, and it must be SELECT-only. Any write
  -- policy on these tables is a trust-boundary breach by definition.
  if (select count(*) from pg_policies
       where schemaname = 'public' and tablename = 'master_review_previews') <> 1
     or exists (select 1 from pg_policies
                 where schemaname = 'public' and tablename = 'master_review_previews'
                   and cmd <> 'SELECT') then
    raise exception 'T1 FAILED: master_review_previews must have exactly one SELECT-only policy';
  end if;
  if (select count(*) from pg_policies
       where schemaname = 'public' and tablename = 'master_chemical_review_actions') <> 1
     or exists (select 1 from pg_policies
                 where schemaname = 'public' and tablename = 'master_chemical_review_actions'
                   and cmd <> 'SELECT') then
    raise exception 'T1 FAILED: master_chemical_review_actions must have exactly one SELECT-only policy';
  end if;

  raise notice 'T1 passed (sql/203 objects in place; SELECT-only policies)';
end$$;

-- ---------------- fixtures ----------------
do $$
declare
  u_a uuid; u_b uuid; u_n uuid;
  v_m_apply uuid; v_m_adj uuid; v_m_ident uuid;
  v_m_rekey uuid; v_m_linked uuid; v_m_approved uuid;
  c_conc jsonb := '{"field":"concentration","active_ingredient_name":"Azoxystrobin","extracted_value":"Azoxystrobin 120 g/L","authoritative_value":"Azoxystrobin 200 g/L","extracted_source":"ai_interpretation","authoritative_source":"official_register"}'::jsonb;
  c_missing jsonb := '{"field":"active_ingredients","active_ingredient_name":"Bogusamine","extracted_value":"extracted as an active ingredient","authoritative_value":"not an active constituent of this registration","extracted_source":"ai_interpretation","authoritative_source":"official_register"}'::jsonb;
  c_reg jsonb := '{"field":"registration_number","extracted_value":"80003","authoritative_value":"90003","extracted_source":"ai_interpretation","authoritative_source":"official_register"}'::jsonb;
  c_whp jsonb := '{"field":"withholding_period_days","extracted_value":"14 days","authoritative_value":"28 days - register label statements","extracted_source":"ai_interpretation","authoritative_source":"official_register"}'::jsonb;
begin
  perform set_config('role', 'postgres', true);

  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated',
     'authenticated', 't203-admin-a@test.local', 'x', now(), now(), now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated',
     'authenticated', 't203-admin-b@test.local', 'x', now(), now(), now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated',
     'authenticated', 't203-user@test.local', 'x', now(), now(), now());

  select id into u_a from auth.users where email = 't203-admin-a@test.local';
  select id into u_b from auth.users where email = 't203-admin-b@test.local';
  select id into u_n from auth.users where email = 't203-user@test.local';

  insert into public.profiles (id, email) values
    (u_a, 't203-admin-a@test.local'), (u_b, 't203-admin-b@test.local'),
    (u_n, 't203-user@test.local')
  on conflict (id) do nothing;

  -- BOTH a and b are system admins: T4 proves preview ownership binds tighter
  -- than admin status.
  insert into public.system_admins (user_id, email, is_active) values
    (u_a, 't203-admin-a@test.local', true),
    (u_b, 't203-admin-b@test.local', true);

  insert into public.vineyards (id, name)
  values ('e2030000-0000-0000-0000-000000000001', 'T203 Vineyard');

  -- Master fixtures (all v1; fixture writes carry no JWT so changed_by null).
  insert into public.master_chemicals
    (registration_country, registration_scheme, registration_number,
     registrant, registered_product_name, source_kind, review_status,
     label_version)
  values ('AU', 'apvma', '80001', 'Original Registrant Pty Ltd',
          'T203 Apply Target', 'manufacturer_label', 'candidate', 'Rev A')
  returning id into v_m_apply;

  insert into public.master_chemicals
    (registration_country, registration_scheme, registration_number,
     registrant, registered_product_name, source_kind, review_status,
     active_ingredients, verification_status, verification_sources,
     verification_conflicts)
  values ('AU', 'apvma', '80002', 'Adjudicate Registrant',
          'T203 Adjudicate Target', 'manufacturer_label', 'candidate',
          '[{"name":"Azoxystrobin","concentration":120,"concentration_unit":"g/L"}]'::jsonb,
          'conflict',
          '[{"kind":"ai_interpretation","name":"AI lookup","reference":null,"retrieved_at":"2026-08-18T00:00:00Z"}]'::jsonb,
          jsonb_build_array(c_conc, c_missing))
  returning id into v_m_adj;

  insert into public.master_chemicals
    (registration_country, registration_scheme, registration_number,
     registered_product_name, source_kind, review_status,
     verification_status, verification_conflicts)
  values ('AU', 'apvma', '80003', 'T203 Identity Conflict Target',
          'manufacturer_label', 'candidate', 'conflict',
          jsonb_build_array(c_reg, c_whp))
  returning id into v_m_ident;

  insert into public.master_chemicals
    (registration_country, registration_scheme, registration_number,
     registered_product_name, source_kind, review_status)
  values ('AU', 'apvma', '80004', 'T203 Rekey Candidate',
          'manufacturer_label', 'candidate')
  returning id into v_m_rekey;

  insert into public.master_chemicals
    (registration_country, registration_scheme, registration_number,
     registered_product_name, source_kind, review_status)
  values ('AU', 'apvma', '80005', 'T203 Rekey Linked',
          'manufacturer_label', 'candidate')
  returning id into v_m_linked;

  insert into public.master_chemicals
    (registration_country, registration_scheme, registration_number,
     registered_product_name, source_kind, review_status, reviewed_by, reviewed_at)
  values ('AU', 'apvma', '80006', 'T203 Approved Row',
          'manufacturer_label', 'approved', u_a, now())
  returning id into v_m_approved;

  -- A vineyard record links M_LINKED -> its identity is frozen (T15) and the
  -- record itself must never change (T17).
  insert into public.saved_chemicals
    (id, vineyard_id, name, master_chemical_id, master_source_revision, client_updated_at)
  values ('e2030000-0000-0000-0000-00000000c001',
          'e2030000-0000-0000-0000-000000000001',
          'T203 Linked Chemical', v_m_linked, 1, now());

  -- A historical spray snapshot that must stay byte-identical (T17).
  insert into public.spray_records (id, vineyard_id, date, tanks, client_updated_at)
  values ('e2030000-0000-0000-0000-00000000e001',
          'e2030000-0000-0000-0000-000000000001', now(),
          '[{"chemicals":[{"name":"T203 Linked Chemical","chemicalSnapshot":{"withholding_period_days":28,"verification_status":"verified"}}]}]'::jsonb,
          now());

  -- Stored previews, written exactly as the service-role edge will write them.
  -- P_OK: the real resolver-shaped patch T8 applies.
  insert into public.master_review_previews
    (id, master_chemical_id, base_revision, outcome, proposed_patch, changes, requested_by)
  values
    ('e2030000-0000-0000-0000-00000000a001', v_m_apply, 1, 'evidence_refreshed',
     '{"registrant":"Registered Registrant Pty Ltd","label_version":"Rev C 2026","retrieved_at":"2026-08-20T00:00:00Z","source_kind":"official_register","verification_status":"partially_verified","verification_sources":[{"kind":"official_register","name":"APVMA PubCRIS - T203 sync","reference":null,"retrieved_at":"2026-08-20T00:00:00Z"}],"verification_conflicts":[],"verification_unresolved_fields":["re_entry_period_hours"]}'::jsonb,
     '[{"field":"registrant","current":"Original Registrant Pty Ltd","authoritative":"Registered Registrant Pty Ltd"}]'::jsonb,
     u_a);

  -- P_EXPIRED: already past its window.
  insert into public.master_review_previews
    (id, master_chemical_id, base_revision, outcome, proposed_patch, requested_by, expires_at)
  values
    ('e2030000-0000-0000-0000-00000000a002', v_m_apply, 1, 'evidence_refreshed',
     '{"registrant":"Too Late Pty Ltd"}'::jsonb, u_a, now() - interval '1 minute');

  -- P_BADKEY: a compromised store path trying to smuggle review_status.
  insert into public.master_review_previews
    (id, master_chemical_id, base_revision, outcome, proposed_patch, requested_by)
  values
    ('e2030000-0000-0000-0000-00000000a003', v_m_apply, 1, 'evidence_refreshed',
     '{"registrant":"Sneaky Pty Ltd","review_status":"approved"}'::jsonb, u_a);

  -- P_BADTYPE: right key, wrong shape.
  insert into public.master_review_previews
    (id, master_chemical_id, base_revision, outcome, proposed_patch, requested_by)
  values
    ('e2030000-0000-0000-0000-00000000a004', v_m_apply, 1, 'material_change',
     '{"registered_uses":"not-an-array"}'::jsonb, u_a);

  -- P_STALE: reviewed at revision 1, applied only after the row moved on.
  insert into public.master_review_previews
    (id, master_chemical_id, base_revision, outcome, proposed_patch, requested_by)
  values
    ('e2030000-0000-0000-0000-00000000a005', v_m_apply, 1, 'evidence_refreshed',
     '{"label_version":"Rev D 2026"}'::jsonb, u_a);

  -- P_B: belongs to admin B.
  insert into public.master_review_previews
    (id, master_chemical_id, base_revision, outcome, proposed_patch, requested_by)
  values
    ('e2030000-0000-0000-0000-00000000a006', v_m_apply, 1, 'evidence_refreshed',
     '{"registrant":"B Applied This"}'::jsonb, u_b);

  perform set_config('vinetrack.t203_user_a', u_a::text, false);
  perform set_config('vinetrack.t203_user_b', u_b::text, false);
  perform set_config('vinetrack.t203_user_n', u_n::text, false);
  perform set_config('vinetrack.t203_m_apply',    v_m_apply::text,    false);
  perform set_config('vinetrack.t203_m_adj',      v_m_adj::text,      false);
  perform set_config('vinetrack.t203_m_ident',    v_m_ident::text,    false);
  perform set_config('vinetrack.t203_m_rekey',    v_m_rekey::text,    false);
  perform set_config('vinetrack.t203_m_linked',   v_m_linked::text,   false);
  perform set_config('vinetrack.t203_m_approved', v_m_approved::text, false);
  perform set_config('vinetrack.t203_c_conc',    c_conc::text,    false);
  perform set_config('vinetrack.t203_c_missing', c_missing::text, false);
  perform set_config('vinetrack.t203_c_reg',     c_reg::text,     false);
  perform set_config('vinetrack.t203_c_whp',     c_whp::text,     false);
end$$;

-- Helper: become one of the fixture users, with RLS enforced.
create or replace function public._t203_login(p_which text)
returns void language plpgsql as $$
declare v_uid text;
begin
  v_uid := current_setting('vinetrack.t203_user_' || p_which, true);
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end$$;

-- =====================================================================
-- T2  NON-ADMIN DENIAL — all four RPCs + RLS invisibility
-- =====================================================================
do $$
declare
  v_m_apply uuid := current_setting('vinetrack.t203_m_apply', true)::uuid;
  v_m_adj   uuid := current_setting('vinetrack.t203_m_adj',   true)::uuid;
  v_m_rekey uuid := current_setting('vinetrack.t203_m_rekey', true)::uuid;
  v_c_conc  jsonb := current_setting('vinetrack.t203_c_conc', true)::jsonb;
  v_err text;
  v_n integer;
  v_out jsonb;
begin
  perform public._t203_login('n');

  v_err := '';
  begin
    v_out := public.master_review_apply(
      'e2030000-0000-0000-0000-00000000a001', v_m_apply, 'attempt');
  exception when others then v_err := sqlerrm;
  end;
  if v_err <> 'not_authorised' then
    raise exception 'T2 FAILED: non-admin apply expected not_authorised, got "%"', v_err;
  end if;

  v_err := '';
  begin
    v_out := public.master_review_adjudicate(
      v_m_adj, 1, 'concentration', v_c_conc, 'stored', 'attempt');
  exception when others then v_err := sqlerrm;
  end;
  if v_err <> 'not_authorised' then
    raise exception 'T2 FAILED: non-admin adjudicate expected not_authorised, got "%"', v_err;
  end if;

  v_err := '';
  begin
    v_out := public.master_review_correct(
      v_m_apply, 1, '{"review_notes":"attempt"}'::jsonb, 'attempt');
  exception when others then v_err := sqlerrm;
  end;
  if v_err <> 'not_authorised' then
    raise exception 'T2 FAILED: non-admin correct expected not_authorised, got "%"', v_err;
  end if;

  v_err := '';
  begin
    v_out := public.master_review_rekey(
      v_m_rekey, 1, 'AU', 'apvma', '99999', 'attempt');
  exception when others then v_err := sqlerrm;
  end;
  if v_err <> 'not_authorised' then
    raise exception 'T2 FAILED: non-admin rekey expected not_authorised, got "%"', v_err;
  end if;

  -- Review plumbing is invisible to non-admins.
  select count(*) into v_n from public.master_review_previews;
  if v_n <> 0 then
    raise exception 'T2 FAILED: non-admin can read % stored previews', v_n;
  end if;
  select count(*) into v_n from public.master_chemical_review_actions;
  if v_n <> 0 then
    raise exception 'T2 FAILED: non-admin can read review actions';
  end if;

  raise notice 'T2 passed (non-admin denied on all RPCs; review tables invisible)';
end$$;

-- =====================================================================
-- T3  REASON REQUIRED — every decision carries a mandatory reason
-- =====================================================================
do $$
declare
  v_m_apply uuid := current_setting('vinetrack.t203_m_apply', true)::uuid;
  v_m_adj   uuid := current_setting('vinetrack.t203_m_adj',   true)::uuid;
  v_m_rekey uuid := current_setting('vinetrack.t203_m_rekey', true)::uuid;
  v_c_conc  jsonb := current_setting('vinetrack.t203_c_conc', true)::jsonb;
  v_err text;
  v_out jsonb;
begin
  perform public._t203_login('a');

  v_err := '';
  begin
    v_out := public.master_review_apply(
      'e2030000-0000-0000-0000-00000000a001', v_m_apply, '   ');
  exception when others then v_err := sqlerrm;
  end;
  if v_err <> 'reason_required' then
    raise exception 'T3 FAILED: apply with blank reason expected reason_required, got "%"', v_err;
  end if;

  v_err := '';
  begin
    v_out := public.master_review_adjudicate(
      v_m_adj, 1, 'concentration', v_c_conc, 'stored', '');
  exception when others then v_err := sqlerrm;
  end;
  if v_err <> 'reason_required' then
    raise exception 'T3 FAILED: adjudicate with empty reason expected reason_required, got "%"', v_err;
  end if;

  v_err := '';
  begin
    v_out := public.master_review_correct(
      v_m_apply, 1, '{"review_notes":"x"}'::jsonb, null);
  exception when others then v_err := sqlerrm;
  end;
  if v_err <> 'reason_required' then
    raise exception 'T3 FAILED: correct with null reason expected reason_required, got "%"', v_err;
  end if;

  v_err := '';
  begin
    v_out := public.master_review_rekey(v_m_rekey, 1, 'AU', 'apvma', '99999', ' ');
  exception when others then v_err := sqlerrm;
  end;
  if v_err <> 'reason_required' then
    raise exception 'T3 FAILED: rekey with blank reason expected reason_required, got "%"', v_err;
  end if;

  raise notice 'T3 passed (reason mandatory on all four RPCs)';
end$$;

-- =====================================================================
-- T4  PREVIEW OWNERSHIP — an admin cannot apply another admin's preview
-- =====================================================================
do $$
declare
  v_m_apply uuid := current_setting('vinetrack.t203_m_apply', true)::uuid;
  v_err text;
  v_out jsonb;
begin
  -- Admin A (a real system admin) tries admin B's preview.
  perform public._t203_login('a');
  v_err := '';
  begin
    v_out := public.master_review_apply(
      'e2030000-0000-0000-0000-00000000a006', v_m_apply, 'not mine');
  exception when others then v_err := sqlerrm;
  end;
  if v_err <> 'preview_not_yours' then
    raise exception 'T4 FAILED: expected preview_not_yours, got "%"', v_err;
  end if;

  raise notice 'T4 passed (ownership binding beats admin status)';
end$$;

-- =====================================================================
-- T5  PREVIEW / MASTER MISMATCH
-- =====================================================================
do $$
declare
  v_m_adj uuid := current_setting('vinetrack.t203_m_adj', true)::uuid;
  v_err text;
  v_out jsonb;
begin
  perform public._t203_login('a');
  v_err := '';
  begin
    v_out := public.master_review_apply(
      'e2030000-0000-0000-0000-00000000a001', v_m_adj, 'wrong master');
  exception when others then v_err := sqlerrm;
  end;
  if v_err <> 'preview_mismatch' then
    raise exception 'T5 FAILED: expected preview_mismatch, got "%"', v_err;
  end if;

  raise notice 'T5 passed (preview bound to its master row)';
end$$;

-- =====================================================================
-- T6  EXPIRED PREVIEW
-- =====================================================================
do $$
declare
  v_m_apply uuid := current_setting('vinetrack.t203_m_apply', true)::uuid;
  v_err text;
  v_out jsonb;
begin
  perform public._t203_login('a');
  v_err := '';
  begin
    v_out := public.master_review_apply(
      'e2030000-0000-0000-0000-00000000a002', v_m_apply, 'too late');
  exception when others then v_err := sqlerrm;
  end;
  if v_err <> 'preview_expired' then
    raise exception 'T6 FAILED: expected preview_expired, got "%"', v_err;
  end if;

  perform set_config('role', 'postgres', true);
  if (select registrant from public.master_chemicals where id = v_m_apply)
     <> 'Original Registrant Pty Ltd' then
    raise exception 'T6 FAILED: expired preview wrote to the master row';
  end if;

  raise notice 'T6 passed (expired preview refused, nothing written)';
end$$;

-- =====================================================================
-- T7  PATCH-CONTRACT VIOLATION — forbidden key and wrong type, atomic no-op
-- =====================================================================
do $$
declare
  v_m_apply uuid := current_setting('vinetrack.t203_m_apply', true)::uuid;
  v_err text;
  v_out jsonb;
  v_row public.master_chemicals%rowtype;
begin
  perform public._t203_login('a');

  -- Forbidden key (review_status can never travel through apply).
  v_err := '';
  begin
    v_out := public.master_review_apply(
      'e2030000-0000-0000-0000-00000000a003', v_m_apply, 'smuggle attempt');
  exception when others then v_err := sqlerrm;
  end;
  if v_err <> 'patch_contract_violation' then
    raise exception 'T7 FAILED: forbidden key expected patch_contract_violation, got "%"', v_err;
  end if;

  -- Wrong value type for a contract key.
  v_err := '';
  begin
    v_out := public.master_review_apply(
      'e2030000-0000-0000-0000-00000000a004', v_m_apply, 'bad type');
  exception when others then v_err := sqlerrm;
  end;
  if v_err <> 'patch_contract_violation' then
    raise exception 'T7 FAILED: wrong type expected patch_contract_violation, got "%"', v_err;
  end if;

  perform set_config('role', 'postgres', true);
  select * into v_row from public.master_chemicals where id = v_m_apply;
  if v_row.registrant <> 'Original Registrant Pty Ltd'
     or v_row.review_status <> 'candidate'
     or v_row.catalogue_version <> 1 then
    raise exception 'T7 FAILED: violating patch partially applied';
  end if;
  if exists (select 1 from public.master_review_previews
              where id in ('e2030000-0000-0000-0000-00000000a003',
                           'e2030000-0000-0000-0000-00000000a004')
                and consumed_at is not null) then
    raise exception 'T7 FAILED: violating previews were consumed';
  end if;
  if exists (select 1 from public.master_chemical_review_actions
              where master_chemical_id = v_m_apply) then
    raise exception 'T7 FAILED: violating apply left an action row';
  end if;

  raise notice 'T7 passed (patch contract enforced; violations are atomic no-ops)';
end$$;

-- =====================================================================
-- T8  HAPPY APPLY — server-stored patch, attribution, audit, consumption
-- =====================================================================
do $$
declare
  v_m_apply uuid := current_setting('vinetrack.t203_m_apply', true)::uuid;
  u_a uuid := current_setting('vinetrack.t203_user_a', true)::uuid;
  v_out jsonb;
  v_row public.master_chemicals%rowtype;
  v_prev public.master_review_previews%rowtype;
  v_act public.master_chemical_review_actions%rowtype;
begin
  perform public._t203_login('a');
  v_out := public.master_review_apply(
    'e2030000-0000-0000-0000-00000000a001', v_m_apply,
    'T203 refresh apply - register sync');

  if v_out->>'status' <> 'applied' then
    raise exception 'T8 FAILED: expected status applied, got %', v_out->>'status';
  end if;
  if (v_out->>'result_revision')::int <> 2 then
    raise exception 'T8 FAILED: expected result_revision 2, got %', v_out->>'result_revision';
  end if;

  perform set_config('role', 'postgres', true);
  select * into v_row from public.master_chemicals where id = v_m_apply;
  if v_row.registrant <> 'Registered Registrant Pty Ltd'
     or v_row.label_version <> 'Rev C 2026'
     or v_row.source_kind <> 'official_register'
     or v_row.verification_status <> 'partially_verified'
     or v_row.verification_unresolved_fields <> array['re_entry_period_hours']
     or v_row.catalogue_version <> 2 then
    raise exception 'T8 FAILED: stored patch was not applied exactly';
  end if;
  if v_row.review_status <> 'candidate' then
    raise exception 'T8 FAILED: apply changed review_status';
  end if;

  -- Version-row attribution: the reviewer and the mandatory reason.
  if not exists (select 1 from public.master_chemical_versions
                  where master_chemical_id = v_m_apply and catalogue_version = 2
                    and changed_by = u_a
                    and change_reason = 'T203 refresh apply - register sync') then
    raise exception 'T8 FAILED: version row missing reviewer attribution or reason';
  end if;

  -- The audit action: durable copy of the patch, actor, revisions, preview.
  select * into v_act from public.master_chemical_review_actions
   where master_chemical_id = v_m_apply and action = 'refresh_apply';
  if v_act.id is null
     or v_act.performed_by <> u_a
     or v_act.base_revision <> 1
     or v_act.result_revision <> 2
     or v_act.preview_id <> 'e2030000-0000-0000-0000-00000000a001'
     or v_act.reason <> 'T203 refresh apply - register sync'
     or (v_act.patch->>'registrant') <> 'Registered Registrant Pty Ltd' then
    raise exception 'T8 FAILED: review action row wrong or missing';
  end if;
  if v_act.id::text <> v_out->>'action_id' then
    raise exception 'T8 FAILED: returned action_id does not match the audit row';
  end if;

  -- Preview consumed and linked to the action.
  select * into v_prev from public.master_review_previews
   where id = 'e2030000-0000-0000-0000-00000000a001';
  if v_prev.consumed_at is null or v_prev.consumed_action_id <> v_act.id then
    raise exception 'T8 FAILED: preview not consumed / not linked to its action';
  end if;

  raise notice 'T8 passed (exact stored patch applied; attribution, audit and consumption atomic)';
end$$;

-- =====================================================================
-- T9  CONSUMED PREVIEW — idempotent double-tap
-- =====================================================================
do $$
declare
  v_m_apply uuid := current_setting('vinetrack.t203_m_apply', true)::uuid;
  v_out jsonb;
  v_n integer;
begin
  perform public._t203_login('a');
  v_out := public.master_review_apply(
    'e2030000-0000-0000-0000-00000000a001', v_m_apply, 'double tap');

  if v_out->>'status' <> 'already_applied' then
    raise exception 'T9 FAILED: expected already_applied, got %', v_out->>'status';
  end if;
  if (v_out->>'result_revision')::int <> 2 then
    raise exception 'T9 FAILED: replay must report the original result revision';
  end if;

  perform set_config('role', 'postgres', true);
  if (select catalogue_version from public.master_chemicals where id = v_m_apply) <> 2 then
    raise exception 'T9 FAILED: replay wrote to the master row';
  end if;
  select count(*) into v_n from public.master_chemical_review_actions
   where master_chemical_id = v_m_apply and action = 'refresh_apply';
  if v_n <> 1 then
    raise exception 'T9 FAILED: replay created a second action row (% rows)', v_n;
  end if;

  raise notice 'T9 passed (consumed preview replays as already_applied, writes nothing)';
end$$;

-- =====================================================================
-- T10 REVISION MISMATCH — apply, adjudicate, correct, rekey
-- =====================================================================
do $$
declare
  v_m_apply uuid := current_setting('vinetrack.t203_m_apply', true)::uuid;
  v_m_adj   uuid := current_setting('vinetrack.t203_m_adj',   true)::uuid;
  v_m_rekey uuid := current_setting('vinetrack.t203_m_rekey', true)::uuid;
  v_c_conc  jsonb := current_setting('vinetrack.t203_c_conc', true)::jsonb;
  v_err text;
  v_out jsonb;
begin
  perform public._t203_login('a');

  -- P_STALE was previewed at revision 1; the row is now at 2.
  v_err := '';
  begin
    v_out := public.master_review_apply(
      'e2030000-0000-0000-0000-00000000a005', v_m_apply, 'stale');
  exception when others then v_err := sqlerrm;
  end;
  if v_err <> 'revision_mismatch' then
    raise exception 'T10 FAILED: stale preview expected revision_mismatch, got "%"', v_err;
  end if;

  v_err := '';
  begin
    v_out := public.master_review_adjudicate(
      v_m_adj, 99, 'concentration', v_c_conc, 'stored', 'stale');
  exception when others then v_err := sqlerrm;
  end;
  if v_err <> 'revision_mismatch' then
    raise exception 'T10 FAILED: adjudicate expected revision_mismatch, got "%"', v_err;
  end if;

  v_err := '';
  begin
    v_out := public.master_review_correct(
      v_m_apply, 1, '{"review_notes":"stale"}'::jsonb, 'stale');
  exception when others then v_err := sqlerrm;
  end;
  if v_err <> 'revision_mismatch' then
    raise exception 'T10 FAILED: correct expected revision_mismatch, got "%"', v_err;
  end if;

  v_err := '';
  begin
    v_out := public.master_review_rekey(v_m_rekey, 99, 'AU', 'apvma', '99999', 'stale');
  exception when others then v_err := sqlerrm;
  end;
  if v_err <> 'revision_mismatch' then
    raise exception 'T10 FAILED: rekey expected revision_mismatch, got "%"', v_err;
  end if;

  raise notice 'T10 passed (CAS guards every write path)';
end$$;

-- =====================================================================
-- T11 ADJUDICATE STORED — entry retired, values untouched, status honest
-- =====================================================================
do $$
declare
  v_m_adj uuid := current_setting('vinetrack.t203_m_adj', true)::uuid;
  u_a uuid := current_setting('vinetrack.t203_user_a', true)::uuid;
  v_c_conc jsonb := current_setting('vinetrack.t203_c_conc', true)::jsonb;
  v_c_missing jsonb := current_setting('vinetrack.t203_c_missing', true)::jsonb;
  v_out jsonb;
  v_row public.master_chemicals%rowtype;
  v_act public.master_chemical_review_actions%rowtype;
begin
  perform public._t203_login('a');
  v_out := public.master_review_adjudicate(
    v_m_adj, 1, 'concentration', v_c_conc, 'stored',
    'Register mirror stale; label concentration confirmed by hand');

  if v_out->>'status' <> 'adjudicated'
     or v_out->>'verification_status' <> 'conflict'
     or (v_out->>'remaining_conflicts')::int <> 1 then
    raise exception 'T11 FAILED: unexpected adjudicate outcome %', v_out;
  end if;

  perform set_config('role', 'postgres', true);
  select * into v_row from public.master_chemicals where id = v_m_adj;
  if jsonb_array_length(v_row.verification_conflicts) <> 1
     or v_row.verification_conflicts->0 <> v_c_missing then
    raise exception 'T11 FAILED: wrong conflict retired';
  end if;
  if v_row.verification_status <> 'conflict' then
    raise exception 'T11 FAILED: status must stay conflict while conflicts remain';
  end if;
  -- The disputed VALUE is untouched — stored means stored.
  if (v_row.active_ingredients->0->>'concentration')::numeric <> 120 then
    raise exception 'T11 FAILED: adjudication mutated a chemistry value';
  end if;
  -- Human review is marked with the non-authoritative manual_entry kind.
  if (v_row.verification_sources->(jsonb_array_length(v_row.verification_sources)-1)->>'kind')
     <> 'manual_entry' then
    raise exception 'T11 FAILED: manual_entry source entry not appended';
  end if;
  if v_row.catalogue_version <> 2 then
    raise exception 'T11 FAILED: adjudication should bump the revision (got %)', v_row.catalogue_version;
  end if;

  -- Audit: the conflict verbatim, the selection, the actor, the reason.
  select * into v_act from public.master_chemical_review_actions
   where master_chemical_id = v_m_adj and action = 'adjudicate';
  if v_act.id is null
     or v_act.field <> 'concentration'
     or v_act.conflict <> v_c_conc
     or v_act.selected <> 'stored'
     or v_act.performed_by <> u_a
     or v_act.base_revision <> 1
     or v_act.result_revision <> 2 then
    raise exception 'T11 FAILED: adjudication audit row wrong or missing';
  end if;

  raise notice 'T11 passed (stored: entry retired verbatim into audit, values untouched)';
end$$;

-- =====================================================================
-- T12 ADJUDICATE SUPERSEDED_BY_REFRESH — caps at partially_verified
-- =====================================================================
do $$
declare
  v_m_adj uuid := current_setting('vinetrack.t203_m_adj', true)::uuid;
  v_c_missing jsonb := current_setting('vinetrack.t203_c_missing', true)::jsonb;
  v_out jsonb;
  v_row public.master_chemicals%rowtype;
begin
  perform public._t203_login('a');
  v_out := public.master_review_adjudicate(
    v_m_adj, 2, 'active_ingredients', v_c_missing, 'superseded_by_refresh',
    'Applied register refresh already removed the phantom active');

  if v_out->>'status' <> 'adjudicated'
     or (v_out->>'remaining_conflicts')::int <> 0 then
    raise exception 'T12 FAILED: unexpected outcome %', v_out;
  end if;
  -- Zero conflicts left; adjudication can still NEVER mint verified.
  if v_out->>'verification_status' <> 'partially_verified' then
    raise exception 'T12 FAILED: expected partially_verified cap, got %',
      v_out->>'verification_status';
  end if;

  perform set_config('role', 'postgres', true);
  select * into v_row from public.master_chemicals where id = v_m_adj;
  if v_row.verification_conflicts <> '[]'::jsonb
     or v_row.verification_status <> 'partially_verified' then
    raise exception 'T12 FAILED: row state wrong after final adjudication';
  end if;
  if not exists (select 1 from public.master_chemical_review_actions
                  where master_chemical_id = v_m_adj
                    and action = 'adjudicate' and selected = 'superseded_by_refresh') then
    raise exception 'T12 FAILED: superseded_by_refresh decision not audited';
  end if;

  raise notice 'T12 passed (superseded_by_refresh audited; status capped at partially_verified)';
end$$;

-- =====================================================================
-- T13 FAIL-CLOSED ADJUDICATIONS — typed handlers, identity, vanished conflicts
-- =====================================================================
do $$
declare
  v_m_adj   uuid := current_setting('vinetrack.t203_m_adj',   true)::uuid;
  v_m_ident uuid := current_setting('vinetrack.t203_m_ident', true)::uuid;
  v_c_conc jsonb := current_setting('vinetrack.t203_c_conc', true)::jsonb;
  v_c_reg  jsonb := current_setting('vinetrack.t203_c_reg',  true)::jsonb;
  v_c_whp  jsonb := current_setting('vinetrack.t203_c_whp',  true)::jsonb;
  v_err text;
  v_out jsonb;
  v_row public.master_chemicals%rowtype;
begin
  perform public._t203_login('a');

  -- authoritative on a non-identity conflict: the typed-handler registry is
  -- EMPTY in Stage 2, so this must fail closed.
  v_err := '';
  begin
    v_out := public.master_review_adjudicate(
      v_m_ident, 1, 'withholding_period_days', v_c_whp, 'authoritative', 'adopt register');
  exception when others then v_err := sqlerrm;
  end;
  if v_err <> 'typed_handler_missing' then
    raise exception 'T13 FAILED: authoritative expected typed_handler_missing, got "%"', v_err;
  end if;

  -- Registration identity conflicts are excluded from adjudication entirely,
  -- for EVERY selection.
  v_err := '';
  begin
    v_out := public.master_review_adjudicate(
      v_m_ident, 1, 'registration_number', v_c_reg, 'stored', 'keep ours');
  exception when others then v_err := sqlerrm;
  end;
  if v_err <> 'identity_not_adjudicable' then
    raise exception 'T13 FAILED: identity stored expected identity_not_adjudicable, got "%"', v_err;
  end if;

  v_err := '';
  begin
    v_out := public.master_review_adjudicate(
      v_m_ident, 1, 'registration_number', v_c_reg, 'authoritative', 'take register');
  exception when others then v_err := sqlerrm;
  end;
  if v_err <> 'identity_not_adjudicable' then
    raise exception 'T13 FAILED: identity authoritative expected identity_not_adjudicable, got "%"', v_err;
  end if;

  -- A conflict that no longer exists on the row (retired in T11).
  v_err := '';
  begin
    v_out := public.master_review_adjudicate(
      v_m_adj, 3, 'concentration', v_c_conc, 'stored', 'replay old decision');
  exception when others then v_err := sqlerrm;
  end;
  if v_err <> 'conflict_not_found' then
    raise exception 'T13 FAILED: vanished conflict expected conflict_not_found, got "%"', v_err;
  end if;

  -- The identity-conflict row is byte-untouched by all four refusals.
  perform set_config('role', 'postgres', true);
  select * into v_row from public.master_chemicals where id = v_m_ident;
  if jsonb_array_length(v_row.verification_conflicts) <> 2
     or v_row.verification_status <> 'conflict'
     or v_row.catalogue_version <> 1 then
    raise exception 'T13 FAILED: a refused adjudication wrote to the row';
  end if;
  if exists (select 1 from public.master_chemical_review_actions
              where master_chemical_id = v_m_ident) then
    raise exception 'T13 FAILED: a refused adjudication left an action row';
  end if;

  raise notice 'T13 passed (empty typed-handler registry fails closed; identity excluded; no partial writes)';
end$$;

-- =====================================================================
-- T14 CORRECT — whitelist, alias canonicalisation, drift-honest bumping
-- =====================================================================
do $$
declare
  v_m_apply uuid := current_setting('vinetrack.t203_m_apply', true)::uuid;
  v_err text;
  v_out jsonb;
  v_row public.master_chemicals%rowtype;
  v_sources_after_canonical integer;
begin
  perform public._t203_login('a');

  -- Canonical correction (form_type) + aliases + notes in one patch.
  v_out := public.master_review_correct(
    v_m_apply, 2,
    '{"form_type":"liquid","common_names":["T203 Apply Target","  T203 APPLY TARGET  "],"review_notes":"Checked against register"}'::jsonb,
    'Vocabulary mapping from label PDF');
  if v_out->>'status' <> 'corrected' or (v_out->>'result_revision')::int <> 3 then
    raise exception 'T14 FAILED: canonical correction should land on revision 3, got %', v_out;
  end if;

  perform set_config('role', 'postgres', true);
  select * into v_row from public.master_chemicals where id = v_m_apply;
  if v_row.form_type <> 'liquid'
     or v_row.review_notes <> 'Checked against register'
     or v_row.common_names <> array['t203 apply target'] then
    raise exception 'T14 FAILED: correction not applied / aliases not canonicalised (got %)',
      v_row.common_names;
  end if;
  -- Canonical corrections are trust-marked manual_entry.
  if (v_row.verification_sources->(jsonb_array_length(v_row.verification_sources)-1)->>'kind')
     <> 'manual_entry' then
    raise exception 'T14 FAILED: canonical correction did not append a manual_entry source';
  end if;
  v_sources_after_canonical := jsonb_array_length(v_row.verification_sources);

  -- Notes-only correction: NO revision bump, NO source entry (no false drift).
  perform public._t203_login('a');
  v_out := public.master_review_correct(
    v_m_apply, 3, '{"review_notes":"Second pass"}'::jsonb, 'Reviewer note only');
  if (v_out->>'result_revision')::int <> 3 then
    raise exception 'T14 FAILED: notes-only correction bumped the revision to %',
      v_out->>'result_revision';
  end if;

  perform set_config('role', 'postgres', true);
  select * into v_row from public.master_chemicals where id = v_m_apply;
  if v_row.catalogue_version <> 3
     or jsonb_array_length(v_row.verification_sources) <> v_sources_after_canonical then
    raise exception 'T14 FAILED: notes-only correction changed canonical state';
  end if;

  -- Authority and chemistry stay unreachable through correct().
  perform public._t203_login('a');
  v_err := '';
  begin
    v_out := public.master_review_correct(
      v_m_apply, 3, '{"verification_status":"verified"}'::jsonb, 'launder attempt');
  exception when others then v_err := sqlerrm;
  end;
  if v_err <> 'patch_contract_violation' then
    raise exception 'T14 FAILED: verification_status expected patch_contract_violation, got "%"', v_err;
  end if;

  v_err := '';
  begin
    v_out := public.master_review_correct(
      v_m_apply, 3, '{"source_kind":"official_register"}'::jsonb, 'launder attempt');
  exception when others then v_err := sqlerrm;
  end;
  if v_err <> 'patch_contract_violation' then
    raise exception 'T14 FAILED: source_kind expected patch_contract_violation, got "%"', v_err;
  end if;

  v_err := '';
  begin
    v_out := public.master_review_correct(
      v_m_apply, 3, '{"registered_uses":[]}'::jsonb, 'evidence edit attempt');
  exception when others then v_err := sqlerrm;
  end;
  if v_err <> 'patch_contract_violation' then
    raise exception 'T14 FAILED: registered_uses expected patch_contract_violation, got "%"', v_err;
  end if;

  perform set_config('role', 'postgres', true);
  if (select count(*) from public.master_chemical_review_actions
       where master_chemical_id = v_m_apply and action = 'correct') <> 2 then
    raise exception 'T14 FAILED: expected exactly 2 audited corrections';
  end if;

  raise notice 'T14 passed (whitelist corrections audited; authority unreachable; no false drift)';
end$$;

-- =====================================================================
-- T15 REKEY — duplicate/invalid/approved/linked refused; clean candidate ok
-- =====================================================================
do $$
declare
  v_m_rekey    uuid := current_setting('vinetrack.t203_m_rekey',    true)::uuid;
  v_m_linked   uuid := current_setting('vinetrack.t203_m_linked',   true)::uuid;
  v_m_approved uuid := current_setting('vinetrack.t203_m_approved', true)::uuid;
  u_a uuid := current_setting('vinetrack.t203_user_a', true)::uuid;
  v_err text;
  v_out jsonb;
  v_row public.master_chemicals%rowtype;
  v_act public.master_chemical_review_actions%rowtype;
begin
  perform public._t203_login('a');

  -- Duplicate identity (80001 belongs to the apply-target fixture).
  v_err := '';
  begin
    v_out := public.master_review_rekey(v_m_rekey, 1, 'AU', 'apvma', '80001', 'dup');
  exception when others then v_err := sqlerrm;
  end;
  if v_err <> 'identity_exists' then
    raise exception 'T15 FAILED: duplicate identity expected identity_exists, got "%"', v_err;
  end if;

  -- Invalid identity inputs.
  v_err := '';
  begin
    v_out := public.master_review_rekey(v_m_rekey, 1, 'au', 'apvma', '80104', 'bad country');
  exception when others then v_err := sqlerrm;
  end;
  if v_err <> 'invalid_identity' then
    raise exception 'T15 FAILED: lowercase country expected invalid_identity, got "%"', v_err;
  end if;
  v_err := '';
  begin
    v_out := public.master_review_rekey(v_m_rekey, 1, 'AU', 'bogus', '80104', 'bad scheme');
  exception when others then v_err := sqlerrm;
  end;
  if v_err <> 'invalid_identity' then
    raise exception 'T15 FAILED: unknown scheme expected invalid_identity, got "%"', v_err;
  end if;

  -- Approved rows: identity immutable.
  v_err := '';
  begin
    v_out := public.master_review_rekey(v_m_approved, 1, 'AU', 'apvma', '80106', 'try');
  exception when others then v_err := sqlerrm;
  end;
  if v_err <> 'rekey_not_candidate' then
    raise exception 'T15 FAILED: approved rekey expected rekey_not_candidate, got "%"', v_err;
  end if;

  -- Linked rows: never silently re-pointed.
  v_err := '';
  begin
    v_out := public.master_review_rekey(v_m_linked, 1, 'AU', 'apvma', '80107', 'try');
  exception when others then v_err := sqlerrm;
  end;
  if v_err <> 'rekey_linked' then
    raise exception 'T15 FAILED: linked rekey expected rekey_linked, got "%"', v_err;
  end if;

  -- Clean candidate: the one legitimate path.
  v_out := public.master_review_rekey(
    v_m_rekey, 1, 'AU', 'apvma', '80104', 'Transposed digits in original enqueue');
  if v_out->>'status' <> 'rekeyed'
     or v_out->>'new_identity_key' <> 'AU:apvma:80104' then
    raise exception 'T15 FAILED: happy rekey wrong outcome %', v_out;
  end if;

  perform set_config('role', 'postgres', true);
  select * into v_row from public.master_chemicals where id = v_m_rekey;
  if v_row.registration_identity_key <> 'AU:apvma:80104'
     or v_row.catalogue_version <> 2 then
    raise exception 'T15 FAILED: rekey did not land (key %, rev %)',
      v_row.registration_identity_key, v_row.catalogue_version;
  end if;
  select * into v_act from public.master_chemical_review_actions
   where master_chemical_id = v_m_rekey and action = 'rekey';
  if v_act.id is null
     or v_act.performed_by <> u_a
     or v_act.patch->'old'->>'registration_identity_key' <> 'AU:apvma:80004'
     or v_act.patch->'new'->>'registration_identity_key' <> 'AU:apvma:80104' then
    raise exception 'T15 FAILED: rekey audit row wrong or missing';
  end if;

  raise notice 'T15 passed (identity gates enforced; clean rekey audited old->new)';
end$$;

-- =====================================================================
-- T16 APPEND-ONLY BY CONSTRUCTION — privilege matrix + live attempts
-- =====================================================================
do $$
declare
  v_m_apply uuid := current_setting('vinetrack.t203_m_apply', true)::uuid;
  u_a uuid := current_setting('vinetrack.t203_user_a', true)::uuid;
  v_caught boolean;
begin
  perform set_config('role', 'postgres', true);

  -- authenticated: SELECT only, on both tables.
  if not has_table_privilege('authenticated', 'public.master_review_previews', 'SELECT')
     or has_table_privilege('authenticated', 'public.master_review_previews', 'INSERT')
     or has_table_privilege('authenticated', 'public.master_review_previews', 'UPDATE')
     or has_table_privilege('authenticated', 'public.master_review_previews', 'DELETE') then
    raise exception 'T16 FAILED: authenticated privileges wrong on previews';
  end if;
  if not has_table_privilege('authenticated', 'public.master_chemical_review_actions', 'SELECT')
     or has_table_privilege('authenticated', 'public.master_chemical_review_actions', 'INSERT')
     or has_table_privilege('authenticated', 'public.master_chemical_review_actions', 'UPDATE')
     or has_table_privilege('authenticated', 'public.master_chemical_review_actions', 'DELETE') then
    raise exception 'T16 FAILED: authenticated privileges wrong on review actions';
  end if;

  -- service_role: store/purge previews but NEVER update (consumption is
  -- RPC-only); review actions are read-only even for the edge.
  if not has_table_privilege('service_role', 'public.master_review_previews', 'INSERT')
     or not has_table_privilege('service_role', 'public.master_review_previews', 'DELETE')
     or has_table_privilege('service_role', 'public.master_review_previews', 'UPDATE') then
    raise exception 'T16 FAILED: service_role privileges wrong on previews';
  end if;
  if has_table_privilege('service_role', 'public.master_chemical_review_actions', 'INSERT')
     or has_table_privilege('service_role', 'public.master_chemical_review_actions', 'UPDATE')
     or has_table_privilege('service_role', 'public.master_chemical_review_actions', 'DELETE') then
    raise exception 'T16 FAILED: service_role must not write review actions';
  end if;

  -- anon: nothing at all.
  if has_table_privilege('anon', 'public.master_review_previews', 'SELECT')
     or has_table_privilege('anon', 'public.master_chemical_review_actions', 'SELECT') then
    raise exception 'T16 FAILED: anon can read review plumbing';
  end if;

  -- Live attempts as a SYSTEM ADMIN (the strongest client): every direct
  -- write must die at the privilege layer.
  perform public._t203_login('a');

  v_caught := false;
  begin
    update public.master_chemical_review_actions set reason = 'tampered';
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then
    raise exception 'T16 FAILED: admin directly updated the review audit';
  end if;

  v_caught := false;
  begin
    delete from public.master_chemical_review_actions;
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then
    raise exception 'T16 FAILED: admin directly deleted review audit rows';
  end if;

  v_caught := false;
  begin
    insert into public.master_chemical_review_actions
      (master_chemical_id, action, base_revision, reason, performed_by)
    values (v_m_apply, 'correct', 1, 'forged', u_a);
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then
    raise exception 'T16 FAILED: admin directly inserted a review action';
  end if;

  v_caught := false;
  begin
    update public.master_review_previews set consumed_at = null;
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then
    raise exception 'T16 FAILED: admin directly un-consumed a preview';
  end if;

  v_caught := false;
  begin
    delete from public.master_review_previews;
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then
    raise exception 'T16 FAILED: admin directly deleted previews';
  end if;

  v_caught := false;
  begin
    insert into public.master_review_previews
      (master_chemical_id, base_revision, outcome, proposed_patch, requested_by)
    values (v_m_apply, 3, 'evidence_refreshed', '{"source_kind":"official_register"}'::jsonb, u_a);
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then
    raise exception 'T16 FAILED: admin forged a stored preview — trust boundary breached';
  end if;

  raise notice 'T16 passed (append-only audit; previews unwritable by every client role)';
end$$;

-- =====================================================================
-- T17 SAVED CHEMICALS + SPRAY SNAPSHOTS UNTOUCHED BY EVERY REVIEW OP
-- =====================================================================
do $$
declare
  v_m_linked uuid := current_setting('vinetrack.t203_m_linked', true)::uuid;
  v_saved record;
begin
  perform set_config('role', 'postgres', true);

  select * into v_saved from public.saved_chemicals
   where id = 'e2030000-0000-0000-0000-00000000c001';
  if v_saved.name <> 'T203 Linked Chemical'
     or v_saved.master_chemical_id is distinct from v_m_linked
     or v_saved.master_source_revision <> 1 then
    raise exception 'T17 FAILED: a review operation touched a vineyard saved chemical';
  end if;

  if (select tanks from public.spray_records
       where id = 'e2030000-0000-0000-0000-00000000e001')
     <> '[{"chemicals":[{"name":"T203 Linked Chemical","chemicalSnapshot":{"withholding_period_days":28,"verification_status":"verified"}}]}]'::jsonb then
    raise exception 'T17 FAILED: a review operation touched a historical spray snapshot';
  end if;

  if (select catalogue_version from public.master_chemicals where id = v_m_linked) <> 1 then
    raise exception 'T17 FAILED: the linked master row changed without any review decision';
  end if;

  raise notice 'T17 passed (vineyard records and spray history immune)';
end$$;

do $$ begin
  raise notice 'sql/203 master review stage-2 tests: ALL PASSED';
end $$;

rollback;
