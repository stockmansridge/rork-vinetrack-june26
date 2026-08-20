-- =============================================================================
-- Tests for sql/202_guide_images_storage.sql
--
-- ROLLBACK-ONLY. Nothing is committed. Run with:
--   psql "$DATABASE_URL" -f sql/tests/202_guide_images_storage_tests.sql
--
-- Write/read tests run as `authenticated` with RLS ACTIVE (the sql/195/197
-- lesson: owner-role tests cannot see RLS-dependent defects). Structural
-- checks run as postgres.
--
-- Coverage
--   T1  migration in place (bucket public + 10 MB + exact MIME list; the four
--       guide_images_* policies exist, are bucket-scoped, System Admin-gated,
--       to authenticated only, and none is an unrestricted `true` policy)
--   T2  System Admin can upload (insert) — plain and dotted image keys — and
--       can read objects back through the storage API (select policy)
--   T3  System Admin replace flow: overwrite-update works, new upload +
--       delete of the previously stored object works (DELETE…RETURNING path)
--   T4  a normal authenticated user cannot upload, cannot overwrite, cannot
--       delete, and sees nothing through the storage API
--   T5  unrelated buckets unaffected (long-standing vineyard-logos policy
--       still present; guide policies scoped to bucket_id = 'guide-images')
--   T6  metadata contract: 'guide.visual_assets' persists through the existing
--       system_feature_flags mechanism — System Admin write OK, normal-user
--       write rejected (42501), normal user can read the map for guide display
--   T7  rollback (implicit — the whole run is one aborted transaction)
--
-- NOT testable in SQL (enforced by the storage API from bucket config, verify
-- manually in the portal after applying sql/202):
--   * >10 MB upload rejected; non-JPEG/PNG/WebP upload rejected
--   * public URL serving of uploaded objects (/object/public/guide-images/…)
--
-- Expected final line:
--   NOTICE: sql/202 guide images storage tests: ALL PASSED
-- =============================================================================
begin;

-- ---------------- T1 structure ----------------
do $$
declare
  v_bucket record;
  v_n integer;
begin
  select * into v_bucket from storage.buckets where id = 'guide-images';
  if v_bucket.id is null then
    raise exception 'T1 FAILED: bucket guide-images missing (sql/202 not applied)';
  end if;
  if v_bucket.public is distinct from true then
    raise exception 'T1 FAILED: guide-images must be PUBLIC (Lovable reads via getPublicUrl)';
  end if;
  if v_bucket.file_size_limit is distinct from 10485760 then
    raise exception 'T1 FAILED: file_size_limit expected 10485760, got %', v_bucket.file_size_limit;
  end if;
  if v_bucket.allowed_mime_types is distinct from array['image/jpeg','image/png','image/webp']::text[] then
    raise exception 'T1 FAILED: allowed_mime_types wrong: %', v_bucket.allowed_mime_types;
  end if;

  select count(*) into v_n
    from pg_policies
   where schemaname = 'storage' and tablename = 'objects'
     and policyname like 'guide_images_%';
  if v_n <> 4 then
    raise exception 'T1 FAILED: expected 4 guide_images_* policies, found %', v_n;
  end if;

  if not exists (select 1 from pg_policies
                  where schemaname='storage' and tablename='objects'
                    and policyname='guide_images_select_admin' and cmd='SELECT')
     or not exists (select 1 from pg_policies
                  where schemaname='storage' and tablename='objects'
                    and policyname='guide_images_insert_admin' and cmd='INSERT')
     or not exists (select 1 from pg_policies
                  where schemaname='storage' and tablename='objects'
                    and policyname='guide_images_update_admin' and cmd='UPDATE')
     or not exists (select 1 from pg_policies
                  where schemaname='storage' and tablename='objects'
                    and policyname='guide_images_delete_admin' and cmd='DELETE') then
    raise exception 'T1 FAILED: guide_images_* policy commands wrong';
  end if;

  -- Every policy: authenticated-only, bucket-scoped, System Admin-gated,
  -- never an unrestricted `true` predicate.
  select count(*) into v_n
    from pg_policies
   where schemaname = 'storage' and tablename = 'objects'
     and policyname like 'guide_images_%'
     and (
           roles <> array['authenticated']::name[]
        or coalesce(qual, '')       = 'true'
        or coalesce(with_check, '') = 'true'
        or (coalesce(qual, '') || coalesce(with_check, '')) not like '%guide-images%'
        or (coalesce(qual, '') || coalesce(with_check, '')) not like '%is_system_admin%'
     );
  if v_n <> 0 then
    raise exception 'T1 FAILED: % guide_images_* policies are mis-scoped or unrestricted', v_n;
  end if;

  raise notice 'T1 passed (bucket public + limits exact; 4 scoped admin-gated policies)';
end$$;

-- ---------------- fixtures ----------------
do $$
declare
  u_a uuid; u_adm uuid;
begin
  perform set_config('role', 'postgres', true);

  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at)
  values
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated',
     'authenticated', 't202-member@test.local', 'x', now(), now(), now()),
    (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated',
     'authenticated', 't202-admin@test.local', 'x', now(), now(), now());

  select id into u_a   from auth.users where email = 't202-member@test.local';
  select id into u_adm from auth.users where email = 't202-admin@test.local';

  insert into public.system_admins (user_id, email, is_active)
  values (u_adm, 't202-admin@test.local', true);

  perform set_config('vinetrack.t202_user_a',   u_a::text,   false);
  perform set_config('vinetrack.t202_user_adm', u_adm::text, false);
end$$;

-- Helper: become one of the fixture users, with RLS enforced.
create or replace function public._t202_login(p_which text)
returns void language plpgsql as $$
declare v_uid text;
begin
  v_uid := current_setting('vinetrack.t202_user_' || p_which, true);
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end$$;

-- =====================================================================
-- T2  SYSTEM ADMIN UPLOAD + API READ-BACK
-- =====================================================================
do $$
declare
  v_n integer;
begin
  perform public._t202_login('adm');

  -- Exact Lovable path shape: {image-key}/{epoch-ms}.{ext}. One plain key,
  -- one dotted workflow key (keys with dots are first-class in the contract).
  insert into storage.objects (bucket_id, name)
  values ('guide-images', 'hero/1755000000000.jpg'),
         ('guide-images', 'pins.step.drop/1755000000000.webp');

  select count(*) into v_n from storage.objects where bucket_id = 'guide-images';
  if v_n <> 2 then
    raise exception 'T2 FAILED: admin cannot read own uploads back (saw %, expected 2)', v_n;
  end if;

  raise notice 'T2 passed (admin upload + select for plain and dotted keys)';
end$$;

-- =====================================================================
-- T3  SYSTEM ADMIN REPLACE FLOW (upsert-update, new upload, old delete)
-- =====================================================================
do $$
declare
  v_n integer;
begin
  perform public._t202_login('adm');

  -- upsert:true overwrite = UPDATE on the existing row.
  update storage.objects
     set metadata = '{"cacheControl":"3600"}'::jsonb
   where bucket_id = 'guide-images' and name = 'hero/1755000000000.jpg';
  if not exists (select 1 from storage.objects
                  where bucket_id = 'guide-images'
                    and name = 'hero/1755000000000.jpg'
                    and metadata->>'cacheControl' = '3600') then
    raise exception 'T3 FAILED: admin overwrite-update did not stick';
  end if;

  -- Replace = upload new timestamped object, then remove the previous one.
  insert into storage.objects (bucket_id, name)
  values ('guide-images', 'hero/1755000000001.jpg');

  delete from storage.objects
   where bucket_id = 'guide-images' and name = 'hero/1755000000000.jpg';

  select count(*) into v_n from storage.objects
   where bucket_id = 'guide-images' and name like 'hero/%';
  if v_n <> 1 then
    raise exception 'T3 FAILED: replace should leave exactly 1 hero object, found %', v_n;
  end if;
  if exists (select 1 from storage.objects
              where bucket_id = 'guide-images' and name = 'hero/1755000000000.jpg') then
    raise exception 'T3 FAILED: previous hero object was not deleted';
  end if;

  raise notice 'T3 passed (admin overwrite, new upload and old-object delete)';
end$$;

-- =====================================================================
-- T4  NORMAL USER: NO WRITE, NO OVERWRITE, NO DELETE, NO API READ
-- =====================================================================
do $$
declare
  v_caught boolean;
  v_n integer;
begin
  perform public._t202_login('a');

  v_caught := false;
  begin
    insert into storage.objects (bucket_id, name)
    values ('guide-images', 'hero/9999999999999.jpg');
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then
    raise exception 'T4 FAILED: a normal user uploaded into guide-images';
  end if;

  -- RLS silently filters updates/deletes to 0 rows — verify nothing changed.
  update storage.objects
     set metadata = '{"hacked":true}'::jsonb
   where bucket_id = 'guide-images';
  delete from storage.objects where bucket_id = 'guide-images';

  select count(*) into v_n from storage.objects where bucket_id = 'guide-images';
  if v_n <> 0 then
    raise exception 'T4 FAILED: normal user can read guide-images via the storage API (% rows)', v_n;
  end if;

  perform set_config('role', 'postgres', true);
  select count(*) into v_n from storage.objects where bucket_id = 'guide-images';
  if v_n <> 2 then
    raise exception 'T4 FAILED: normal user deleted guide-images objects (% left, expected 2)', v_n;
  end if;
  if exists (select 1 from storage.objects
              where bucket_id = 'guide-images' and metadata->>'hacked' = 'true') then
    raise exception 'T4 FAILED: normal user modified a guide-images object';
  end if;

  raise notice 'T4 passed (normal user fully write-blocked; API reads admin-only)';
end$$;

-- =====================================================================
-- T5  UNRELATED BUCKETS UNAFFECTED
-- =====================================================================
do $$
declare
  v_n integer;
begin
  perform set_config('role', 'postgres', true);

  -- Long-standing policy from sql/010 must still exist untouched.
  if not exists (select 1 from pg_policies
                  where schemaname = 'storage' and tablename = 'objects'
                    and policyname = 'vineyard_logos_select_members') then
    raise exception 'T5 FAILED: pre-existing vineyard-logos policy disappeared';
  end if;

  -- No guide policy reaches outside its bucket (belt-and-braces re-check).
  select count(*) into v_n
    from pg_policies
   where schemaname = 'storage' and tablename = 'objects'
     and policyname like 'guide_images_%'
     and (coalesce(qual, '') || coalesce(with_check, '')) not like '%guide-images%';
  if v_n <> 0 then
    raise exception 'T5 FAILED: a guide_images_* policy is not bucket-scoped';
  end if;

  raise notice 'T5 passed (other buckets and their policies untouched)';
end$$;

-- =====================================================================
-- T6  METADATA CONTRACT — guide.visual_assets via system_feature_flags
-- =====================================================================
do $$
declare
  v_caught boolean;
  v_path text;
begin
  -- System Admin persists the key→asset map exactly as the portal does.
  perform public._t202_login('adm');
  perform public.set_system_feature_flag(
    'guide.visual_assets', true,
    '{"hero":{"path":"hero/1755000000001.jpg","focus":"right","updated_at":"2026-08-20T00:00:00Z"}}'::jsonb);

  -- A normal user reads the map back (this is how the guide resolves images).
  perform public._t202_login('a');
  select f.value->'hero'->>'path' into v_path
    from public.get_system_feature_flags() f
   where f.key = 'guide.visual_assets';
  if v_path is distinct from 'hero/1755000000001.jpg' then
    raise exception 'T6 FAILED: guide image map not readable by normal users (got %)', v_path;
  end if;

  -- ...but can never write it.
  v_caught := false;
  begin
    perform public.set_system_feature_flag('guide.visual_assets', true, '{}'::jsonb);
  exception when insufficient_privilege then v_caught := true;
  end;
  if not v_caught then
    raise exception 'T6 FAILED: a normal user rewrote the guide image map';
  end if;

  raise notice 'T6 passed (flag map: admin-write, everyone-read, member write rejected)';
end$$;

do $$ begin
  raise notice 'sql/202 guide images storage tests: ALL PASSED';
end $$;

rollback;
