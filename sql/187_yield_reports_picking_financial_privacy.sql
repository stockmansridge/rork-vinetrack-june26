-- =============================================================================
-- 187: Yield final parity — picking-record financial privacy by role +
--      shared bunch-count sampling default + latest-completed session index
--
-- 1. FINANCIAL PRIVACY (Picking Log). sql/180 exposed `sold_to`,
--    `price_per_tonne` and the generated `grape_value` to EVERY vineyard
--    member through the row-wide select policy. Commercial sale data must be
--    readable by owner/manager only — and the restriction must hold at the
--    API, not just in app UI.
--
--    Chosen pattern: RESTRICTED PROJECTION via a companion table.
--      * New table  public.picking_record_financials  (owner/manager-only
--        RLS) becomes the ONLY place commercial values are stored.
--      * A BEFORE INSERT OR UPDATE trigger on picking_records routes any
--        client-supplied sold_to / price_per_tonne into the companion table
--        (when the writer is a financial editor) and ALWAYS strips them from
--        the base row. The base columns therefore read back NULL for every
--        role — old app builds keep working, they simply stop seeing money.
--      * grape_value stays a generated column on the base table but is now
--        permanently NULL (price is never stored there); the authoritative
--        value is computed from the companion table.
--      * RPC get_picking_record_financials(p_vineyard_id) returns the
--        commercial fields (plus computed grape_value) to owner/manager and
--        raises 42501 for everyone else.
--      * Both totals views are recreated (same columns, same order) so
--        total_grape_value derives from the companion table via the caller's
--        RLS: managers keep real totals, other roles read NULL.
--
--    Why NOT column-level privileges: shipped mobile builds and the portal
--    read picking_records with select=*, which Supabase documents as failing
--    outright once column grants are revoked. Why NOT a masking view swap:
--    the iOS sync upserts picking_records with ON CONFLICT, which Postgres
--    does not support on trigger-updatable views.
--
--    `sold` (boolean) DELIBERATELY stays member-visible: it is operational
--    status (the fruit left the property / purpose of the pick) and carries
--    no monetary value or counterparty. Auditted per the privacy brief;
--    documented in docs/portal-handoff-yield-bunch-count-trips.md.
--
--    Trigger semantics (protects data against old builds echoing masked
--    NULLs back on edit):
--      * writer is owner/manager (or server-side, auth.uid() IS NULL):
--          - sold = false                         -> companion row deleted
--            (sql/180 contract: unsold picks carry no commercial fields)
--          - sold = true, any value non-null      -> companion upserted from
--            the body (both fields taken as sent, so clearing one while
--            keeping the other works)
--          - sold = true, both values null        -> NO-OP. Never treated as
--            a clear: post-187 clients read masked NULLs and echo them back
--            on unrelated edits.
--      * any other role: companion is never touched.
--    All writers must send the FULL financial state on update (both mobile
--    apps already do; portal handoff documents the same rule).
--
-- 2. SHARED SAMPLING DEFAULT. Bunch Count Trips prompt for a sample density
--    before route generation. The density (samples per hectare, the existing
--    session concept from the canonical payload) is now a vineyard-level
--    operational setting so a changed value becomes the default for the next
--    trip on every device. Column + get/set RPC pair per the sql/099/108
--    house pattern; writers = every role that can run a trip (same roles as
--    yield_estimation_sessions writes).
--
-- 3. LATEST-COMPLETED INDEX. Yield Reports resolve the current Yield
--    Estimate from the LATEST COMPLETED session per vintage/block; a partial
--    index keeps that lookup cheap for the portal.
--
-- No changes to the yield_estimation_sessions payload contract — the Bunch
-- Count Trip redesign extends the existing camelCase payload additively
-- (client-side; see the portal handoff doc).
--
-- Verification: sql/tests/187_picking_financial_privacy_tests.sql
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Companion table: commercial sale data, owner/manager-only
-- ---------------------------------------------------------------------------
-- picking_record_id intentionally has NO foreign key to picking_records: the
-- routing trigger fires BEFORE INSERT (the parent row does not exist yet) and
-- picking_records rows are soft-deleted only (hard delete is policy-blocked),
-- so orphans cannot arise through normal operation. vineyard cascade covers
-- whole-vineyard removal.
create table if not exists public.picking_record_financials (
  picking_record_id uuid primary key,
  vineyard_id uuid not null references public.vineyards(id) on delete cascade,
  sold_to text null,
  price_per_tonne double precision null,
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now()
);

do $$
begin
  alter table public.picking_record_financials
    add constraint picking_record_financials_price_non_negative
    check (price_per_tonne is null or price_per_tonne >= 0);
exception when duplicate_object then null;
end $$;

create index if not exists idx_picking_record_financials_vineyard
  on public.picking_record_financials (vineyard_id);

alter table public.picking_record_financials enable row level security;

-- Owner/manager may read directly; ALL writes go through the security-definer
-- routing trigger, so no insert/update/delete policies exist (denied by
-- default under RLS).
drop policy if exists "picking_record_financials_select_managers" on public.picking_record_financials;
create policy "picking_record_financials_select_managers"
on public.picking_record_financials for select
to authenticated
using (public.has_vineyard_role(vineyard_id, array['owner','manager']));

grant select on public.picking_record_financials to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Routing trigger — strips commercial values off the base row and stores
--    them in the companion table when the writer is a financial editor.
--    Named so it fires AFTER picking_records_before_write (alphabetical
--    ordering of BEFORE triggers), which nulls financials on unsold rows and
--    derives the server-authoritative vintage first.
-- ---------------------------------------------------------------------------
create or replace function public.picking_records_route_financials()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_financial_editor boolean;
begin
  -- Server-side writes (migrations, service role) count as financial editors.
  v_financial_editor := auth.uid() is null
    or public.has_vineyard_role(new.vineyard_id, array['owner','manager']);

  if v_financial_editor then
    if not new.sold then
      delete from public.picking_record_financials
       where picking_record_id = new.id;
    elsif new.sold_to is not null or new.price_per_tonne is not null then
      insert into public.picking_record_financials
        (picking_record_id, vineyard_id, sold_to, price_per_tonne, updated_by, updated_at)
      values
        (new.id, new.vineyard_id, new.sold_to, new.price_per_tonne, auth.uid(), now())
      on conflict (picking_record_id) do update
        set sold_to         = excluded.sold_to,
            price_per_tonne = excluded.price_per_tonne,
            updated_by      = excluded.updated_by,
            updated_at      = now();
    end if;
    -- sold = true with BOTH values null: no-op by design (see header).
  end if;

  -- The base row never stores commercial values again.
  new.sold_to := null;
  new.price_per_tonne := null;
  return new;
end;
$$;

drop trigger if exists picking_records_route_financials on public.picking_records;
create trigger picking_records_route_financials
before insert or update on public.picking_records
for each row execute function public.picking_records_route_financials();

-- ---------------------------------------------------------------------------
-- 3. Backfill: move existing commercial values into the companion table,
--    then strip them from the base rows. Idempotent (second run matches
--    nothing). The strip UPDATE deliberately bumps updated_at so clients
--    re-pull the now-masked rows.
-- ---------------------------------------------------------------------------
insert into public.picking_record_financials
  (picking_record_id, vineyard_id, sold_to, price_per_tonne)
select id, vineyard_id, sold_to, price_per_tonne
  from public.picking_records
 where sold
   and (sold_to is not null or price_per_tonne is not null)
on conflict (picking_record_id) do nothing;

update public.picking_records
   set sold_to = null,
       price_per_tonne = null
 where sold_to is not null
    or price_per_tonne is not null;

-- ---------------------------------------------------------------------------
-- 4. Owner/manager read RPC — commercial fields + computed grape value
-- ---------------------------------------------------------------------------
create or replace function public.get_picking_record_financials(
  p_vineyard_id uuid
) returns table (
  picking_record_id uuid,
  sold_to           text,
  price_per_tonne   double precision,
  grape_value       double precision
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  if not public.has_vineyard_role(p_vineyard_id, array['owner','manager']) then
    raise exception 'Owner or manager role required' using errcode = '42501';
  end if;

  return query
    select f.picking_record_id,
           f.sold_to,
           f.price_per_tonne,
           case
             when pr.sold and f.price_per_tonne is not null
             then (pr.weight_kg / 1000.0) * f.price_per_tonne
           end
      from public.picking_record_financials f
      join public.picking_records pr on pr.id = f.picking_record_id
     where f.vineyard_id = p_vineyard_id
       and pr.deleted_at is null;
end;
$$;

revoke all on function public.get_picking_record_financials(uuid) from public;
grant execute on function public.get_picking_record_financials(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Totals views: identical column lists, but total_grape_value now derives
--    from the companion table THROUGH THE CALLER'S RLS (security_invoker):
--    managers keep real totals, everyone else reads NULL.
-- ---------------------------------------------------------------------------
create or replace view public.picking_yield_totals
with (security_invoker = on) as
select
  pr.vineyard_id,
  pr.vintage,
  pr.paddock_id,
  pr.variety_name,
  max(pr.paddock_name)                    as paddock_name,
  count(*)::integer                       as pick_count,
  sum(pr.weight_kg)                       as total_weight_kg,
  sum(pr.weight_kg) / 1000.0              as actual_yield_tonnes,
  min(pr.picked_at)                       as first_picked_at,
  max(pr.picked_at)                       as last_picked_at,
  sum(
    case
      when pr.sold and f.price_per_tonne is not null
      then (pr.weight_kg / 1000.0) * f.price_per_tonne
    end
  )                                       as total_grape_value
from public.picking_records pr
left join public.picking_record_financials f
  on f.picking_record_id = pr.id
where pr.deleted_at is null
group by pr.vineyard_id, pr.vintage, pr.paddock_id, pr.variety_name;

grant select on public.picking_yield_totals to authenticated;

create or replace view public.picking_yield_planting_totals
with (security_invoker = on) as
with base as (
  select pr.*,
         case
           when pr.sold and f.price_per_tonne is not null
           then (pr.weight_kg / 1000.0) * f.price_per_tonne
         end as companion_grape_value
  from public.picking_records pr
  left join public.picking_record_financials f
    on f.picking_record_id = pr.id
  where pr.deleted_at is null
),
totals as (
  select
    vineyard_id,
    vintage,
    paddock_id,
    planting_group_key,
    case
      when planting_group_key is null then lower(btrim(variety_name))
    end                                     as unlinked_variety_key,
    max(paddock_name)                       as paddock_name,
    max(variety_name)                       as variety_name,
    max(clone)                              as clone,
    max(rootstock)                          as rootstock,
    count(*)::integer                       as pick_count,
    sum(weight_kg)                          as total_weight_kg,
    sum(weight_kg) / 1000.0                 as actual_yield_tonnes,
    min(picked_at)                          as first_picked_at,
    max(picked_at)                          as last_picked_at,
    sum(companion_grape_value)              as total_grape_value
  from base
  group by vineyard_id, vintage, paddock_id, planting_group_key,
    case
      when planting_group_key is null then lower(btrim(variety_name))
    end
),
members as (
  select
    b.vineyard_id,
    b.vintage,
    b.paddock_id,
    b.planting_group_key,
    array_agg(distinct m order by m)        as member_allocation_ids
  from base b
  cross join lateral unnest(coalesce(b.variety_allocation_ids, '{}'::uuid[])) as m
  where b.planting_group_key is not null
  group by b.vineyard_id, b.vintage, b.paddock_id, b.planting_group_key
)
select
  t.vineyard_id,
  t.vintage,
  t.paddock_id,
  t.planting_group_key,
  t.unlinked_variety_key,
  t.paddock_name,
  t.variety_name,
  t.clone,
  t.rootstock,
  m.member_allocation_ids,
  t.pick_count,
  t.total_weight_kg,
  t.actual_yield_tonnes,
  t.first_picked_at,
  t.last_picked_at,
  t.total_grape_value
from totals t
left join members m
  on  m.vineyard_id        = t.vineyard_id
  and m.vintage            = t.vintage
  and m.paddock_id         = t.paddock_id
  and m.planting_group_key = t.planting_group_key;

grant select on public.picking_yield_planting_totals to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Vineyard-level Bunch Count Trip sampling default (samples per hectare —
--    the existing session payload concept). Members read; every trip-capable
--    role may write (a changed value becomes the shared default, sql brief).
-- ---------------------------------------------------------------------------
alter table public.vineyards
  add column if not exists yield_samples_per_hectare integer not null default 20;

do $$
begin
  alter table public.vineyards
    add constraint vineyards_yield_samples_per_hectare_range
    check (yield_samples_per_hectare between 1 and 100);
exception when duplicate_object then null;
end $$;

create or replace function public.get_vineyard_yield_sampling_settings(
  p_vineyard_id uuid
) returns table (
  vineyard_id         uuid,
  samples_per_hectare integer
)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  if not public.is_vineyard_member(p_vineyard_id) then
    raise exception 'Not a vineyard member' using errcode = '42501';
  end if;
  return query
    select v.id, v.yield_samples_per_hectare
      from public.vineyards v
     where v.id = p_vineyard_id;
end;
$$;

revoke all on function public.get_vineyard_yield_sampling_settings(uuid) from public;
grant execute on function public.get_vineyard_yield_sampling_settings(uuid) to authenticated;

create or replace function public.set_vineyard_yield_sampling_settings(
  p_vineyard_id         uuid,
  p_samples_per_hectare integer
) returns table (
  vineyard_id         uuid,
  samples_per_hectare integer
)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  if not public.has_vineyard_role(p_vineyard_id, array['owner','manager','supervisor','operator']) then
    raise exception 'Vineyard role required' using errcode = '42501';
  end if;
  if p_samples_per_hectare is null
     or p_samples_per_hectare < 1
     or p_samples_per_hectare > 100 then
    raise exception 'samples_per_hectare must be between 1 and 100';
  end if;

  update public.vineyards v
     set yield_samples_per_hectare = p_samples_per_hectare,
         updated_at = now()
   where v.id = p_vineyard_id;

  return query
    select v.id, v.yield_samples_per_hectare
      from public.vineyards v
     where v.id = p_vineyard_id;
end;
$$;

revoke all on function public.set_vineyard_yield_sampling_settings(uuid, integer) from public;
grant execute on function public.set_vineyard_yield_sampling_settings(uuid, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. Latest-completed Bunch Count Trip lookup (current Yield Estimate rule)
-- ---------------------------------------------------------------------------
create index if not exists idx_yield_sessions_latest_completed
  on public.yield_estimation_sessions (vineyard_id, completed_at desc)
  where is_completed and deleted_at is null;

notify pgrst, 'reload schema';
