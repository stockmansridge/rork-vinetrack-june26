-- =============================================================================
-- Tests for sql/205_chemical_display_name_casing.sql
--
-- ROLLBACK-ONLY. Nothing is committed. Run with:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f sql/tests/205_chemical_display_name_casing_tests.sql
--
-- Coverage
--   T1 migration in place (function, trigger function, trigger on the table)
--   T2 the casing rule: register capitals become readable words, and capitals
--      that carry meaning (codes, digits, single letters) survive
--   T3 anything already carrying lower case is returned BYTE-IDENTICAL, and
--      the rule is idempotent — f(f(x)) = f(x)
--   T4 the trigger cases on INSERT and on UPDATE, from any client, and leaves
--      an already-cased name alone
--   T5 master_chemicals.registered_product_name (register evidence, matching
--      key) is untouched — no trigger, byte-identical after an update
--   T6 spray_records snapshots (frozen evidence) are untouched
--   T7 the backfill predicate is settled: no live saved_chemicals row is left
--      shouting
--
-- Expected final line:
--   NOTICE: sql/205 chemical display name casing tests: ALL PASSED
-- =============================================================================
begin;

-- ---------------- T1 preconditions ----------------
do $$
begin
  if to_regprocedure('public.vt_display_chemical_name(text)') is null then
    raise exception 'T1 FAILED: vt_display_chemical_name(text) missing (apply sql/205 first)';
  end if;
  if to_regprocedure('public.saved_chemicals_display_name()') is null then
    raise exception 'T1 FAILED: saved_chemicals_display_name() missing';
  end if;
  if not exists (
    select 1 from pg_trigger t
     where t.tgrelid = 'public.saved_chemicals'::regclass
       and t.tgname = 'saved_chemicals_display_name'
       and not t.tgisinternal
  ) then
    raise exception 'T1 FAILED: trigger saved_chemicals_display_name missing on saved_chemicals';
  end if;
  raise notice 'T1 passed: sql/205 objects in place';
end;
$$;

-- ---------------- T2 the casing rule ----------------
do $$
declare
  v_cases text[][] := array[
    -- [input, expected]
    array['DITHANE RAINSHIELD NEO TEC FUNGICIDE', 'Dithane Rainshield Neo Tec Fungicide'],
    array['CUSTODIA FORTE FUNGICIDE',             'Custodia Forte Fungicide'],
    array['SPRAYSEAL PRUNING WOUND TREATMENT',    'Sprayseal Pruning Wound Treatment'],
    -- formulation codes have no vowel: they stay codes
    array['TOPAS 100 EC',                         'Topas 100 EC'],
    array['COPPER OXYCHLORIDE WG',                'Copper Oxychloride WG'],
    array['MANCOZEB DF',                          'Mancozeb DF'],
    -- anything with a digit is kept verbatim
    array['PENNCOZEB 750DF',                      'Penncozeb 750DF'],
    array['CAVALIER 500SC',                       'Cavalier 500SC'],
    -- hyphens are cased part by part and preserved; single letters survive
    array['2,4-D AMINE 625',                      '2,4-D Amine 625'],
    array['ROUND-UP ATTACK',                      'Round-Up Attack'],
    -- vowel-carrying codes on the keep list
    array['GLYPHOSATE ULV',                       'Glyphosate ULV'],
    array['MCPA 750',                             'MCPA 750'],
    -- whitespace is tidied on a name we are already rewriting
    array['  KOCIDE   BLUE  ',                    'Kocide Blue']
  ];
  v_in  text;
  v_out text;
  v_got text;
  i int;
begin
  for i in 1 .. array_length(v_cases, 1) loop
    v_in  := v_cases[i][1];
    v_out := v_cases[i][2];
    v_got := public.vt_display_chemical_name(v_in);
    if v_got is distinct from v_out then
      raise exception 'T2 FAILED: % -> % (expected %)', v_in, v_got, v_out;
    end if;
  end loop;

  if public.vt_display_chemical_name(null) is not null then
    raise exception 'T2 FAILED: null must stay null';
  end if;
  if public.vt_display_chemical_name('') <> '' then
    raise exception 'T2 FAILED: empty must stay empty';
  end if;

  raise notice 'T2 passed: register capitals become readable, meaningful capitals survive';
end;
$$;

-- ---------------- T3 lower case is sacred + idempotence ----------------
do $$
declare
  v_keep text[] := array[
    'Kocide Blue Xtra',            -- manufacturer styling
    'Dithane Rainshield Neo Tec',  -- already cased by the pipeline
    'my shed mix',                 -- operator wording, lower case on purpose
    'BASF Something Xtra',         -- a genuine acronym inside a cased name
    'pHix'                         -- deliberate internal capital
  ];
  v_name text;
  v_got  text;
begin
  foreach v_name in array v_keep loop
    v_got := public.vt_display_chemical_name(v_name);
    if v_got <> v_name then
      raise exception 'T3 FAILED: % was rewritten to %', v_name, v_got;
    end if;
  end loop;

  -- Idempotent: running the rule over its own output changes nothing.
  foreach v_name in array array['DITHANE RAINSHIELD NEO TEC FUNGICIDE', 'TOPAS 100 EC', '2,4-D AMINE 625'] loop
    v_got := public.vt_display_chemical_name(v_name);
    if public.vt_display_chemical_name(v_got) <> v_got then
      raise exception 'T3 FAILED: not idempotent for %', v_name;
    end if;
  end loop;

  raise notice 'T3 passed: mixed-case names untouched, rule is idempotent';
end;
$$;

-- ---------------- T4/T5/T6 live table behaviour ----------------
do $$
declare
  v_vy      uuid := 'd2050000-0000-0000-0000-000000000001';
  v_chem    uuid := 'd2050000-0000-0000-0000-00000000c001';
  v_typed   uuid := 'd2050000-0000-0000-0000-00000000c002';
  v_master  uuid;
  v_spray   uuid := 'd2050000-0000-0000-0000-00000000e001';
  v_name    text;
  v_tanks   jsonb;
  v_before  jsonb;
begin
  insert into public.vineyards (id, name) values (v_vy, 'T205 Vineyard');

  -- T4: INSERT from a client that sends the register's capitals.
  insert into public.saved_chemicals (id, vineyard_id, name, client_updated_at)
  values (v_chem, v_vy, 'DITHANE RAINSHIELD NEO TEC FUNGICIDE', now());

  select name into v_name from public.saved_chemicals where id = v_chem;
  if v_name <> 'Dithane Rainshield Neo Tec Fungicide' then
    raise exception 'T4 FAILED: insert stored "%"', v_name;
  end if;

  -- T4: UPDATE is covered too (an older client re-uploading its cached row).
  update public.saved_chemicals set name = 'PENNCOZEB 750DF' where id = v_chem;
  select name into v_name from public.saved_chemicals where id = v_chem;
  if v_name <> 'Penncozeb 750DF' then
    raise exception 'T4 FAILED: update stored "%"', v_name;
  end if;

  -- T4: a name the operator cased themselves is stored exactly as sent.
  insert into public.saved_chemicals (id, vineyard_id, name, client_updated_at)
  values (v_typed, v_vy, 'my shed mix', now());
  select name into v_name from public.saved_chemicals where id = v_typed;
  if v_name <> 'my shed mix' then
    raise exception 'T4 FAILED: operator wording became "%"', v_name;
  end if;

  -- T5: the register name is evidence and a matching key. No trigger, and an
  -- unrelated update must leave it byte-identical.
  if exists (
    select 1 from pg_trigger t
     where t.tgrelid = 'public.master_chemicals'::regclass
       and t.tgname like '%display_name%'
       and not t.tgisinternal
  ) then
    raise exception 'T5 FAILED: a display-name trigger exists on master_chemicals';
  end if;

  insert into public.master_chemicals
    (registration_country, registration_scheme, registration_number,
     registered_product_name, source_kind, review_status)
  values ('AU', 'apvma', 'T205-90001',
          'DITHANE RAINSHIELD NEO TEC FUNGICIDE', 'manufacturer_label', 'candidate')
  returning id into v_master;

  update public.master_chemicals set review_notes = 'T205 touch' where id = v_master;

  select registered_product_name into v_name from public.master_chemicals where id = v_master;
  if v_name <> 'DITHANE RAINSHIELD NEO TEC FUNGICIDE' then
    raise exception 'T5 FAILED: register evidence became "%"', v_name;
  end if;

  -- T6: a historical spray snapshot names its product inside `tanks`. Frozen.
  v_before := '[{"chemicals":[{"name":"DITHANE RAINSHIELD NEO TEC FUNGICIDE"}]}]'::jsonb;
  insert into public.spray_records (id, vineyard_id, date, tanks, client_updated_at)
  values (v_spray, v_vy, now(), v_before, now());

  update public.saved_chemicals set name = 'DITHANE RAINSHIELD NEO TEC FUNGICIDE'
   where id = v_chem;

  select tanks into v_tanks from public.spray_records where id = v_spray;
  if v_tanks is distinct from v_before then
    raise exception 'T6 FAILED: spray snapshot changed to %', v_tanks;
  end if;

  raise notice 'T4 passed: trigger cases inserts and updates, operator wording preserved';
  raise notice 'T5 passed: register evidence untouched';
  raise notice 'T6 passed: spray snapshots untouched';
end;
$$;

-- ---------------- T7 nothing left shouting ----------------
do $$
declare
  v_left bigint;
begin
  select count(*) into v_left
    from public.saved_chemicals c
   where c.deleted_at is null
     and c.name <> ''
     and public.vt_display_chemical_name(c.name) is distinct from c.name;

  if v_left > 0 then
    raise exception 'T7 FAILED: % live saved_chemicals rows still need casing', v_left;
  end if;

  raise notice 'T7 passed: no live chemical name is left shouting';
end;
$$;

do $$
begin
  raise notice 'sql/205 chemical display name casing tests: ALL PASSED';
end;
$$;

rollback;
