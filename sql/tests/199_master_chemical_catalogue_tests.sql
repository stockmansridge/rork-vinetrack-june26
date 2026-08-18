-- =============================================================================
-- Tests for sql/199_master_chemical_catalogue.sql
--
-- ROLLBACK-ONLY. Nothing is committed. Run with:
--   psql "$DATABASE_URL" -f sql/tests/199_master_chemical_catalogue_tests.sql
--
-- Write/read tests run as `authenticated` with RLS ACTIVE (the sql/195/197
-- lesson: owner-role tests cannot see RLS-dependent defects). Constraint-level
-- tests run as postgres because constraints must hold even for admins.
--
-- Coverage
--   T1  migration in place (tables, identity column, triggers, RLS, policies,
--       saved_chemicals link columns, Custodia seed present as CANDIDATE)
--   T2  registration identity uniqueness (dup, whitespace dup, case rules,
--       Forte 91636 distinct, AU vs GB same-number distinct)
--   T3  lifecycle vocabulary + THE approval gate (ai_interpretation rows can
--       never be approved; manufacturer_label rows can)
--   T4  server-managed revision: content bumps, review-only edits do not,
--       client-supplied versions are ignored (no forgery), history appends
--   T5  RLS reads: normal user sees approved only (candidate + retired
--       invisible); admin sees everything
--   T6  RLS writes: normal user cannot insert/update/delete master rows;
--       admin can, and admin updates write history (SECURITY DEFINER path)
--   T7  version history is admin-only, and not writable by normal users
--   T8  saved_chemicals link: valid link OK, bogus FK rejected, unlinked
--       (old-client shape) rows stay valid
--   T9  master revision moves on -> saved chemical NOT rewritten, drift
--       detectable (master_source_revision < catalogue_version)
--   T10 vineyard-only edits (price/stock) touch neither master nor link
--   T11 historical spray snapshot immune to master + saved-chemical updates
--   T12 cross-vineyard isolation + a referenced master row cannot be deleted
--   T13 rollback
--
-- Expected final line:
--   NOTICE: sql/199 master chemical catalogue tests: ALL PASSED
-- =============================================================================
begin;

-- ---------------- T1 preconditions ----------------
do $$
declare
  v_seed record;
begin
  if to_regclass('public.master_chemicals') is null then
    raise exception 'T1 FAILED: master_chemicals missing (sql/199 not applied)';
  end if;
  if to_regclass('public.master_chemical_versions') is null then
    raise exception 'T1 FAILED: master_chemical_versions missing';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='master_chemicals'
                    and column_name='registration_identity_key' and is_generated='ALWAYS') then
    raise exception 'T1 FAILED: registration_identity_key must be a generated column';
  end if;
  if not exists (select 1 from pg_constraint
                  where conname='master_chemicals_identity_unique') then
    raise exception 'T1 FAILED: identity unique constraint missing';
  end if;
  if not exists (select 1 from pg_constraint
                  where conname='master_chemicals_approved_provenance_check') then
    raise exception 'T1 FAILED: approved-provenance CHECK missing';
  end if;
  if (select count(*) from pg_trigger g join pg_class c on c.oid=g.tgrelid
       where c.relname='master_chemicals' and not g.tgisinternal
         and g.tgname in ('t10_master_before_write','t20_master_record_version')) <> 2 then
    raise exception 'T1 FAILED: revision/history triggers not attached';
  end if;
  if not (select relrowsecurity from pg_class where relname='master_chemicals') then
    raise exception 'T1 FAILED: RLS not enabled on master_chemicals';
  end if;
  if not (select relrowsecurity from pg_class where relname='master_chemical_versions') then
    raise exception 'T1 FAILED: RLS not enabled on master_chemical_versions';
  end if;
  if (select count(*) from pg_policies
       where schemaname='public' and tablename='master_chemicals') < 2 then
    raise exception 'T1 FAILED: master_chemicals policies missing';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='saved_chemicals'
                    and column_name='master_chemical_id') then
    raise exception 'T1 FAILED: saved_chemicals.master_chemical_id missing';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='saved_chemicals'
                    and column_name='master_source_revision') then
    raise exception 'T1 FAILED: saved_chemicals.master_source_revision missing';
  end if;

  -- The audited Custodia fixture must be seeded, as a CANDIDATE, at version 1,
  -- with its version-1 history row already recorded by the trigger.
  select * into v_seed from public.master_chemicals
   where registration_identity_key = 'AU:apvma:66541';
  if v_seed.id is null then
    raise exception 'T1 FAILED: Custodia seed (AU:apvma:66541) missing';
  end if;
  if v_seed.review_status <> 'candidate' then
    raise exception 'T1 FAILED: Custodia seed must be a candidate (PubCRIS currency unconfirmed), got %', v_seed.review_status;
  end if;
  if v_seed.catalogue_version <> 1 then
    raise exception 'T1 FAILED: seed catalogue_version expected 1, got %', v_seed.catalogue_version;
  end if;
  if v_seed.registered_product_name <> 'Custodia 320 SC'
     or v_seed.registrant <> 'Adama Australia Pty Ltd' then
    raise exception 'T1 FAILED: seed identity naming wrong';
  end if;
  if jsonb_array_length(v_seed.active_ingredients) <> 2 then
    raise exception 'T1 FAILED: seed must carry exactly two actives';
  end if;
  if v_seed.activity_groups <> array['3','11'] then
    raise exception 'T1 FAILED: seed activity_groups expected {3,11}, got %', v_seed.activity_groups;
  end if;
  if v_seed.verification_status <> 'partially_verified' then
    raise exception 'T1 FAILED: seed verification_status expected partially_verified';
  end if;
  if not ('re_entry_period_hours' = any(v_seed.verification_unresolved_fields)) then
    raise exception 'T1 FAILED: seed must keep re_entry_period_hours unresolved (never invented)';
  end if;
  if not exists (select 1 from public.master_chemical_versions
                  where master_chemical_id = v_seed.id and catalogue_version = 1) then
    raise exception 'T1 FAILED: seed version-1 history row missing';
  end if;

  raise notice 'T1 passed (sql/199 in place; Custodia seeded as candidate with v1 history)';
end$$;

-- ---------------- fixtures ----------------
do $$
declare
  u_a uuid; u_b uuid; u_adm uuid;
  v_master uuid;
begin
  perform set_config('role', 'postgres', true);

  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated',
     'authenticated', 't199-member@test.local', 'x', now(), now(), now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated',
     'authenticated', 't199-outsider@test.local', 'x', now(), now(), now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated',
     'authenticated', 't199-admin@test.local', 'x', now(), now(), now());

  select id into u_a   from auth.users where email = 't199-member@test.local';
  select id into u_b   from auth.users where email = 't199-outsider@test.local';
  select id into u_adm from auth.users where email = 't199-admin@test.local';

  insert into public.profiles (id, email) values
    (u_a, 't199-member@test.local'), (u_b, 't199-outsider@test.local'),
    (u_adm, 't199-admin@test.local')
  on conflict (id) do nothing;

  insert into public.vineyards (id, name) values
    ('d9990000-0000-0000-0000-000000000001', 'T199 Home');

  insert into public.vineyard_members (vineyard_id, user_id, role) values
    ('d9990000-0000-0000-0000-000000000001', u_a, 'manager');

  insert into public.system_admins (user_id, email, is_active)
  values (u_adm, 't199-admin@test.local', true);

  -- One APPROVED master fixture, created with register/label provenance, that
  -- the RLS + linking tests read. (Rolled back with everything else.)
  insert into public.master_chemicals (
    registration_country, registration_scheme, registration_number,
    registrant, registered_product_name, common_names,
    product_category, form_type,
    active_ingredients, activity_groups, activity_group_scheme,
    registered_uses, label_rate_bases,
    verification_status, verification_sources, verification_unresolved_fields,
    verified_at, source_kind, retrieved_at, review_status, reviewed_by, reviewed_at
  ) values (
    'AU', 'apvma', '90001',
    'T199 Registrant Pty Ltd', 'T199 Shield 500 SC', array['t199 shield'],
    'fungicide', 'liquid',
    '[{"name":"Azoxystrobin","concentration":500,"concentration_unit":"g/L",
       "activity_group":{"scheme":"frac","code":"11","common_name":"QoI / Strobilurin"},
       "group_source":"authoritative_classification","identity_source":"manufacturer_label"}]'::jsonb,
    array['11'], 'frac',
    '[{"crop":"Grapevines","target":"powdery_mildew","target_raw":"Powdery mildew",
       "rates":[{"label":"Standard","basis":"per_hectare","value":0.5,"unit":"L"}],
       "withholding_period_days":14,"restrictions":null}]'::jsonb,
    array['per_hectare'],
    'verified',
    '[{"kind":"manufacturer_label","name":"T199 label","reference":null,"retrieved_at":"2026-08-18T00:00:00Z"}]'::jsonb,
    '{}',
    '2026-08-18T00:00:00Z', 'manufacturer_label', '2026-08-18T00:00:00Z',
    'approved', u_adm, now()
  ) returning id into v_master;

  perform set_config('vinetrack.t199_user_a',   u_a::text,     false);
  perform set_config('vinetrack.t199_user_b',   u_b::text,     false);
  perform set_config('vinetrack.t199_user_adm', u_adm::text,   false);
  perform set_config('vinetrack.t199_master',   v_master::text, false);
end$$;

-- Helper: become one of the fixture users, with RLS enforced.
create or replace function public._t199_login(p_which text)
returns void language plpgsql as $$
declare v_uid text;
begin
  v_uid := current_setting('vinetrack.t199_user_' || p_which, true);
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end$$;

-- =====================================================================
-- T2  REGISTRATION IDENTITY UNIQUENESS
-- =====================================================================
do $$
declare
  v_caught boolean;
begin
  perform set_config('role', 'postgres', true);

  -- Exact duplicate of the seeded Custodia identity.
  v_caught := false;
  begin
    insert into public.master_chemicals
      (registration_country, registration_scheme, registration_number, registered_product_name)
    values ('AU', 'apvma', '66541', 'Custodia clone');
  exception when unique_violation then v_caught := true;
  end;
  if not v_caught then
    raise exception 'T2 FAILED: duplicate AU:apvma:66541 was accepted — two approved-track rows for one registration';
  end if;

  -- Whitespace / case games on the number must hit the SAME identity.
  v_caught := false;
  begin
    insert into public.master_chemicals
      (registration_country, registration_scheme, registration_number, registered_product_name)
    values ('AU', 'apvma', '  66541  ', 'Custodia padded clone');
  exception when unique_violation then v_caught := true;
  end;
  if not v_caught then
    raise exception 'T2 FAILED: padded registration number bypassed identity uniqueness';
  end if;

  -- Country must be canonical ISO-2 uppercase — no 'au' side-channel identity.
  v_caught := false;
  begin
    insert into public.master_chemicals
      (registration_country, registration_scheme, registration_number, registered_product_name)
    values ('au', 'apvma', '66541', 'Custodia lowercase country');
  exception when check_violation then v_caught := true;
  end;
  if not v_caught then
    raise exception 'T2 FAILED: lowercase country accepted (identity canonicalisation hole)';
  end if;

  -- Custodia FORTE is a different registration — must insert cleanly.
  insert into public.master_chemicals
    (registration_country, registration_scheme, registration_number,
     registrant, registered_product_name, common_names)
  values ('AU', 'apvma', '91636', 'Adama Australia Pty Ltd', 'Custodia Forte',
          array['custodia forte']);

  -- The same NUMBER in another country is a different product identity.
  insert into public.master_chemicals
    (registration_country, registration_scheme, registration_number, registered_product_name)
  values ('GB', 'other', '16393', 'Custodia (UK)');
  insert into public.master_chemicals
    (registration_country, registration_scheme, registration_number, registered_product_name)
  values ('AU', 'other', '16393', 'T199 same-number different-country');

  raise notice 'T2 passed (identity unique; Forte + cross-country identities distinct)';
end$$;

-- =====================================================================
-- T3  LIFECYCLE VOCABULARY + APPROVAL PROVENANCE GATE
-- =====================================================================
do $$
declare
  v_caught boolean;
  v_ai uuid;
begin
  perform set_config('role', 'postgres', true);

  v_caught := false;
  begin
    insert into public.master_chemicals
      (registration_country, registration_scheme, registration_number,
       registered_product_name, review_status)
    values ('AU', 'apvma', '90002', 'T199 bogus status', 'published');
  exception when check_violation then v_caught := true;
  end;
  if not v_caught then
    raise exception 'T3 FAILED: unknown review_status accepted';
  end if;

  -- An AI-sourced candidate exists...
  insert into public.master_chemicals
    (registration_country, registration_scheme, registration_number,
     registered_product_name, source_kind, review_status)
  values ('AU', 'apvma', '90003', 'T199 AI candidate', 'ai_interpretation', 'candidate')
  returning id into v_ai;

  -- ...and can NEVER be approved while its only provenance is the AI.
  v_caught := false;
  begin
    update public.master_chemicals set review_status = 'approved' where id = v_ai;
  exception when check_violation then v_caught := true;
  end;
  if not v_caught then
    raise exception 'T3 FAILED: ai_interpretation row was approved — AI output laundered into authority';
  end if;

  -- With register/label provenance recorded, approval is possible.
  update public.master_chemicals
     set source_kind = 'manufacturer_label', review_status = 'approved'
   where id = v_ai;
  if (select review_status from public.master_chemicals where id = v_ai) <> 'approved' then
    raise exception 'T3 FAILED: label-backed approval did not stick';
  end if;

  -- Retire works and is terminal-but-kept.
  update public.master_chemicals set review_status = 'retired' where id = v_ai;
  if not exists (select 1 from public.master_chemicals where id = v_ai and review_status='retired') then
    raise exception 'T3 FAILED: retirement lost the row';
  end if;

  raise notice 'T3 passed (lifecycle vocabulary enforced; AI can never be approved)';
end$$;

-- =====================================================================
-- T4  SERVER-MANAGED REVISION + APPEND-ONLY HISTORY
-- =====================================================================
do $$
declare
  v_id uuid;
  v_ver integer;
  v_hist integer;
begin
  perform set_config('role', 'postgres', true);

  insert into public.master_chemicals
    (registration_country, registration_scheme, registration_number,
     registrant, registered_product_name, source_kind)
  values ('NZ', 'acvm', 'T199-REV', 'Original Registrant', 'T199 Revision Probe',
          'manufacturer_label')
  returning id into v_id;

  select catalogue_version into v_ver from public.master_chemicals where id = v_id;
  if v_ver <> 1 then
    raise exception 'T4 FAILED: new row should start at catalogue_version 1, got %', v_ver;
  end if;
  select count(*) into v_hist from public.master_chemical_versions where master_chemical_id = v_id;
  if v_hist <> 1 then
    raise exception 'T4 FAILED: insert should record history v1 (got % rows)', v_hist;
  end if;

  -- Canonical content change -> bump + history.
  update public.master_chemicals set registrant = 'Corrected Registrant' where id = v_id;
  select catalogue_version into v_ver from public.master_chemicals where id = v_id;
  if v_ver <> 2 then
    raise exception 'T4 FAILED: content change should bump to 2, got %', v_ver;
  end if;
  if not exists (select 1 from public.master_chemical_versions
                  where master_chemical_id = v_id and catalogue_version = 2
                    and snapshot->>'registrant' = 'Corrected Registrant') then
    raise exception 'T4 FAILED: v2 history snapshot missing or wrong';
  end if;
  if not exists (select 1 from public.master_chemical_versions
                  where master_chemical_id = v_id and catalogue_version = 1
                    and snapshot->>'registrant' = 'Original Registrant') then
    raise exception 'T4 FAILED: v1 history was rewritten — history must be append-only';
  end if;

  -- Review-only change -> NO bump, NO history.
  update public.master_chemicals set review_notes = 'checked' where id = v_id;
  select catalogue_version into v_ver from public.master_chemicals where id = v_id;
  if v_ver <> 2 then
    raise exception 'T4 FAILED: review-notes edit bumped the revision (got %)', v_ver;
  end if;

  -- Forged client version WITHOUT content change is ignored.
  update public.master_chemicals set catalogue_version = 99 where id = v_id;
  select catalogue_version into v_ver from public.master_chemicals where id = v_id;
  if v_ver <> 2 then
    raise exception 'T4 FAILED: client forged catalogue_version to % without content change', v_ver;
  end if;

  -- Forged client version WITH content change still lands on old+1.
  update public.master_chemicals
     set catalogue_version = 99, label_version = 'Rev B 2026'
   where id = v_id;
  select catalogue_version into v_ver from public.master_chemicals where id = v_id;
  if v_ver <> 3 then
    raise exception 'T4 FAILED: content change with forged version should land on 3, got %', v_ver;
  end if;
  select count(*) into v_hist from public.master_chemical_versions where master_chemical_id = v_id;
  if v_hist <> 3 then
    raise exception 'T4 FAILED: expected 3 history rows, got %', v_hist;
  end if;

  raise notice 'T4 passed (server-managed revision; forgery ignored; append-only history)';
end$$;

-- =====================================================================
-- T5  RLS READS — approved only for normal users; admin sees all
-- =====================================================================
do $$
declare
  v_n integer;
begin
  -- A retired row exists (from T3) and the Custodia candidate is seeded.
  perform public._t199_login('a');

  select count(*) into v_n from public.master_chemicals
   where registration_identity_key = 'AU:apvma:90001';
  if v_n <> 1 then
    raise exception 'T5 FAILED: member cannot read an APPROVED master product';
  end if;

  select count(*) into v_n from public.master_chemicals
   where registration_identity_key = 'AU:apvma:66541';
  if v_n <> 0 then
    raise exception 'T5 FAILED: CANDIDATE (Custodia seed) is visible to a normal user — candidate isolation broken';
  end if;

  select count(*) into v_n from public.master_chemicals
   where registration_identity_key = 'AU:apvma:90003';
  if v_n <> 0 then
    raise exception 'T5 FAILED: RETIRED row visible to a normal user';
  end if;

  perform public._t199_login('adm');
  select count(*) into v_n from public.master_chemicals
   where registration_identity_key in ('AU:apvma:66541','AU:apvma:90001','AU:apvma:90003');
  if v_n <> 3 then
    raise exception 'T5 FAILED: admin should see candidate + approved + retired (saw %)', v_n;
  end if;

  raise notice 'T5 passed (approved-only reads; candidates/retired invisible; admin sees all)';
end$$;

-- =====================================================================
-- T6  RLS WRITES — normal users never alter the catalogue; admins do,
--     and admin updates record history through RLS (SECURITY DEFINER)
-- =====================================================================
do $$
declare
  v_caught boolean;
  v_master uuid := current_setting('vinetrack.t199_master', true)::uuid;
  v_ver integer;
  v_hist integer;
begin
  perform public._t199_login('a');

  v_caught := false;
  begin
    insert into public.master_chemicals
      (registration_country, registration_scheme, registration_number, registered_product_name)
    values ('AU', 'apvma', '90050', 'T199 member insert');
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then
    raise exception 'T6 FAILED: a normal vineyard user inserted a master row';
  end if;

  update public.master_chemicals set registrant = 'HACKED' where id = v_master;
  perform public._t199_login('adm');
  if exists (select 1 from public.master_chemicals where id = v_master and registrant = 'HACKED') then
    raise exception 'T6 FAILED: a normal vineyard user modified a master row';
  end if;

  perform public._t199_login('a');
  delete from public.master_chemicals where id = v_master;
  perform public._t199_login('adm');
  if not exists (select 1 from public.master_chemicals where id = v_master) then
    raise exception 'T6 FAILED: a normal vineyard user deleted a master row';
  end if;

  -- Admin content update under RLS: bumps revision AND records history
  -- (the SECURITY DEFINER trigger path real admin sessions will use).
  select catalogue_version into v_ver from public.master_chemicals where id = v_master;
  update public.master_chemicals
     set label_version = 'T199 admin correction'
   where id = v_master;
  if (select catalogue_version from public.master_chemicals where id = v_master) <> v_ver + 1 then
    raise exception 'T6 FAILED: admin content update did not bump the revision';
  end if;
  select count(*) into v_hist from public.master_chemical_versions
   where master_chemical_id = v_master and catalogue_version = v_ver + 1;
  if v_hist <> 1 then
    raise exception 'T6 FAILED: admin update did not record history under RLS';
  end if;

  insert into public.master_chemicals
    (registration_country, registration_scheme, registration_number,
     registered_product_name, source_kind, review_status)
  values ('AU', 'apvma', '90051', 'T199 admin draft', 'manual_entry', 'candidate');

  raise notice 'T6 passed (catalogue writes are admin-only; admin history recorded under RLS)';
end$$;

-- =====================================================================
-- T7  VERSION HISTORY IS ADMIN-ONLY
-- =====================================================================
do $$
declare
  v_n integer;
  v_caught boolean;
  v_master uuid := current_setting('vinetrack.t199_master', true)::uuid;
begin
  perform public._t199_login('a');
  select count(*) into v_n from public.master_chemical_versions;
  if v_n <> 0 then
    raise exception 'T7 FAILED: normal user can read master version history (% rows)', v_n;
  end if;

  v_caught := false;
  begin
    insert into public.master_chemical_versions (master_chemical_id, catalogue_version, snapshot)
    values (v_master, 999, '{}'::jsonb);
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then
    raise exception 'T7 FAILED: normal user wrote master version history';
  end if;

  perform public._t199_login('adm');
  select count(*) into v_n from public.master_chemical_versions where master_chemical_id = v_master;
  if v_n < 2 then
    raise exception 'T7 FAILED: admin should see the master''s history rows';
  end if;

  raise notice 'T7 passed (version history admin-only)';
end$$;

-- =====================================================================
-- T8  SAVED CHEMICAL LINK — valid link, FK integrity, old clients
-- =====================================================================
do $$
declare
  v_master uuid := current_setting('vinetrack.t199_master', true)::uuid;
  v_caught boolean;
  v_rev integer;
begin
  perform public._t199_login('a');

  -- Link a vineyard record to the approved master at its current revision,
  -- exactly as "create Saved Chemical from Master" will.
  insert into public.saved_chemicals
    (id, vineyard_id, name, active_ingredient, chemical_group,
     registration_country, registration_scheme, registration_number,
     master_chemical_id, master_source_revision, client_updated_at)
  select 'd9990000-0000-0000-0000-00000000c001', 'd9990000-0000-0000-0000-000000000001',
         'T199 Shield 500 SC', 'Azoxystrobin 500 g/L', '11',
         'AU', 'apvma', '90001',
         mc.id, mc.catalogue_version, now()
    from public.master_chemicals mc where mc.id = v_master;

  select master_source_revision into v_rev from public.saved_chemicals
   where id = 'd9990000-0000-0000-0000-00000000c001';
  if v_rev is null then
    raise exception 'T8 FAILED: master_source_revision was not stored';
  end if;

  -- A link must point at a real master row.
  v_caught := false;
  begin
    insert into public.saved_chemicals
      (id, vineyard_id, name, master_chemical_id, master_source_revision, client_updated_at)
    values ('d9990000-0000-0000-0000-00000000c002', 'd9990000-0000-0000-0000-000000000001',
            'T199 dangling link', gen_random_uuid(), 1, now());
  exception when foreign_key_violation then v_caught := true;
  end;
  if not v_caught then
    raise exception 'T8 FAILED: saved chemical accepted a dangling master link';
  end if;

  -- Old-client shape: no master columns at all. Must stay perfectly valid.
  insert into public.saved_chemicals (id, vineyard_id, name, client_updated_at)
  values ('d9990000-0000-0000-0000-00000000c003', 'd9990000-0000-0000-0000-000000000001',
          'T199 legacy unlinked', now());
  if (select master_chemical_id from public.saved_chemicals
       where id = 'd9990000-0000-0000-0000-00000000c003') is not null then
    raise exception 'T8 FAILED: unlinked row grew a master link from nowhere';
  end if;

  raise notice 'T8 passed (link stored with revision; FK enforced; old clients unaffected)';
end$$;

-- =====================================================================
-- T9  MASTER MOVES ON -> SAVED CHEMICAL UNCHANGED, DRIFT DETECTABLE
-- =====================================================================
do $$
declare
  v_master uuid := current_setting('vinetrack.t199_master', true)::uuid;
  v_master_ver integer;
  v_saved record;
begin
  -- Admin corrects the master product (a label correction).
  perform public._t199_login('adm');
  update public.master_chemicals
     set active_ingredients = jsonb_set(active_ingredients, '{0,concentration}', '480'::jsonb)
   where id = v_master;
  select catalogue_version into v_master_ver from public.master_chemicals where id = v_master;

  -- The vineyard's record is EXACTLY as it was — no silent rewrite.
  perform public._t199_login('a');
  select * into v_saved from public.saved_chemicals
   where id = 'd9990000-0000-0000-0000-00000000c001';
  if v_saved.active_ingredient <> 'Azoxystrobin 500 g/L' then
    raise exception 'T9 FAILED: master correction rewrote a vineyard record';
  end if;
  if v_saved.master_source_revision >= v_master_ver then
    raise exception 'T9 FAILED: drift not detectable (saved rev % vs master rev %)',
      v_saved.master_source_revision, v_master_ver;
  end if;

  -- The exact query Re-verify will run: "is updated verified info available?"
  if not exists (
    select 1 from public.saved_chemicals sc
      join public.master_chemicals mc on mc.id = sc.master_chemical_id
     where sc.id = 'd9990000-0000-0000-0000-00000000c001'
       and mc.catalogue_version > sc.master_source_revision
  ) then
    raise exception 'T9 FAILED: member cannot detect that updated master information exists';
  end if;

  raise notice 'T9 passed (master rev % > saved rev %; vineyard record untouched)',
    v_master_ver, v_saved.master_source_revision;
end$$;

-- =====================================================================
-- T10  VINEYARD-ONLY EDITS TOUCH NEITHER MASTER NOR LINK
-- =====================================================================
do $$
declare
  v_master uuid := current_setting('vinetrack.t199_master', true)::uuid;
  v_ver_before integer;
  v_hist_before integer;
  v_saved record;
begin
  perform public._t199_login('adm');
  select catalogue_version into v_ver_before from public.master_chemicals where id = v_master;
  select count(*) into v_hist_before from public.master_chemical_versions
   where master_chemical_id = v_master;

  -- The operator edits price/stock — vineyard-private commercial data.
  perform public._t199_login('a');
  update public.saved_chemicals
     set price_per_pack = 189.50, inventory_quantity = 4,
         notes = 'shed 2', client_updated_at = now()
   where id = 'd9990000-0000-0000-0000-00000000c001';

  select * into v_saved from public.saved_chemicals
   where id = 'd9990000-0000-0000-0000-00000000c001';
  if v_saved.master_chemical_id is distinct from v_master then
    raise exception 'T10 FAILED: a price edit disturbed the master link';
  end if;

  perform public._t199_login('adm');
  if (select catalogue_version from public.master_chemicals where id = v_master) <> v_ver_before then
    raise exception 'T10 FAILED: a vineyard edit changed the MASTER product';
  end if;
  if (select count(*) from public.master_chemical_versions where master_chemical_id = v_master)
     <> v_hist_before then
    raise exception 'T10 FAILED: a vineyard edit wrote master history';
  end if;

  raise notice 'T10 passed (vineyard commercial edits never touch the master)';
end$$;

-- =====================================================================
-- T11  HISTORICAL SPRAY SNAPSHOT IS IMMUNE
-- =====================================================================
do $$
declare
  v_master uuid := current_setting('vinetrack.t199_master', true)::uuid;
  v_tanks_before text;
  v_tanks_after text;
begin
  perform public._t199_login('a');

  insert into public.spray_records (id, vineyard_id, date, tanks, client_updated_at)
  values ('d9990000-0000-0000-0000-00000000e001', 'd9990000-0000-0000-0000-000000000001',
          now(),
          '[{"chemicals":[{"name":"T199 Shield 500 SC",
             "chemicalSnapshot":{"activity_groups":["11"],
               "registration_identity_key":"AU:apvma:90001",
               "verification_status":"verified","schema_version":1}}]}]'::jsonb,
          now());

  select tanks::text into v_tanks_before from public.spray_records
   where id = 'd9990000-0000-0000-0000-00000000e001';

  -- Master corrected AND the saved chemical re-labelled afterwards…
  perform public._t199_login('adm');
  update public.master_chemicals
     set registered_uses = jsonb_set(registered_uses, '{0,withholding_period_days}', '21'::jsonb)
   where id = v_master;

  perform public._t199_login('a');
  update public.saved_chemicals
     set name = 'T199 Shield 500 SC (renamed)', client_updated_at = now()
   where id = 'd9990000-0000-0000-0000-00000000c001';

  -- …and the applied-spray snapshot is byte-identical.
  select tanks::text into v_tanks_after from public.spray_records
   where id = 'd9990000-0000-0000-0000-00000000e001';
  if v_tanks_before <> v_tanks_after then
    raise exception 'T11 FAILED: historical spray snapshot changed after master/saved updates';
  end if;

  raise notice 'T11 passed (historical spray snapshots immutable)';
end$$;

-- =====================================================================
-- T12  ISOLATION + REFERENCED MASTER CANNOT BE DELETED
-- =====================================================================
do $$
declare
  v_master uuid := current_setting('vinetrack.t199_master', true)::uuid;
  v_n integer;
  v_caught boolean;
begin
  -- An outsider sees no vineyard chemicals (existing RLS intact) even though
  -- the master row itself is shared reference data.
  perform public._t199_login('b');
  select count(*) into v_n from public.saved_chemicals
   where vineyard_id = 'd9990000-0000-0000-0000-000000000001';
  if v_n <> 0 then
    raise exception 'T12 FAILED: outsider can see another vineyard''s chemicals';
  end if;
  select count(*) into v_n from public.master_chemicals where id = v_master;
  if v_n <> 1 then
    raise exception 'T12 FAILED: approved master should be shared reference data';
  end if;

  -- A master row referenced by ANY vineyard cannot be hard-deleted, even by
  -- an admin. Retirement is the only exit.
  perform public._t199_login('adm');
  v_caught := false;
  begin
    delete from public.master_chemicals where id = v_master;
  exception when foreign_key_violation then v_caught := true;
  end;
  if not v_caught then
    raise exception 'T12 FAILED: a referenced master row was hard-deleted';
  end if;

  raise notice 'T12 passed (vineyard isolation intact; referenced master undeletable)';
end$$;

do $$ begin
  raise notice 'sql/199 master chemical catalogue tests: ALL PASSED';
end $$;

rollback;
