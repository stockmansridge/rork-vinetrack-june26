-- =============================================================================
-- 181: Pruning Yield Calculator — shared per-block saved configuration
--
-- Promotes the Pruning Yield Calculator's per-block inputs from device-local
-- storage (iOS UserDefaults / Android SharedPreferences) to one shared synced
-- record per vineyard block, so iOS, Android and the Lovable portal all read
-- and write the SAME saved pruning-yield configuration.
--
-- Contract summary
--   Table  public.pruning_yield_settings — ONE active row per
--          (vineyard_id, paddock_id), enforced by a unique constraint.
--          Clients upsert with on_conflict=vineyard_id,paddock_id so editing
--          never duplicates rows and two devices minting different ids for
--          the same block converge on a single record.
--   RPC    soft_delete_pruning_yield_settings(p_id uuid)
--
-- ONLY the INPUT ASSUMPTIONS are persisted. Calculated outputs (buds/vine,
-- bunches/ha, yield kg/ha, yield t/ha, block total tonnes) are derived on
-- every client with the shared formula so they can never go stale:
--
--   buds_per_vine  = buds_per_spur × spurs_per_vine        (spur method)
--                  = buds_per_cane × canes_per_vine        (cane method)
--   bunches_per_ha = bunches_per_bud × buds_per_vine × vines_per_ha
--   yield_kg_ha    = bunches_per_ha × bunch_weight_grams ÷ 1000
--   yield_t_ha     = yield_kg_ha ÷ 1000
--   block_total_t  = yield_t_ha × block area (ha), when area > 0
--
-- paddock_id intentionally has NO foreign key (matching picking_records and
-- the block_results contract): clients only surface settings for blocks that
-- still exist, so a removed block's row simply becomes invisible.
--
-- Field defaults mirror the long-standing client defaults: spur method,
-- 1.5 bunches/bud, 2 buds/spur, 6 spurs/vine, 10 buds/cane, 4 canes/vine,
-- 120 g bunch weight. vines_per_ha is nullable — when null, clients seed it
-- from the block's vine count ÷ area.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. pruning_yield_settings table
-- ---------------------------------------------------------------------------
create table if not exists public.pruning_yield_settings (
  id uuid primary key default gen_random_uuid(),
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  paddock_id uuid not null,
  prune_method text not null default 'spur',   -- 'spur' | 'cane'
  bunches_per_bud double precision not null default 1.5,
  buds_per_spur double precision not null default 2,
  spurs_per_vine double precision not null default 6,
  buds_per_cane double precision not null default 10,
  canes_per_vine double precision not null default 4,
  vines_per_ha double precision null,          -- null = derive from block config
  bunch_weight_grams double precision not null default 120,
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz null,
  client_updated_at timestamptz null,
  sync_version integer not null default 1
);

-- One saved configuration per block — the client upsert target.
do $$
begin
  alter table public.pruning_yield_settings
    add constraint pruning_yield_settings_vineyard_paddock_key
    unique (vineyard_id, paddock_id);
exception when duplicate_object then null;
end $$;

do $$
begin
  alter table public.pruning_yield_settings
    add constraint pruning_yield_settings_method_check
    check (prune_method in ('spur', 'cane'));
exception when duplicate_object then null;
end $$;

do $$
begin
  alter table public.pruning_yield_settings
    add constraint pruning_yield_settings_non_negative
    check (
      bunches_per_bud >= 0
      and buds_per_spur >= 0
      and spurs_per_vine >= 0
      and buds_per_cane >= 0
      and canes_per_vine >= 0
      and bunch_weight_grams >= 0
      and (vines_per_ha is null or vines_per_ha >= 0)
    );
exception when duplicate_object then null;
end $$;

create index if not exists idx_pruning_yield_settings_updated_at
  on public.pruning_yield_settings (updated_at);

-- ---------------------------------------------------------------------------
-- 2. Input normalisation + upsert resurrection
-- ---------------------------------------------------------------------------
create or replace function public.pruning_yield_settings_before_write()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Accept 'Spur' / ' CANE ' etc. from any client, store canonical lowercase.
  new.prune_method := lower(trim(coalesce(new.prune_method, 'spur')));
  -- A genuine client upsert (client_updated_at changed) resurrects a
  -- soft-deleted row: the block has ONE current configuration again. The
  -- soft-delete RPC does not touch client_updated_at, so it is unaffected.
  if tg_op = 'UPDATE' and new.client_updated_at is distinct from old.client_updated_at then
    new.deleted_at := null;
  end if;
  return new;
end;
$$;

create or replace trigger pruning_yield_settings_before_write
before insert or update on public.pruning_yield_settings
for each row execute function public.pruning_yield_settings_before_write();

create or replace trigger pruning_yield_settings_set_updated_at
before update on public.pruning_yield_settings
for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- 3. RLS — identical shape to picking_records / historical_yield_records
-- ---------------------------------------------------------------------------
alter table public.pruning_yield_settings enable row level security;

drop policy if exists "pruning_yield_settings_select_members" on public.pruning_yield_settings;
create policy "pruning_yield_settings_select_members"
on public.pruning_yield_settings for select
to authenticated
using (public.is_vineyard_member(vineyard_id));

drop policy if exists "pruning_yield_settings_insert_members" on public.pruning_yield_settings;
create policy "pruning_yield_settings_insert_members"
on public.pruning_yield_settings for insert
to authenticated
with check (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor','operator']));

drop policy if exists "pruning_yield_settings_update_members" on public.pruning_yield_settings;
create policy "pruning_yield_settings_update_members"
on public.pruning_yield_settings for update
to authenticated
using (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor','operator']))
with check (public.has_vineyard_role(vineyard_id, array['owner','manager','supervisor','operator']));

drop policy if exists "pruning_yield_settings_no_client_hard_delete" on public.pruning_yield_settings;
create policy "pruning_yield_settings_no_client_hard_delete"
on public.pruning_yield_settings for delete
to authenticated
using (false);

-- ---------------------------------------------------------------------------
-- 4. Soft delete RPC (owner/manager/supervisor)
-- ---------------------------------------------------------------------------
create or replace function public.soft_delete_pruning_yield_settings(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_vineyard_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select vineyard_id into v_vineyard_id from public.pruning_yield_settings where id = p_id;
  if v_vineyard_id is null then raise exception 'Pruning yield settings not found'; end if;
  if not public.has_vineyard_role(v_vineyard_id, array['owner','manager','supervisor']) then
    raise exception 'Insufficient permissions to delete pruning yield settings';
  end if;
  update public.pruning_yield_settings
     set deleted_at = now(), updated_by = auth.uid()
   where id = p_id;
end;
$$;
revoke all on function public.soft_delete_pruning_yield_settings(uuid) from public;
grant execute on function public.soft_delete_pruning_yield_settings(uuid) to authenticated;

notify pgrst, 'reload schema';
