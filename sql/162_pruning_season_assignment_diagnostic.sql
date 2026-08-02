-- =============================================================================
-- 162: READ-ONLY diagnostic — pruning season assignment audit.
--
-- Makes NO changes. Run it in the Supabase SQL editor of the shared VineTrack
-- project and paste the full JSON result back. Nothing is corrected until the
-- affected rows and their intended mappings have been reviewed.
--
-- Canonical rule being tested (SQL 161):
--   season_year  = extract(year from pruning_entries.entry_date)
--   vintage_year = resolve_vineyard_vintage_year(vineyard, entry_date)
--
-- Sections
--   summary                       counts for every check, one glance
--   season_year_mismatches        entries whose season year <> year(entry_date)
--   vintage_year_mismatches       entries whose stored vintage <> the resolver
--   same_date_split_seasons       one date, one vineyard, >1 season year
--   duplicate_seasons             >1 live season row per block + year
--   orphan_or_invalid_season_ids  missing / soft-deleted / cross-block seasons
--   season_years_by_vineyard      where the data actually lives
--   client_correlation            iOS vs Android vs portal, where recorded
--                                 (best effort — see the note below)
--
-- NOTE on client attribution: pruning_entries has no client/platform column,
-- so a row cannot be attributed to iOS or Android directly. The
-- client_correlation section uses the only available signals — the linked
-- Work Task's source/created-by metadata where the column exists, and the
-- entry's created_by account — and reports 'unknown' rather than guessing.
-- =============================================================================

with entries as (
  select
    e.id,
    e.vineyard_id,
    e.paddock_id,
    e.entry_date,
    e.vintage_year,
    e.created_by,
    e.created_at,
    e.work_task_id,
    e.pruning_season_id,
    s.id            as season_row_id,
    s.season_year   as season_year,
    s.deleted_at    as season_deleted_at,
    s.vineyard_id   as season_vineyard_id,
    s.paddock_id    as season_paddock_id,
    extract(year from e.entry_date)::integer as work_year
  from public.pruning_entries e
  left join public.pruning_seasons s on s.id = e.pruning_season_id
  where e.deleted_at is null
),
mismatched as (
  select * from entries where season_year is distinct from work_year
),
vintage_mismatched as (
  select e.*, public.resolve_vineyard_vintage_year(e.vineyard_id, e.entry_date) as expected_vintage
  from entries e
  where e.vintage_year is distinct from public.resolve_vineyard_vintage_year(e.vineyard_id, e.entry_date)
),
same_date_split as (
  select vineyard_id, entry_date,
         count(distinct season_year) as season_years,
         array_agg(distinct season_year order by season_year) as years,
         count(*) as entries
  from entries
  group by vineyard_id, entry_date
  having count(distinct season_year) > 1
),
duplicate_seasons as (
  select vineyard_id, paddock_id, season_year, count(*) as live_rows,
         array_agg(id order by created_at) as season_ids
  from public.pruning_seasons
  where deleted_at is null
  group by vineyard_id, paddock_id, season_year
  having count(*) > 1
),
invalid_links as (
  select * from entries
  where season_row_id is null
     or season_deleted_at is not null
     or season_vineyard_id is distinct from vineyard_id
     or season_paddock_id is distinct from paddock_id
)
select jsonb_pretty(jsonb_build_object(
  'generated_at', now(),
  'canonical_rule', 'season_year = year(entry_date); vintage_year = resolve_vineyard_vintage_year(vineyard, entry_date)',

  'summary', jsonb_build_object(
    'live_entries',                (select count(*) from entries),
    'season_year_mismatches',      (select count(*) from mismatched),
    'vintage_year_mismatches',     (select count(*) from vintage_mismatched),
    'same_date_split_dates',       (select count(*) from same_date_split),
    'duplicate_season_groups',     (select count(*) from duplicate_seasons),
    'orphan_or_invalid_seasons',   (select count(*) from invalid_links),
    'live_seasons',                (select count(*) from public.pruning_seasons where deleted_at is null),
    'sql_161_applied',             to_regprocedure('public.resolve_pruning_season(uuid, uuid, date, uuid, timestamptz)') is not null
  ),

  'season_year_mismatches', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'entry_id', m.id,
      'vineyard_id', m.vineyard_id,
      'block', p.name,
      'entry_date', m.entry_date,
      'work_year', m.work_year,
      'stored_season_year', m.season_year,
      'stored_vintage_year', m.vintage_year,
      'season_id', m.pruning_season_id,
      'canonical_season_id', case
        when to_regprocedure('public.derive_pruning_season_id(uuid, uuid, integer)') is not null
        then public.derive_pruning_season_id(m.vineyard_id, m.paddock_id, m.work_year)
        else null
      end,
      'canonical_season_exists', exists (
        select 1 from public.pruning_seasons s2
        where s2.vineyard_id = m.vineyard_id and s2.paddock_id = m.paddock_id
          and s2.season_year = m.work_year and s2.deleted_at is null
      ),
      'quarters', (select count(*) from public.pruning_row_segments g where g.pruning_entry_id = m.id),
      'created_at', m.created_at,
      'created_by', m.created_by
    ) order by m.entry_date desc, p.name), '[]'::jsonb)
    from mismatched m left join public.paddocks p on p.id = m.paddock_id
  ),

  'vintage_year_mismatches', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'entry_id', v.id,
      'vineyard_id', v.vineyard_id,
      'entry_date', v.entry_date,
      'stored_vintage_year', v.vintage_year,
      'expected_vintage_year', v.expected_vintage
    ) order by v.entry_date desc), '[]'::jsonb)
    from vintage_mismatched v
  ),

  'same_date_split_seasons', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'vineyard_id', d.vineyard_id,
      'vineyard', vy.name,
      'entry_date', d.entry_date,
      'season_years', d.years,
      'entries', d.entries
    ) order by d.entry_date desc), '[]'::jsonb)
    from same_date_split d left join public.vineyards vy on vy.id = d.vineyard_id
  ),

  'duplicate_seasons', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'vineyard_id', ds.vineyard_id,
      'block', p.name,
      'season_year', ds.season_year,
      'live_rows', ds.live_rows,
      'season_ids', ds.season_ids
    ) order by ds.season_year desc), '[]'::jsonb)
    from duplicate_seasons ds left join public.paddocks p on p.id = ds.paddock_id
  ),

  'orphan_or_invalid_season_ids', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'entry_id', i.id,
      'vineyard_id', i.vineyard_id,
      'entry_date', i.entry_date,
      'season_id', i.pruning_season_id,
      'reason', case
        when i.season_row_id is null then 'season_row_missing'
        when i.season_deleted_at is not null then 'season_soft_deleted'
        when i.season_vineyard_id is distinct from i.vineyard_id then 'season_belongs_to_another_vineyard'
        else 'season_belongs_to_another_block'
      end
    ) order by i.entry_date desc), '[]'::jsonb)
    from invalid_links i
  ),

  'season_years_by_vineyard', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'vineyard_id', t.vineyard_id,
      'vineyard', t.name,
      'season_year', t.season_year,
      'entries', t.entries,
      'first_entry', t.first_entry,
      'last_entry', t.last_entry,
      'vintage_years', t.vintages
    ) order by t.name, t.season_year), '[]'::jsonb)
    from (
      select e.vineyard_id, vy.name, e.season_year,
             count(*) as entries,
             min(e.entry_date) as first_entry,
             max(e.entry_date) as last_entry,
             array_agg(distinct e.vintage_year) as vintages
      from entries e left join public.vineyards vy on vy.id = e.vineyard_id
      group by e.vineyard_id, vy.name, e.season_year
    ) t
  ),

  'client_correlation', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'created_by', t.created_by,
      'account', t.email,
      'entries', t.entries,
      'mismatched_entries', t.mismatched,
      'season_years', t.years,
      'note', 'pruning_entries has no platform column — attribution is by account, not device'
    ) order by t.entries desc), '[]'::jsonb)
    from (
      select e.created_by,
             pr.email,
             count(*) as entries,
             count(*) filter (where e.season_year is distinct from e.work_year) as mismatched,
             array_agg(distinct e.season_year) as years
      from entries e left join public.profiles pr on pr.id = e.created_by
      group by e.created_by, pr.email
    ) t
  )
)) as pruning_season_assignment_audit;
