-- =====================================================================
-- 055 · Growth Stage Records — dedicated table + view + storage bucket
-- =====================================================================
-- Phase: Growth Stage Records
--
-- Adds public.growth_stage_records as the canonical store for grape vine
-- growth-stage observations (E-L stage). The existing pin-based growth
-- observations (`public.pins` with `growth_stage_code` not null) remain
-- the source of truth for the legacy iOS workflow and continue to be
-- written by the existing client. This migration is strictly additive:
--
--   * Adds public.growth_stage_records and its RLS / soft-delete RPC.
--   * Adds the public.v_growth_stage_observations view so the Lovable
--     web portal can read both pins-based and new-table observations
--     during the transition.
--   * Adds the private "growth-stage-photos" storage bucket and policies.
--   * Backfills records from existing growth-stage pins (idempotent
--     via pin_id) without modifying the source pins.
--
-- Mirroring strategy:
--   The iOS client mirrors growth-stage pins into growth_stage_records
--   when a pin with mode='growth' and growth_stage_code is saved. The
--   `pin_id` column links the mirrored row back to its source pin so
--   updates/soft-deletes can be reconciled.
-- =====================================================================

-- ----- 1. Table -----------------------------------------------------------
create table if not exists public.growth_stage_records (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  paddock_id uuid null,
  pin_id uuid null,
  stage_code text not null,
  stage_label text null,
  variety text null,
  variety_id uuid null,
  observed_at timestamptz not null default now(),
  latitude double precision null,
  longitude double precision null,
  row_number integer null,
  side text null,
  notes text null,
  photo_paths text[] not null default '{}',
  recorded_by_name text null,
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  client_updated_at timestamptz null,
  sync_version integer not null default 1,
  deleted_at timestamptz null
);

-- Best-effort FKs (only if referenced tables exist in this project)
do $$
begin
  if exists (select 1 from information_schema.tables
             where table_schema = 'public' and table_name = 'paddocks')
     and not exists (select 1 from information_schema.table_constraints
                     where table_schema = 'public'
                       and table_name = 'growth_stage_records'
                       and constraint_name = 'growth_stage_records_paddock_id_fkey') then
    alter table public.growth_stage_records
      add constraint growth_stage_records_paddock_id_fkey
      foreign key (paddock_id) references public.paddocks(id) on delete set null;
  end if;

  if exists (select 1 from information_schema.tables
             where table_schema = 'public' and table_name = 'pins')
     and not exists (select 1 from information_schema.table_constraints
                     where table_schema = 'public'
                       and table_name = 'growth_stage_records'
                       and constraint_name = 'growth_stage_records_pin_id_fkey') then
    alter table public.growth_stage_records
      add constraint growth_stage_records_pin_id_fkey
      foreign key (pin_id) references public.pins(id) on delete set null;
  end if;
end$$;

-- Unique constraint on pin_id (for active rows) so the iOS mirror is idempotent.
create unique index if not exists uq_growth_stage_records_pin_id_active
  on public.growth_stage_records (pin_id)
  where pin_id is not null and deleted_at is null;

create index if not exists idx_growth_stage_records_vineyard_observed
  on public.growth_stage_records (vineyard_id, observed_at desc)
  where deleted_at is null;
create index if not exists idx_growth_stage_records_paddock_id
  on public.growth_stage_records (paddock_id);
create index if not exists idx_growth_stage_records_variety
  on public.growth_stage_records (vineyard_id, variety)
  where deleted_at is null;
create index if not exists idx_growth_stage_records_updated_at
  on public.growth_stage_records (updated_at);
create index if not exists idx_growth_stage_records_deleted_at
  on public.growth_stage_records (deleted_at);

create or replace trigger growth_stage_records_set_updated_at
before update on public.growth_stage_records
for each row execute function public.set_updated_at();

-- ----- 2. RLS -------------------------------------------------------------
alter table public.growth_stage_records enable row level security;

drop policy if exists "growth_stage_records_select_members"
  on public.growth_stage_records;
create policy "growth_stage_records_select_members"
on public.growth_stage_records for select
to authenticated
using (public.is_vineyard_member(vineyard_id));

drop policy if exists "growth_stage_records_insert_members"
  on public.growth_stage_records;
create policy "growth_stage_records_insert_members"
on public.growth_stage_records for insert
to authenticated
with check (
  public.has_vineyard_role(vineyard_id,
    array['owner','manager','supervisor','operator'])
);

drop policy if exists "growth_stage_records_update_members"
  on public.growth_stage_records;
create policy "growth_stage_records_update_members"
on public.growth_stage_records for update
to authenticated
using (
  public.has_vineyard_role(vineyard_id,
    array['owner','manager','supervisor','operator'])
)
with check (
  public.has_vineyard_role(vineyard_id,
    array['owner','manager','supervisor','operator'])
);

drop policy if exists "growth_stage_records_no_client_hard_delete"
  on public.growth_stage_records;
create policy "growth_stage_records_no_client_hard_delete"
on public.growth_stage_records for delete
to authenticated
using (false);

-- ----- 3. Soft-delete RPC -------------------------------------------------
create or replace function public.soft_delete_growth_stage_record(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_vineyard_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  select vineyard_id into v_vineyard_id
    from public.growth_stage_records
   where id = p_id;

  if v_vineyard_id is null then
    raise exception 'Growth stage record not found';
  end if;

  if not public.has_vineyard_role(v_vineyard_id,
       array['owner','manager','supervisor']) then
    raise exception 'Insufficient permissions to delete growth stage record';
  end if;

  update public.growth_stage_records
     set deleted_at = now(),
         updated_by = auth.uid(),
         sync_version = sync_version + 1
   where id = p_id;
end;
$function$;
revoke all on function public.soft_delete_growth_stage_record(uuid) from public;
grant execute on function public.soft_delete_growth_stage_record(uuid)
  to authenticated;

-- ----- 4. Backwards-compatible view --------------------------------------
-- Union of legacy pin-based growth observations and new growth_stage_records.
-- Pin rows that have already been mirrored (pin_id present in
-- growth_stage_records) are excluded from the pin branch to avoid
-- duplicates. The new-table branch always wins.
create or replace view public.v_growth_stage_observations as
  select
    gsr.id                  as id,
    gsr.vineyard_id         as vineyard_id,
    gsr.paddock_id          as paddock_id,
    gsr.pin_id              as pin_id,
    gsr.stage_code          as stage_code,
    gsr.stage_label         as stage_label,
    gsr.variety             as variety,
    gsr.variety_id          as variety_id,
    gsr.observed_at         as observed_at,
    gsr.latitude            as latitude,
    gsr.longitude           as longitude,
    gsr.row_number          as row_number,
    gsr.side                as side,
    gsr.notes               as notes,
    gsr.photo_paths         as photo_paths,
    gsr.recorded_by_name    as recorded_by_name,
    gsr.created_by          as created_by,
    gsr.updated_by          as updated_by,
    gsr.created_at          as created_at,
    gsr.updated_at          as updated_at,
    'growth_stage_records'::text as source
  from public.growth_stage_records gsr
  where gsr.deleted_at is null
  union all
  select
    p.id                    as id,
    p.vineyard_id           as vineyard_id,
    p.paddock_id            as paddock_id,
    p.id                    as pin_id,
    p.growth_stage_code     as stage_code,
    null::text              as stage_label,
    null::text              as variety,
    null::uuid              as variety_id,
    coalesce(p.created_at, now()) as observed_at,
    p.latitude              as latitude,
    p.longitude             as longitude,
    p.row_number            as row_number,
    p.side                  as side,
    p.notes                 as notes,
    case
      when p.photo_path is not null then array[p.photo_path]
      else '{}'::text[]
    end                     as photo_paths,
    p.completed_by          as recorded_by_name,
    p.created_by            as created_by,
    p.updated_by            as updated_by,
    p.created_at            as created_at,
    p.updated_at            as updated_at,
    'pins'::text            as source
  from public.pins p
  where p.deleted_at is null
    and p.growth_stage_code is not null
    and not exists (
      select 1 from public.growth_stage_records gsr2
       where gsr2.pin_id = p.id
         and gsr2.deleted_at is null
    );

grant select on public.v_growth_stage_observations to authenticated;

-- ----- 5. Storage bucket --------------------------------------------------
-- Path convention: {vineyard_id}/{growth_stage_record_id}/{uuid}.jpg
insert into storage.buckets (id, name, public)
values ('growth-stage-photos', 'growth-stage-photos', false)
on conflict (id) do nothing;

drop policy if exists "growth_stage_photos_select_members" on storage.objects;
create policy "growth_stage_photos_select_members"
on storage.objects for select
to authenticated
using (
  bucket_id = 'growth-stage-photos'
  and public.is_vineyard_member(public.storage_first_folder_uuid(name))
);

drop policy if exists "growth_stage_photos_insert_members" on storage.objects;
create policy "growth_stage_photos_insert_members"
on storage.objects for insert
to authenticated
with check (
  bucket_id = 'growth-stage-photos'
  and public.has_vineyard_role(
        public.storage_first_folder_uuid(name),
        array['owner','manager','supervisor','operator']
      )
);

drop policy if exists "growth_stage_photos_update_members" on storage.objects;
create policy "growth_stage_photos_update_members"
on storage.objects for update
to authenticated
using (
  bucket_id = 'growth-stage-photos'
  and public.has_vineyard_role(
        public.storage_first_folder_uuid(name),
        array['owner','manager','supervisor','operator']
      )
)
with check (
  bucket_id = 'growth-stage-photos'
  and public.has_vineyard_role(
        public.storage_first_folder_uuid(name),
        array['owner','manager','supervisor','operator']
      )
);

drop policy if exists "growth_stage_photos_delete_managers" on storage.objects;
create policy "growth_stage_photos_delete_managers"
on storage.objects for delete
to authenticated
using (
  bucket_id = 'growth-stage-photos'
  and public.has_vineyard_role(
        public.storage_first_folder_uuid(name),
        array['owner','manager','supervisor']
      )
);

-- ----- 6. Backfill from existing growth-stage pins -----------------------
-- Idempotent: skips pins that already have a mirrored row (active or
-- soft-deleted) via the unique index on pin_id. Existing pins are not
-- modified.
insert into public.growth_stage_records (
  id,
  vineyard_id,
  paddock_id,
  pin_id,
  stage_code,
  stage_label,
  variety,
  variety_id,
  observed_at,
  latitude,
  longitude,
  row_number,
  side,
  notes,
  photo_paths,
  recorded_by_name,
  created_by,
  updated_by,
  created_at,
  updated_at,
  client_updated_at,
  sync_version,
  deleted_at
)
select
  gen_random_uuid()                  as id,
  p.vineyard_id                      as vineyard_id,
  p.paddock_id                       as paddock_id,
  p.id                               as pin_id,
  p.growth_stage_code                as stage_code,
  null::text                         as stage_label,
  null::text                         as variety,
  null::uuid                         as variety_id,
  coalesce(p.created_at, now())      as observed_at,
  p.latitude                         as latitude,
  p.longitude                        as longitude,
  p.row_number                       as row_number,
  p.side                             as side,
  p.notes                            as notes,
  case
    when p.photo_path is not null then array[p.photo_path]
    else '{}'::text[]
  end                                as photo_paths,
  p.completed_by                     as recorded_by_name,
  p.created_by                       as created_by,
  p.updated_by                       as updated_by,
  coalesce(p.created_at, now())      as created_at,
  coalesce(p.updated_at, now())      as updated_at,
  p.client_updated_at                as client_updated_at,
  1                                  as sync_version,
  null::timestamptz                  as deleted_at
from public.pins p
where p.deleted_at is null
  and p.growth_stage_code is not null
  and not exists (
    select 1 from public.growth_stage_records gsr
     where gsr.pin_id = p.id
  )
on conflict do nothing;
