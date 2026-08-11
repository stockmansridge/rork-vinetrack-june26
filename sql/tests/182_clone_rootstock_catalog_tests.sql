-- =====================================================================
-- 182_clone_rootstock_catalog_tests.sql — rollback-only verification
-- =====================================================================
-- Run in the Supabase SQL editor of the SHARED VineTrack project AFTER
-- applying sql/182_clone_rootstock_catalog.sql.
--
-- Everything runs inside ONE transaction that is ROLLED BACK at the end.
-- No production row is created, changed or deleted.
--
-- Test map
--   T1  Objects, triggers, seeds, RPC grants exist
--   T2  System clone lookup: clones belong to ONE variety; selection-system
--       identity preserved (FPS vs ENTAV records with same visible number
--       stay distinct)
--   T3  Custom clones: RPC derives stable variety-scoped key, requires a
--       valid parent variety, rejects reserved sentinel names, upserts in
--       place, and supports clones on CUSTOM varieties
--   T4  Rootstocks: independent catalogue; custom rootstock creation;
--       built-in near-duplicates rejected; reserved 'own roots' rejected;
--       archive hides the record
--   T5  RLS isolation: outsiders can't list/read another vineyard's custom
--       records; operators can't create custom records; global catalogue
--       writes blocked for non-admins
--   T6  Archive clone: owner/manager only; archived clone flagged inactive
--       but retained (historical allocations keep resolving by key)
--
-- Expected final output:
--   NOTICE: SQL 182 clone/rootstock catalogue tests: ALL PASSED
-- =====================================================================

begin;

-- Guard: refuse to run before SQL 182 is applied.
do $$
begin
  if to_regclass('public.grape_clone_catalog') is null
     or to_regclass('public.vineyard_grape_clones') is null
     or to_regclass('public.rootstock_catalog') is null
     or to_regclass('public.vineyard_rootstocks') is null
     or to_regprocedure('public.upsert_vineyard_grape_clone(uuid, text, text, boolean)') is null
     or to_regprocedure('public.upsert_vineyard_rootstock(uuid, text, boolean)') is null then
    raise exception 'SQL 182 not applied — run sql/182_clone_rootstock_catalog.sql first.';
  end if;
end$$;

do $$
declare
  u_mgr uuid;
  u_op  uuid;
  u_out uuid;
  v_vy  uuid := gen_random_uuid();
  v_vy2 uuid := gen_random_uuid();
  r_clone  public.vineyard_grape_clones;
  r_clone2 public.vineyard_grape_clones;
  r_root   public.vineyard_rootstocks;
  r_var    public.vineyard_grape_varieties;
  n     integer;
  v_failed boolean;
begin
  -- ---- fixtures ----------------------------------------------------------
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
  select gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         e, 'x', now(), now(), now()
  from unnest(array['t182-mgr@test.local','t182-op@test.local','t182-out@test.local']) e;
  select id into u_mgr from auth.users where email = 't182-mgr@test.local';
  select id into u_op  from auth.users where email = 't182-op@test.local';
  select id into u_out from auth.users where email = 't182-out@test.local';

  insert into public.profiles (id, email)
  select u, 't182-' || u::text || '@test.local' from unnest(array[u_mgr, u_op, u_out]) u
  on conflict (id) do nothing;

  insert into public.vineyards (id, name) values
    (v_vy,  'T182 Clone Vineyard'),
    (v_vy2, 'T182 Other Vineyard');
  insert into public.vineyard_members (vineyard_id, user_id, role) values
    (v_vy,  u_mgr, 'manager'),
    (v_vy,  u_op,  'operator'),
    (v_vy2, u_out, 'manager');

  -- ---- T1. Objects, seeds, grants -----------------------------------------
  select count(*) into n from information_schema.columns
  where table_schema = 'public' and table_name = 'grape_clone_catalog'
    and column_name in ('key','variety_key','display_name','clone_code','selection_system',
                        'source_country','aliases','source_reference','is_builtin','is_active',
                        'created_at','updated_at');
  if n <> 12 then raise exception 'T1: grape_clone_catalog expected 12 contract columns, found %', n; end if;

  select count(*) into n from information_schema.columns
  where table_schema = 'public' and table_name = 'rootstock_catalog'
    and column_name in ('key','canonical_name','display_name','aliases','parentage',
                        'source_reference','is_builtin','is_active','created_at','updated_at');
  if n <> 10 then raise exception 'T1: rootstock_catalog expected 10 contract columns, found %', n; end if;

  select count(*) into n from public.grape_clone_catalog where is_builtin and is_active;
  if n < 50 then raise exception 'T1: expected >= 50 seeded clones, found %', n; end if;

  select count(*) into n from public.rootstock_catalog where is_builtin and is_active;
  if n < 20 then raise exception 'T1: expected >= 20 seeded rootstocks, found %', n; end if;

  if not exists (select 1 from public.grape_clone_catalog where key = 'shiraz:pt23' and variety_key = 'shiraz') then
    raise exception 'T1: seed clone shiraz:pt23 missing';
  end if;
  if not exists (select 1 from public.rootstock_catalog where key = '1103_paulsen') then
    raise exception 'T1: seed rootstock 1103_paulsen missing';
  end if;

  select count(*) into n from pg_trigger
  where tgrelid in ('public.grape_clone_catalog'::regclass,
                    'public.vineyard_grape_clones'::regclass,
                    'public.rootstock_catalog'::regclass,
                    'public.vineyard_rootstocks'::regclass)
    and tgname like 'trg_%_touch';
  if n <> 4 then raise exception 'T1: expected 4 touch triggers, found %', n; end if;

  if to_regprocedure('public.get_grape_clone_catalog()') is null
     or to_regprocedure('public.get_rootstock_catalog()') is null
     or to_regprocedure('public.list_vineyard_grape_clones(uuid)') is null
     or to_regprocedure('public.list_vineyard_rootstocks(uuid)') is null
     or to_regprocedure('public.archive_vineyard_grape_clone(uuid)') is null
     or to_regprocedure('public.archive_vineyard_rootstock(uuid)') is null then
    raise exception 'T1: RPCs missing';
  end if;
  raise notice 'T1 passed';

  -- ---- T2. Clone-variety ownership + selection-system identity -------------
  -- Every clone belongs to exactly one variety.
  select count(*) into n from public.grape_clone_catalog
  where variety_key is null or trim(variety_key) = '';
  if n <> 0 then raise exception 'T2: % clones without a variety', n; end if;

  -- Shiraz clones never surface under Chardonnay.
  select count(*) into n from public.grape_clone_catalog
  where key like 'shiraz:%' and variety_key <> 'shiraz';
  if n <> 0 then raise exception 'T2: shiraz-prefixed clone with wrong variety_key'; end if;

  -- FPS 07 exists for BOTH Shiraz and Cabernet as DISTINCT records —
  -- visible number alone never collapses selection identity.
  select count(*) into n from public.grape_clone_catalog
  where clone_code = 'FPS 07' and selection_system = 'FPS (UC Davis)';
  if n < 2 then raise exception 'T2: expected distinct FPS 07 records per variety, found %', n; end if;

  -- An ENTAV number and an FPS number are separate systems: no seeded row
  -- mixes them.
  select count(*) into n from public.grape_clone_catalog
  where selection_system = 'ENTAV-INRA' and clone_code like 'FPS%';
  if n <> 0 then raise exception 'T2: ENTAV row carrying an FPS code'; end if;
  raise notice 'T2 passed';

  -- ---- T3. Custom clones ----------------------------------------------------
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_mgr::text, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);

  -- Create a custom clone under a built-in variety.
  r_clone := public.upsert_vineyard_grape_clone(v_vy, 'shiraz', 'Old Block Selection', true);
  if r_clone.clone_key <> ('custom:' || v_vy::text || ':shiraz:old_block_selection') then
    raise exception 'T3: unexpected custom clone key %', r_clone.clone_key;
  end if;
  if r_clone.variety_key <> 'shiraz' or not r_clone.is_custom then
    raise exception 'T3: custom clone row wrong (variety=% custom=%)', r_clone.variety_key, r_clone.is_custom;
  end if;

  -- Upsert same name again — updates in place, no duplicate.
  r_clone2 := public.upsert_vineyard_grape_clone(v_vy, 'shiraz', 'Old Block Selection', true);
  if r_clone2.id <> r_clone.id then raise exception 'T3: upsert minted a second row'; end if;
  select count(*) into n from public.vineyard_grape_clones where vineyard_id = v_vy;
  if n <> 1 then raise exception 'T3: expected 1 custom clone, found %', n; end if;

  -- Parent variety is REQUIRED and must exist.
  v_failed := false;
  begin
    perform public.upsert_vineyard_grape_clone(v_vy, null, 'Nameless', true);
  exception when others then v_failed := true;
  end;
  if not v_failed then raise exception 'T3: missing variety accepted'; end if;

  v_failed := false;
  begin
    perform public.upsert_vineyard_grape_clone(v_vy, 'not_a_variety', 'Ghost', true);
  exception when others then v_failed := true;
  end;
  if not v_failed then raise exception 'T3: unknown variety accepted'; end if;

  -- Reserved sentinel names rejected (they are conventions, not records).
  v_failed := false;
  begin
    perform public.upsert_vineyard_grape_clone(v_vy, 'shiraz', 'Mass Selection', true);
  exception when others then v_failed := true;
  end;
  if not v_failed then raise exception 'T3: reserved name accepted'; end if;

  -- Clones on CUSTOM varieties: create the variety, then a clone under it.
  r_var := public.upsert_vineyard_grape_variety(v_vy, null, 'T182 Rare White', null, true);
  r_clone2 := public.upsert_vineyard_grape_clone(v_vy, r_var.variety_key, 'Estate Selection', true);
  if r_clone2.variety_key <> r_var.variety_key then
    raise exception 'T3: custom-variety clone lost its parent variety';
  end if;

  -- The Shiraz custom clone and the Rare White custom clone never collide
  -- and are filterable by variety.
  select count(*) into n from public.vineyard_grape_clones
  where vineyard_id = v_vy and variety_key = 'shiraz';
  if n <> 1 then raise exception 'T3: variety filter broken (shiraz=%)', n; end if;
  raise notice 'T3 passed';

  -- ---- T4. Rootstocks -------------------------------------------------------
  -- Custom rootstock.
  r_root := public.upsert_vineyard_rootstock(v_vy, 'Trial Stock 7', true);
  if r_root.rootstock_key <> ('custom:' || v_vy::text || ':trial_stock_7') or not r_root.is_custom then
    raise exception 'T4: unexpected custom rootstock %', r_root.rootstock_key;
  end if;

  -- Near-duplicate of a built-in is rejected (typo must not shadow catalogue).
  v_failed := false;
  begin
    perform public.upsert_vineyard_rootstock(v_vy, '1103 Paulsen', true);
  exception when others then v_failed := true;
  end;
  if not v_failed then raise exception 'T4: built-in duplicate accepted'; end if;

  -- Reserved own-roots naming rejected — own roots is an allocation
  -- sentinel, never a rootstock record.
  v_failed := false;
  begin
    perform public.upsert_vineyard_rootstock(v_vy, 'Own Roots', true);
  exception when others then v_failed := true;
  end;
  if not v_failed then raise exception 'T4: reserved own roots accepted'; end if;

  -- Archive hides but retains the record.
  r_root := public.archive_vineyard_rootstock(r_root.id);
  if r_root.is_active then raise exception 'T4: archive did not deactivate'; end if;
  select count(*) into n from public.vineyard_rootstocks where vineyard_id = v_vy;
  if n <> 1 then raise exception 'T4: archived rootstock disappeared'; end if;
  raise notice 'T4 passed';

  -- ---- T5. RLS isolation ----------------------------------------------------
  -- Outsider (member of another vineyard only) can't list this vineyard.
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_out::text, 'role', 'authenticated')::text, true);

  v_failed := false;
  begin
    perform * from public.list_vineyard_grape_clones(v_vy);
  exception when others then v_failed := true;
  end;
  if not v_failed then raise exception 'T5: outsider listed foreign clones'; end if;

  v_failed := false;
  begin
    perform * from public.list_vineyard_rootstocks(v_vy);
  exception when others then v_failed := true;
  end;
  if not v_failed then raise exception 'T5: outsider listed foreign rootstocks'; end if;

  -- Direct table reads are RLS-filtered to zero.
  select count(*) into n from public.vineyard_grape_clones where vineyard_id = v_vy;
  if n <> 0 then raise exception 'T5: outsider read % foreign clone rows', n; end if;

  -- Outsider cannot create custom records in the foreign vineyard.
  v_failed := false;
  begin
    perform public.upsert_vineyard_grape_clone(v_vy, 'shiraz', 'Intruder', true);
  exception when others then v_failed := true;
  end;
  if not v_failed then raise exception 'T5: outsider created a foreign clone'; end if;

  -- Operator (member, but below manager) cannot create custom records.
  perform set_config('request.jwt.claims',
    json_build_object('sub', u_op::text, 'role', 'authenticated')::text, true);

  v_failed := false;
  begin
    perform public.upsert_vineyard_grape_clone(v_vy, 'shiraz', 'Operator Clone', true);
  exception when others then v_failed := true;
  end;
  if not v_failed then raise exception 'T5: operator created a custom clone'; end if;

  -- …but the operator CAN read the vineyard's custom records + catalogue.
  select count(*) into n from public.list_vineyard_grape_clones(v_vy);
  if n < 1 then raise exception 'T5: operator could not read vineyard clones'; end if;
  select count(*) into n from public.get_grape_clone_catalog();
  if n < 50 then raise exception 'T5: operator could not read global clone catalogue'; end if;

  -- Global catalogue writes blocked for non-admins.
  v_failed := false;
  begin
    insert into public.grape_clone_catalog (key, variety_key, display_name, clone_code)
    values ('shiraz:hax', 'shiraz', 'Hax', 'HAX');
  exception when others then v_failed := true;
  end;
  if not v_failed then raise exception 'T5: non-admin wrote to global clone catalogue'; end if;

  v_failed := false;
  begin
    insert into public.rootstock_catalog (key, canonical_name, display_name)
    values ('hax_stock', 'Hax Stock', 'Hax Stock');
  exception when others then v_failed := true;
  end;
  if not v_failed then raise exception 'T5: non-admin wrote to global rootstock catalogue'; end if;
  raise notice 'T5 passed';

  -- ---- T6. Archive clone: manager only, record retained ---------------------
  v_failed := false;
  begin
    perform public.archive_vineyard_grape_clone(r_clone.id);  -- still operator
  exception when others then v_failed := true;
  end;
  if not v_failed then raise exception 'T6: operator archived a clone'; end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', u_mgr::text, 'role', 'authenticated')::text, true);
  r_clone := public.archive_vineyard_grape_clone(r_clone.id);
  if r_clone.is_active then raise exception 'T6: archive did not deactivate clone'; end if;
  select count(*) into n from public.vineyard_grape_clones where id = r_clone.id;
  if n <> 1 then raise exception 'T6: archived clone deleted'; end if;
  raise notice 'T6 passed';

  raise notice 'SQL 182 clone/rootstock catalogue tests: ALL PASSED';
end$$;

rollback;
