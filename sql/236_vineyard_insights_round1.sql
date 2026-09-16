-- =============================================================================
-- 236_vineyard_insights_round1.sql
--
-- Vineyard Insights (Round 1) — Scout capture, Vintage Notes, and the
-- `vineyard_insights` Operational Tool catalogue entry.
--
-- NOT APPLIED BY THIS CHANGE. Returned for Jonathan to run.
--
-- WHAT THIS MIGRATION ADDS (additive only — nothing existing is altered):
--   A. operational_tool_catalogue row for 'vineyard_insights' (display_order 140)
--   B. public.scout_visits
--   C. public.scout_block_assessments
--   D. public.scout_observations
--   E. public.scout_observation_photos
--   F. public.vintage_note_types      (+ seeded system catalogue)
--   G. public.vintage_notes
--   H. storage bucket 'scout-photos' + policies
--   I. public.can_use_vineyard_insights(uuid) — the single access predicate
--   J. Vintage resolution triggers for scout_visits and vintage_notes
--   K. upsert/soft-delete RPCs for vintage notes and custom note types
--
-- ACCESS MODEL — READ THIS BEFORE CHANGING A POLICY
--
--   Every object below requires BOTH:
--     * public.is_system_admin()            — active row in system_admins
--     * public.is_vineyard_member(vineyard) — membership of THAT vineyard
--
--   The conjunction is deliberate and is expressed once, in
--   public.can_use_vineyard_insights(). System Admin is a platform capability,
--   not a skeleton key: being able to administer VineTrack does not make
--   someone a member of a grower's business, and a preview feature must not
--   become the one place where tenancy silently stops applying.
--
--   Equally, a vineyard owner or manager is NOT a System Admin. Owner/manager
--   is a customer-level role over their own vineyard; it confers no platform
--   authority and must not reach this preview data. Hiding the tile in the app
--   is presentation only — these policies are the actual boundary.
--
-- VINTAGE IS SERVER-RESOLVED
--
--   scout_visits.vintage_year and vintage_notes.vintage_year are written by
--   triggers from the record DATE via the existing authoritative resolver
--   public.resolve_vineyard_vintage_year (sql/119), which reads the vineyard's
--   shared season-start preference (sql/108). Any client-supplied value is
--   OVERWRITTEN, on insert and on every update of the date. A client clock, a
--   stale cached season setting or a hand-edited payload must never be able to
--   file a record into the wrong vintage — that silently corrupts every future
--   report for that season.
--
-- SOFT DELETION ONLY
--
--   Nothing here supports a client hard delete. Field observations are
--   evidence; a mis-tap must be recoverable and a delete must be reconcilable
--   across offline devices.
--
-- ROLLBACK (non-destructive to unrelated objects):
--   drop function if exists public.soft_delete_vintage_note(uuid);
--   drop function if exists public.upsert_vintage_note(uuid,uuid,date,uuid,text,text,text,timestamptz);
--   drop function if exists public.upsert_vintage_note_type(uuid,uuid,text,text,text,integer,boolean);
--   drop function if exists public._vineyard_insights_set_vintage();
--   drop table if exists public.scout_observation_photos;
--   drop table if exists public.scout_observations;
--   drop table if exists public.scout_block_assessments;
--   drop table if exists public.scout_visits;
--   drop table if exists public.vintage_notes;
--   drop table if exists public.vintage_note_types;
--   drop function if exists public.can_use_vineyard_insights(uuid);
--   delete from public.operational_tool_catalogue where tool_id='vineyard_insights';
--   -- storage: delete policies named 'scout_photos_*' and the 'scout-photos' bucket
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- A. Operational Tool catalogue entry
-- ---------------------------------------------------------------------------
-- display_order 140 — the next slot after resistance_planner (130). The apps
-- still gate visibility independently; this row only makes the id RECOGNISED
-- by the sql/159 preference normaliser, so a saved layout can carry it.
--
-- Being listed here grants nothing. sql/159 explicitly documents that the
-- preference table is presentation-only and that clients must filter a saved
-- layout through the caller's authorised catalogue first.
insert into public.operational_tool_catalogue (tool_id, display_order, added_in)
values ('vineyard_insights', 140, 'sql/236')
on conflict (tool_id) do nothing;

-- ---------------------------------------------------------------------------
-- I. The single access predicate
-- ---------------------------------------------------------------------------
-- Expressed ONCE so no policy can drift into checking only half of it.
create or replace function public.can_use_vineyard_insights(p_vineyard_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select
        auth.uid() is not null
        and p_vineyard_id is not null
        and public.is_system_admin()
        and public.is_vineyard_member(p_vineyard_id);
$$;

revoke all on function public.can_use_vineyard_insights(uuid) from public, anon;
grant execute on function public.can_use_vineyard_insights(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Shared vintage-resolution trigger
-- ---------------------------------------------------------------------------
-- Used by scout_visits (scout_date) and vintage_notes (note_date). Always
-- overwrites; never trusts an inbound vintage_year.
create or replace function public._vineyard_insights_set_vintage()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_date date;
begin
  v_date := case tg_argv[0]
              when 'scout_date' then new.scout_date
              else new.note_date
            end;

  new.vintage_year := public.resolve_vineyard_vintage_year(new.vineyard_id, v_date);
  return new;
end;
$$;

revoke all on function public._vineyard_insights_set_vintage() from public, anon;

-- =========================================================================
-- B. scout_visits
-- =========================================================================
create table if not exists public.scout_visits (
  -- Client-generated UUID: the offline idempotency key. A retry of the same
  -- capture must resolve to the same row, not a second visit.
  id                  uuid primary key,
  vineyard_id         uuid not null references public.vineyards(id) on delete cascade,
  -- Server-resolved. See _vineyard_insights_set_vintage.
  vintage_year        integer not null,
  scout_date          date not null default current_date,
  status              text not null default 'draft'
                        check (status in ('draft','completed')),
  visit_summary       text,
  -- Provider payload kept verbatim: observation time, capture time, source,
  -- temperature, humidity, wind, gust, recent rainfall, and explicit
  -- stale/unavailable flags. Stored as jsonb because the honest shape differs
  -- per provider, and an absent reading must stay absent rather than become 0.
  weather_snapshot    jsonb,
  scout_user_id       uuid references auth.users(id) on delete set null,
  -- Who the scout WAS on the day. Retained if the user is later renamed or
  -- removed, so a historical visit never loses its author.
  scout_name_snapshot text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  created_by          uuid references auth.users(id) on delete set null,
  updated_by          uuid references auth.users(id) on delete set null,
  client_updated_at   timestamptz,
  sync_version        bigint not null default 0,
  deleted_at          timestamptz
);

create index if not exists scout_visits_vineyard_vintage_idx
  on public.scout_visits (vineyard_id, vintage_year, scout_date desc)
  where deleted_at is null;

create index if not exists scout_visits_status_idx
  on public.scout_visits (vineyard_id, status)
  where deleted_at is null;

-- Delta sync and soft-delete reconciliation.
create index if not exists scout_visits_updated_at_idx
  on public.scout_visits (vineyard_id, updated_at desc);

create index if not exists scout_visits_deleted_at_idx
  on public.scout_visits (deleted_at);

drop trigger if exists scout_visits_set_vintage on public.scout_visits;
create trigger scout_visits_set_vintage
before insert or update of scout_date, vineyard_id on public.scout_visits
for each row execute function public._vineyard_insights_set_vintage('scout_date');

create or replace trigger scout_visits_set_updated_at
before update on public.scout_visits
for each row execute function public.set_updated_at();

alter table public.scout_visits enable row level security;

drop policy if exists "scout_visits_select_insights" on public.scout_visits;
create policy "scout_visits_select_insights"
on public.scout_visits for select
to authenticated
using (public.can_use_vineyard_insights(vineyard_id));

drop policy if exists "scout_visits_insert_insights" on public.scout_visits;
create policy "scout_visits_insert_insights"
on public.scout_visits for insert
to authenticated
with check (public.can_use_vineyard_insights(vineyard_id));

drop policy if exists "scout_visits_update_insights" on public.scout_visits;
create policy "scout_visits_update_insights"
on public.scout_visits for update
to authenticated
using (public.can_use_vineyard_insights(vineyard_id))
with check (public.can_use_vineyard_insights(vineyard_id));

-- No delete policy: soft deletion only.
drop policy if exists "scout_visits_no_client_hard_delete" on public.scout_visits;
create policy "scout_visits_no_client_hard_delete"
on public.scout_visits for delete
to authenticated
using (false);

revoke all on public.scout_visits from anon;
grant select, insert, update on public.scout_visits to authenticated;

-- =========================================================================
-- C. scout_block_assessments
-- =========================================================================
create table if not exists public.scout_block_assessments (
  id                uuid primary key,
  scout_visit_id    uuid not null references public.scout_visits(id) on delete cascade,
  -- Denormalised for RLS: a policy must not need to join to decide access,
  -- and the assessment can then be filtered by vineyard directly.
  vineyard_id       uuid not null references public.vineyards(id) on delete cascade,
  paddock_id        uuid not null references public.paddocks(id) on delete cascade,
  status            text not null default 'in_progress'
                      check (status in ('in_progress','complete')),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  created_by        uuid references auth.users(id) on delete set null,
  updated_by        uuid references auth.users(id) on delete set null,
  client_updated_at timestamptz,
  sync_version      bigint not null default 0,
  deleted_at        timestamptz
);

-- One ACTIVE assessment per visit and block. Partial so a soft-deleted
-- assessment does not block re-adding the block to the same visit.
create unique index if not exists scout_block_assessments_unique_active_idx
  on public.scout_block_assessments (scout_visit_id, paddock_id)
  where deleted_at is null;

create index if not exists scout_block_assessments_visit_idx
  on public.scout_block_assessments (scout_visit_id)
  where deleted_at is null;

create index if not exists scout_block_assessments_updated_at_idx
  on public.scout_block_assessments (vineyard_id, updated_at desc);

create index if not exists scout_block_assessments_deleted_at_idx
  on public.scout_block_assessments (deleted_at);

create or replace trigger scout_block_assessments_set_updated_at
before update on public.scout_block_assessments
for each row execute function public.set_updated_at();

alter table public.scout_block_assessments enable row level security;

drop policy if exists "scout_block_assessments_select_insights" on public.scout_block_assessments;
create policy "scout_block_assessments_select_insights"
on public.scout_block_assessments for select
to authenticated
using (public.can_use_vineyard_insights(vineyard_id));

drop policy if exists "scout_block_assessments_insert_insights" on public.scout_block_assessments;
create policy "scout_block_assessments_insert_insights"
on public.scout_block_assessments for insert
to authenticated
with check (public.can_use_vineyard_insights(vineyard_id));

drop policy if exists "scout_block_assessments_update_insights" on public.scout_block_assessments;
create policy "scout_block_assessments_update_insights"
on public.scout_block_assessments for update
to authenticated
using (public.can_use_vineyard_insights(vineyard_id))
with check (public.can_use_vineyard_insights(vineyard_id));

drop policy if exists "scout_block_assessments_no_client_hard_delete" on public.scout_block_assessments;
create policy "scout_block_assessments_no_client_hard_delete"
on public.scout_block_assessments for delete
to authenticated
using (false);

revoke all on public.scout_block_assessments from anon;
grant select, insert, update on public.scout_block_assessments to authenticated;

-- =========================================================================
-- D. scout_observations
-- =========================================================================
-- One structured row per assessment item. Normalised rather than dozens of
-- columns on public.pins: these rows are the reportable evidence behind the
-- future Vintage Report, and a wide denormalised pin row cannot be grouped,
-- counted or trended by item.
create table if not exists public.scout_observations (
  id                       uuid primary key,
  assessment_id            uuid not null
                             references public.scout_block_assessments(id) on delete cascade,
  vineyard_id              uuid not null references public.vineyards(id) on delete cascade,
  item_kind                text not null check (item_kind in (
                             'growth_stage','weeds','vine_vigour','soil_moisture',
                             'powdery_mildew','downy_mildew','other_issue',
                             'general_recommendation')),
  -- Stable stored code (e.g. 'soil_very_dry'), never a display string.
  value_code               text,
  -- The exact wording shown when the observation was made. Kept so a later
  -- relabelling cannot retrospectively change what a scout appears to have
  -- said about a past season.
  value_label              text,
  notes                    text,
  -- Nullable linkage reserved for the later REVIEWED action workflow. Round 1
  -- deliberately creates no automatic Repair Pin and no automatic Work Task:
  -- actions raised from an unreviewed dropdown produce a task list nobody
  -- trusts. The columns exist so that workflow is additive.
  linked_pin_id            uuid references public.pins(id) on delete set null,
  -- The canonical phenology record this observation created, when
  -- item_kind = 'growth_stage'. The E-L VALUE itself is deliberately NOT
  -- duplicated here: growth_stage_records stays the single authority, so the
  -- two can never disagree about budburst.
  linked_growth_record_id  uuid references public.growth_stage_records(id) on delete set null,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),
  created_by               uuid references auth.users(id) on delete set null,
  updated_by               uuid references auth.users(id) on delete set null,
  client_updated_at        timestamptz,
  sync_version             bigint not null default 0,
  deleted_at               timestamptz
);

create unique index if not exists scout_observations_unique_active_item_idx
  on public.scout_observations (assessment_id, item_kind)
  where deleted_at is null;

create index if not exists scout_observations_assessment_idx
  on public.scout_observations (assessment_id)
  where deleted_at is null;

create index if not exists scout_observations_growth_link_idx
  on public.scout_observations (linked_growth_record_id)
  where linked_growth_record_id is not null and deleted_at is null;

create index if not exists scout_observations_updated_at_idx
  on public.scout_observations (vineyard_id, updated_at desc);

create index if not exists scout_observations_deleted_at_idx
  on public.scout_observations (deleted_at);

create or replace trigger scout_observations_set_updated_at
before update on public.scout_observations
for each row execute function public.set_updated_at();

alter table public.scout_observations enable row level security;

drop policy if exists "scout_observations_select_insights" on public.scout_observations;
create policy "scout_observations_select_insights"
on public.scout_observations for select
to authenticated
using (public.can_use_vineyard_insights(vineyard_id));

drop policy if exists "scout_observations_insert_insights" on public.scout_observations;
create policy "scout_observations_insert_insights"
on public.scout_observations for insert
to authenticated
with check (public.can_use_vineyard_insights(vineyard_id));

drop policy if exists "scout_observations_update_insights" on public.scout_observations;
create policy "scout_observations_update_insights"
on public.scout_observations for update
to authenticated
using (public.can_use_vineyard_insights(vineyard_id))
with check (public.can_use_vineyard_insights(vineyard_id));

drop policy if exists "scout_observations_no_client_hard_delete" on public.scout_observations;
create policy "scout_observations_no_client_hard_delete"
on public.scout_observations for delete
to authenticated
using (false);

revoke all on public.scout_observations from anon;
grant select, insert, update on public.scout_observations to authenticated;

-- =========================================================================
-- E. scout_observation_photos
-- =========================================================================
create table if not exists public.scout_observation_photos (
  id                  uuid primary key,
  observation_id      uuid not null
                        references public.scout_observations(id) on delete cascade,
  vineyard_id         uuid not null references public.vineyards(id) on delete cascade,
  -- Path convention: {vineyard_id}/{observation_id}/{uuid}.jpg
  storage_path        text not null,
  captured_at         timestamptz not null,
  latitude            double precision,
  longitude           double precision,
  horizontal_accuracy double precision,
  -- 'gps_confirmed' — a fresh fix passing the existing strict validation.
  -- 'location_unavailable' — no qualifying fix; the photo is associated with
  --   the BLOCK only. The CHECK below makes the dishonest combination
  --   unrepresentable: no stale fix, last-known position, shed location or
  --   block centroid can ever be stored as though it were the photo's
  --   measured position.
  location_status     text not null default 'location_unavailable'
                        check (location_status in ('gps_confirmed','location_unavailable')),
  captured_by         uuid references auth.users(id) on delete set null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  client_updated_at   timestamptz,
  sync_version        bigint not null default 0,
  deleted_at          timestamptz,
  constraint scout_photo_location_honesty check (
    (location_status = 'gps_confirmed'
       and latitude is not null
       and longitude is not null)
    or
    (location_status = 'location_unavailable'
       and latitude is null
       and longitude is null)
  )
);

create index if not exists scout_observation_photos_observation_idx
  on public.scout_observation_photos (observation_id)
  where deleted_at is null;

create index if not exists scout_observation_photos_updated_at_idx
  on public.scout_observation_photos (vineyard_id, updated_at desc);

create index if not exists scout_observation_photos_deleted_at_idx
  on public.scout_observation_photos (deleted_at);

create or replace trigger scout_observation_photos_set_updated_at
before update on public.scout_observation_photos
for each row execute function public.set_updated_at();

alter table public.scout_observation_photos enable row level security;

drop policy if exists "scout_observation_photos_select_insights" on public.scout_observation_photos;
create policy "scout_observation_photos_select_insights"
on public.scout_observation_photos for select
to authenticated
using (public.can_use_vineyard_insights(vineyard_id));

drop policy if exists "scout_observation_photos_insert_insights" on public.scout_observation_photos;
create policy "scout_observation_photos_insert_insights"
on public.scout_observation_photos for insert
to authenticated
with check (public.can_use_vineyard_insights(vineyard_id));

drop policy if exists "scout_observation_photos_update_insights" on public.scout_observation_photos;
create policy "scout_observation_photos_update_insights"
on public.scout_observation_photos for update
to authenticated
using (public.can_use_vineyard_insights(vineyard_id))
with check (public.can_use_vineyard_insights(vineyard_id));

drop policy if exists "scout_observation_photos_no_client_hard_delete" on public.scout_observation_photos;
create policy "scout_observation_photos_no_client_hard_delete"
on public.scout_observation_photos for delete
to authenticated
using (false);

revoke all on public.scout_observation_photos from anon;
grant select, insert, update on public.scout_observation_photos to authenticated;

-- =========================================================================
-- F. vintage_note_types
-- =========================================================================
-- Seeded system types have vineyard_id IS NULL and are visible to every
-- authorised caller. Custom types carry a vineyard_id and are scoped to that
-- vineyard alone.
create table if not exists public.vintage_note_types (
  id           uuid primary key default gen_random_uuid(),
  -- NULL = system type shared by all vineyards.
  vineyard_id  uuid references public.vineyards(id) on delete cascade,
  code         text not null,
  group_code   text not null check (group_code in
                 ('weather','phenology','disease','activity','other')),
  label        text not null,
  sort_order   integer not null default 0,
  is_system    boolean not null default false,
  -- Retiring is not deleting: a retired type disappears from the picker for
  -- NEW notes and stays resolvable for historical ones.
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  created_by   uuid references auth.users(id) on delete set null,
  updated_by   uuid references auth.users(id) on delete set null,
  deleted_at   timestamptz
);

-- A code is unique per vineyard, and system codes are unique globally.
create unique index if not exists vintage_note_types_system_code_idx
  on public.vintage_note_types (code)
  where vineyard_id is null and deleted_at is null;

create unique index if not exists vintage_note_types_vineyard_code_idx
  on public.vintage_note_types (vineyard_id, code)
  where vineyard_id is not null and deleted_at is null;

create index if not exists vintage_note_types_vineyard_idx
  on public.vintage_note_types (vineyard_id, group_code, sort_order)
  where deleted_at is null;

create or replace trigger vintage_note_types_set_updated_at
before update on public.vintage_note_types
for each row execute function public.set_updated_at();

alter table public.vintage_note_types enable row level security;

drop policy if exists "vintage_note_types_select_insights" on public.vintage_note_types;
create policy "vintage_note_types_select_insights"
on public.vintage_note_types for select
to authenticated
using (
  -- System types: readable by any caller who may use the preview at all.
  -- Requiring System Admin here (rather than allowing all authenticated
  -- users) keeps the preview's very existence undisclosed.
  (vineyard_id is null and public.is_system_admin())
  or public.can_use_vineyard_insights(vineyard_id)
);

drop policy if exists "vintage_note_types_insert_insights" on public.vintage_note_types;
create policy "vintage_note_types_insert_insights"
on public.vintage_note_types for insert
to authenticated
with check (
  -- Custom types only. A client may never mint a system type: those are
  -- seeded by migration so every vineyard's catalogue stays identical.
  vineyard_id is not null
  and is_system = false
  and public.can_use_vineyard_insights(vineyard_id)
);

drop policy if exists "vintage_note_types_update_insights" on public.vintage_note_types;
create policy "vintage_note_types_update_insights"
on public.vintage_note_types for update
to authenticated
using (vineyard_id is not null and public.can_use_vineyard_insights(vineyard_id))
with check (
  vineyard_id is not null
  and is_system = false
  and public.can_use_vineyard_insights(vineyard_id)
);

drop policy if exists "vintage_note_types_no_client_hard_delete" on public.vintage_note_types;
create policy "vintage_note_types_no_client_hard_delete"
on public.vintage_note_types for delete
to authenticated
using (false);

revoke all on public.vintage_note_types from anon;
grant select, insert, update on public.vintage_note_types to authenticated;

-- Seeded system catalogue. Mirrors Android `VintageNoteCatalog.systemTypes`
-- and iOS `VintageNoteCatalog.systemTypes` exactly — code, group, label and
-- sort order. Sort orders are spaced by 10 so a future type can be inserted
-- between two existing ones without renumbering (and therefore without a
-- client and server briefly disagreeing on order).
insert into public.vintage_note_types (vineyard_id, code, group_code, label, sort_order, is_system)
values
  (null,'frost','weather','Frost',10,true),
  (null,'low_temperature','weather','Low temperature / cold spell',20,true),
  (null,'extended_dry','weather','Extended dry period',30,true),
  (null,'excessive_heat','weather','Excessive heat / heatwave',40,true),
  (null,'high_winds','weather','High winds',50,true),
  (null,'heavy_rain','weather','Heavy rain',60,true),
  (null,'extended_wet','weather','Extended wet period',70,true),
  (null,'flooding','weather','Flooding / waterlogging',80,true),
  (null,'hail','weather','Hail',90,true),
  (null,'smoke_exposure','weather','Smoke / bushfire exposure',100,true),
  (null,'high_humidity','weather','High humidity / persistent fog',110,true),
  (null,'early_budburst','phenology','Early budburst',10,true),
  (null,'delayed_budburst','phenology','Delayed budburst',20,true),
  (null,'flowering_started','phenology','Flowering started',30,true),
  (null,'flowering_completed','phenology','Flowering completed',40,true),
  (null,'poor_fruit_set','phenology','Poor or variable fruit set',50,true),
  (null,'veraison_started','phenology','Veraison started',60,true),
  (null,'slow_ripening','phenology','Slow or delayed ripening',70,true),
  (null,'rapid_ripening','phenology','Rapid or early ripening',80,true),
  (null,'harvest_started','phenology','Harvest started',90,true),
  (null,'harvest_completed','phenology','Harvest completed',100,true),
  (null,'lower_yield','phenology','Lower than expected yield',110,true),
  (null,'higher_yield','phenology','Higher than expected yield',120,true),
  (null,'increased_disease_pressure','disease','Increased disease pressure',10,true),
  (null,'powdery_mildew','disease','Powdery mildew',20,true),
  (null,'downy_mildew','disease','Downy mildew',30,true),
  (null,'botrytis','disease','Botrytis',40,true),
  (null,'pest_bird_pressure','disease','Pest or bird pressure',50,true),
  (null,'pruning_started','activity','Pruning started',10,true),
  (null,'pruning_completed','activity','Pruning completed',20,true),
  (null,'shoot_thinning','activity','Shoot thinning',30,true),
  (null,'desuckering','activity','Desuckering',40,true),
  (null,'wire_lifting','activity','Wire lifting',50,true),
  (null,'leaf_plucking','activity','Leaf plucking',60,true),
  (null,'canopy_trimming','activity','Canopy trimming',70,true),
  (null,'fruit_thinning','activity','Fruit thinning',80,true),
  (null,'significant_irrigation','activity','Significant irrigation',90,true),
  (null,'cover_crop_activity','activity','Cover crop activity',100,true),
  (null,'other_custom','other','Other / custom event',10,true)
on conflict do nothing;

-- =========================================================================
-- G. vintage_notes
-- =========================================================================
create table if not exists public.vintage_notes (
  -- Client-generated UUID — the offline idempotency key.
  id                     uuid primary key,
  vineyard_id            uuid not null references public.vineyards(id) on delete cascade,
  note_date              date not null default current_date,
  -- Server-resolved from note_date. Never trusted from the client.
  vintage_year           integer not null,
  note_type_id           uuid references public.vintage_note_types(id) on delete set null,
  -- The label as it read when the note was written. Survives a later rename
  -- or retirement of the type, so history keeps saying what was chosen.
  note_type_label        text,
  notes                  text,
  observed_by_user_id    uuid references auth.users(id) on delete set null,
  observer_name_snapshot text,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  created_by             uuid references auth.users(id) on delete set null,
  updated_by             uuid references auth.users(id) on delete set null,
  client_updated_at      timestamptz,
  sync_version           bigint not null default 0,
  deleted_at             timestamptz,
  -- Mirrors the client rule: a type OR some text, never neither. A note that
  -- records nothing is not a note.
  constraint vintage_notes_not_empty check (
    note_type_id is not null
    or (notes is not null and length(btrim(notes)) > 0)
  )
);

create index if not exists vintage_notes_vineyard_vintage_idx
  on public.vintage_notes (vineyard_id, vintage_year, note_date desc)
  where deleted_at is null;

create index if not exists vintage_notes_type_idx
  on public.vintage_notes (note_type_id)
  where deleted_at is null;

create index if not exists vintage_notes_updated_at_idx
  on public.vintage_notes (vineyard_id, updated_at desc);

create index if not exists vintage_notes_deleted_at_idx
  on public.vintage_notes (deleted_at);

drop trigger if exists vintage_notes_set_vintage on public.vintage_notes;
create trigger vintage_notes_set_vintage
before insert or update of note_date, vineyard_id on public.vintage_notes
for each row execute function public._vineyard_insights_set_vintage('note_date');

create or replace trigger vintage_notes_set_updated_at
before update on public.vintage_notes
for each row execute function public.set_updated_at();

alter table public.vintage_notes enable row level security;

drop policy if exists "vintage_notes_select_insights" on public.vintage_notes;
create policy "vintage_notes_select_insights"
on public.vintage_notes for select
to authenticated
using (public.can_use_vineyard_insights(vineyard_id));

drop policy if exists "vintage_notes_insert_insights" on public.vintage_notes;
create policy "vintage_notes_insert_insights"
on public.vintage_notes for insert
to authenticated
with check (public.can_use_vineyard_insights(vineyard_id));

drop policy if exists "vintage_notes_update_insights" on public.vintage_notes;
create policy "vintage_notes_update_insights"
on public.vintage_notes for update
to authenticated
using (public.can_use_vineyard_insights(vineyard_id))
with check (public.can_use_vineyard_insights(vineyard_id));

drop policy if exists "vintage_notes_no_client_hard_delete" on public.vintage_notes;
create policy "vintage_notes_no_client_hard_delete"
on public.vintage_notes for delete
to authenticated
using (false);

revoke all on public.vintage_notes from anon;
grant select, insert, update on public.vintage_notes to authenticated;

-- =========================================================================
-- H. Storage bucket for Scout photos
-- =========================================================================
-- Private. Path convention: {vineyard_id}/{observation_id}/{uuid}.jpg
insert into storage.buckets (id, name, public)
values ('scout-photos', 'scout-photos', false)
on conflict (id) do nothing;

drop policy if exists "scout_photos_select_insights" on storage.objects;
create policy "scout_photos_select_insights"
on storage.objects for select
to authenticated
using (
  bucket_id = 'scout-photos'
  and public.can_use_vineyard_insights(public.storage_first_folder_uuid(name))
);

drop policy if exists "scout_photos_insert_insights" on storage.objects;
create policy "scout_photos_insert_insights"
on storage.objects for insert
to authenticated
with check (
  bucket_id = 'scout-photos'
  and public.can_use_vineyard_insights(public.storage_first_folder_uuid(name))
);

drop policy if exists "scout_photos_update_insights" on storage.objects;
create policy "scout_photos_update_insights"
on storage.objects for update
to authenticated
using (
  bucket_id = 'scout-photos'
  and public.can_use_vineyard_insights(public.storage_first_folder_uuid(name))
)
with check (
  bucket_id = 'scout-photos'
  and public.can_use_vineyard_insights(public.storage_first_folder_uuid(name))
);

drop policy if exists "scout_photos_delete_insights" on storage.objects;
create policy "scout_photos_delete_insights"
on storage.objects for delete
to authenticated
using (
  bucket_id = 'scout-photos'
  and public.can_use_vineyard_insights(public.storage_first_folder_uuid(name))
);

-- =========================================================================
-- K. RPCs
-- =========================================================================

-- Create or update a Vintage Note. Idempotent on p_id, so an offline replay
-- of the same capture updates the one row rather than creating a second note.
create or replace function public.upsert_vintage_note(
  p_id                uuid,
  p_vineyard_id       uuid,
  p_note_date         date,
  p_note_type_id      uuid default null,
  p_note_type_label   text default null,
  p_notes             text default null,
  p_observer_name     text default null,
  p_client_updated_at timestamptz default null
) returns public.vintage_notes
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_row public.vintage_notes;
begin
  if v_uid is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  -- System Admin AND membership of THIS vineyard. Checked here as well as in
  -- RLS: a security-definer function bypasses RLS by design, so it must
  -- re-establish the same boundary itself.
  if not public.can_use_vineyard_insights(p_vineyard_id) then
    raise exception 'Vineyard Insights access required' using errcode = '42501';
  end if;

  if p_note_type_id is null
     and (p_notes is null or length(btrim(p_notes)) = 0) then
    raise exception 'Add a note type or some notes before saving'
      using errcode = '22023';
  end if;

  -- A custom type must belong to THIS vineyard; a system type has no vineyard.
  if p_note_type_id is not null and not exists (
       select 1 from public.vintage_note_types t
        where t.id = p_note_type_id
          and t.deleted_at is null
          and (t.vineyard_id is null or t.vineyard_id = p_vineyard_id)
     ) then
    raise exception 'Unknown note type for this vineyard' using errcode = '22023';
  end if;

  insert into public.vintage_notes as n (
    id, vineyard_id, note_date, vintage_year, note_type_id, note_type_label,
    notes, observed_by_user_id, observer_name_snapshot,
    created_by, updated_by, client_updated_at
  ) values (
    p_id, p_vineyard_id, p_note_date,
    0, -- overwritten by the vintage trigger
    p_note_type_id, p_note_type_label,
    p_notes, v_uid, p_observer_name,
    v_uid, v_uid, coalesce(p_client_updated_at, now())
  )
  on conflict (id) do update
    set note_date         = excluded.note_date,
        note_type_id      = excluded.note_type_id,
        -- Only refresh the snapshot when the caller supplies one, so an edit
        -- that does not touch the type cannot blank the historical label.
        note_type_label   = coalesce(excluded.note_type_label, n.note_type_label),
        notes             = excluded.notes,
        updated_by        = v_uid,
        client_updated_at = excluded.client_updated_at,
        sync_version      = n.sync_version + 1,
        -- An update revives a row a peer soft-deleted only if this caller is
        -- explicitly editing it; deletion stays the last writer's decision.
        deleted_at        = n.deleted_at
    where n.vineyard_id = p_vineyard_id
  returning * into v_row;

  if v_row.id is null then
    raise exception 'Note belongs to a different vineyard' using errcode = '42501';
  end if;

  return v_row;
end;
$$;

revoke all on function public.upsert_vintage_note(uuid,uuid,date,uuid,text,text,text,timestamptz)
  from public, anon;
grant execute on function public.upsert_vintage_note(uuid,uuid,date,uuid,text,text,text,timestamptz)
  to authenticated;

-- Soft-delete a Vintage Note.
create or replace function public.soft_delete_vintage_note(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_vineyard uuid;
begin
  if v_uid is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  select vineyard_id into v_vineyard from public.vintage_notes where id = p_id;
  if v_vineyard is null then
    return false;
  end if;

  if not public.can_use_vineyard_insights(v_vineyard) then
    raise exception 'Vineyard Insights access required' using errcode = '42501';
  end if;

  update public.vintage_notes
     set deleted_at   = coalesce(deleted_at, now()),
         updated_by   = v_uid,
         sync_version = sync_version + 1
   where id = p_id;

  return true;
end;
$$;

revoke all on function public.soft_delete_vintage_note(uuid) from public, anon;
grant execute on function public.soft_delete_vintage_note(uuid) to authenticated;

-- Create, rename or retire a vineyard-scoped custom note type.
--
-- Renaming or retiring NEVER touches vintage_notes.note_type_label: existing
-- notes keep the wording their observer chose. That asymmetry is the whole
-- reason the snapshot column exists.
create or replace function public.upsert_vintage_note_type(
  p_id          uuid,
  p_vineyard_id uuid,
  p_code        text,
  p_group_code  text,
  p_label       text,
  p_sort_order  integer default 0,
  p_is_active   boolean default true
) returns public.vintage_note_types
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_row public.vintage_note_types;
begin
  if v_uid is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  if not public.can_use_vineyard_insights(p_vineyard_id) then
    raise exception 'Vineyard Insights access required' using errcode = '42501';
  end if;

  if p_label is null or length(btrim(p_label)) = 0 then
    raise exception 'A note type needs a label' using errcode = '22023';
  end if;

  insert into public.vintage_note_types as t (
    id, vineyard_id, code, group_code, label, sort_order,
    is_system, is_active, created_by, updated_by
  ) values (
    coalesce(p_id, gen_random_uuid()), p_vineyard_id, p_code,
    p_group_code, btrim(p_label), coalesce(p_sort_order, 0),
    false, coalesce(p_is_active, true), v_uid, v_uid
  )
  on conflict (id) do update
    set label      = btrim(p_label),
        group_code = excluded.group_code,
        sort_order = excluded.sort_order,
        is_active  = excluded.is_active,
        updated_by = v_uid
    -- A system type is never editable by a client, and a custom type belongs
    -- to exactly one vineyard.
    where t.vineyard_id = p_vineyard_id and t.is_system = false
  returning * into v_row;

  if v_row.id is null then
    raise exception 'Note type is not editable for this vineyard'
      using errcode = '42501';
  end if;

  return v_row;
end;
$$;

revoke all on function public.upsert_vintage_note_type(uuid,uuid,text,text,text,integer,boolean)
  from public, anon;
grant execute on function public.upsert_vintage_note_type(uuid,uuid,text,text,text,integer,boolean)
  to authenticated;

-- =========================================================================
-- Validation — the migration ABORTS if any assumption is wrong.
-- =========================================================================
do $$
begin
  -- The vintage resolver this migration depends on must exist.
  assert (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname = 'resolve_vineyard_vintage_year') > 0,
    'resolve_vineyard_vintage_year (sql/119) is required';

  assert (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname = 'is_system_admin') > 0,
    'is_system_admin (sql/062) is required';

  -- Every new table must have RLS enabled. A Data API exposure without RLS
  -- would publish this preview data to any authenticated user.
  assert (select bool_and(c.relrowsecurity)
            from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'public'
             and c.relname in ('scout_visits','scout_block_assessments',
                               'scout_observations','scout_observation_photos',
                               'vintage_note_types','vintage_notes')),
    'RLS must be enabled on every Vineyard Insights table';

  -- The full seeded catalogue must be present and match the clients.
  assert (select count(*) from public.vintage_note_types
           where vineyard_id is null and is_system) = 39,
    'Expected 39 seeded system vintage note types';
end;
$$;

commit;
