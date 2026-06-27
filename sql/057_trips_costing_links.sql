-- Phase 1: Trip costing links + member operator category link.
-- Adds the foreign-key columns required to derive labour/fuel cost from
-- existing data (operator_categories.cost_per_hour, tractors.fuel_usage_l_per_hour,
-- fuel_purchases). No cost is stored on the trip itself — calculations happen
-- in the client (TripCostService) and are gated by role-based visibility.

-- =====================================================================
-- trips: tractor + operator linkage
-- =====================================================================
alter table public.trips
  add column if not exists tractor_id uuid null references public.tractors(id) on delete set null;

alter table public.trips
  add column if not exists operator_user_id uuid null references auth.users(id) on delete set null;

alter table public.trips
  add column if not exists operator_category_id uuid null references public.operator_categories(id) on delete set null;

create index if not exists idx_trips_tractor_id on public.trips (tractor_id);
create index if not exists idx_trips_operator_user_id on public.trips (operator_user_id);

-- =====================================================================
-- vineyard_members: per-member default operator category
-- =====================================================================
-- Used as a fallback for trip cost calculations when trips.operator_category_id
-- is not explicitly set. Owners/managers manage these assignments via
-- Operator Categories (assign users) UI.
alter table public.vineyard_members
  add column if not exists operator_category_id uuid null references public.operator_categories(id) on delete set null;

create index if not exists idx_vineyard_members_operator_category_id
  on public.vineyard_members (operator_category_id);
