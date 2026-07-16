-- 118: READ-ONLY diagnostic — where does the pruning data actually live?
--
-- Context: the portal calls SQL 115 with (vineyard fe952afe-…, season_year
-- 2027) and gets zeros, while both mobile apps show real pruning progress.
-- Both mobile apps and SQL 115's own default resolve the pruning season as
-- the CALENDAR YEAR of today (2026 — pruning is happening in July 2026), and
-- every mobile season id is deterministically derived from
-- (vineyard, paddock, 2026). A query for season_year 2027 therefore finds no
-- season rows even when all the data is present under 2026.
--
-- This script proves (or disproves) that in one shot. It makes NO changes —
-- run it in the Supabase SQL editor and paste the full JSON result back.
--
-- What each section shows:
--   vineyards_named_stockmans_ridge  duplicate-vineyard check (item 8)
--   target_by_season_year            which season year the data sits under (item 7)
--   target_blocks                    per-block seasons incl. Grüner Veltliner (item 11)
--   target_entries                   every entry with its id — trace device records (items 3/7)
--   all_pruning_by_vineyard          entries under any OTHER vineyard uuid (items 7/8)
--   entry_year_mismatches            entries whose date year differs from their season year

select jsonb_pretty(jsonb_build_object(
  'generated_at', now(),
  'target_vineyard_id', 'fe952afe-437f-4be7-8cbf-fdd8e630411c',

  'vineyards_named_stockmans_ridge', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', v.id,
      'name', v.name,
      'paddocks', (select count(*) from public.paddocks p where p.vineyard_id = v.id and p.deleted_at is null),
      'members', (select count(*) from public.vineyard_members m where m.vineyard_id = v.id),
      'pruning_seasons', (select count(*) from public.pruning_seasons s where s.vineyard_id = v.id),
      'pruning_entries', (select count(*) from public.pruning_entries e where e.vineyard_id = v.id),
      'pruning_segments', (select count(*) from public.pruning_row_segments g where g.vineyard_id = v.id)
    )), '[]'::jsonb)
    from public.vineyards v
    where v.name ilike '%stockman%'
       or v.id = 'fe952afe-437f-4be7-8cbf-fdd8e630411c'
  ),

  'target_by_season_year', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'season_year', t.season_year,
      'seasons', t.seasons,
      'entries', t.entries,
      'completed_quarters', t.completed_quarters,
      'completed_row_equivalents', t.completed_row_equivalents
    ) order by t.season_year), '[]'::jsonb)
    from (
      select s.season_year,
        count(distinct s.id) as seasons,
        count(distinct e.id) filter (where e.deleted_at is null) as entries,
        count(distinct g.id) filter (where g.completed) as completed_quarters,
        round((count(distinct g.id) filter (where g.completed))::numeric / 4.0, 2) as completed_row_equivalents
      from public.pruning_seasons s
      left join public.pruning_entries e on e.pruning_season_id = s.id
      left join public.pruning_row_segments g on g.pruning_season_id = s.id
      where s.vineyard_id = 'fe952afe-437f-4be7-8cbf-fdd8e630411c'
      group by s.season_year
    ) t
  ),

  'target_blocks', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'block', p.name,
      'season_year', s.season_year,
      'season_id', s.id,
      'season_deleted', s.deleted_at is not null,
      'entries', (
        select count(*) from public.pruning_entries e
        where e.pruning_season_id = s.id and e.deleted_at is null
      ),
      'completed_row_equivalents', (
        select round(count(*)::numeric / 4.0, 2) from public.pruning_row_segments g
        where g.pruning_season_id = s.id and g.completed
      )
    ) order by p.name, s.season_year), '[]'::jsonb)
    from public.pruning_seasons s
    join public.paddocks p on p.id = s.paddock_id
    where s.vineyard_id = 'fe952afe-437f-4be7-8cbf-fdd8e630411c'
  ),

  'target_entries', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', e.id,
      'block', p.name,
      'season_id', e.pruning_season_id,
      'season_year', s.season_year,
      'entry_date', e.entry_date,
      'row_equivalents', e.row_equivalents_completed,
      'labour_hours', e.labour_hours,
      'work_task_id', e.work_task_id,
      'deleted', e.deleted_at is not null
    ) order by e.entry_date, p.name), '[]'::jsonb)
    from public.pruning_entries e
    left join public.pruning_seasons s on s.id = e.pruning_season_id
    left join public.paddocks p on p.id = e.paddock_id
    where e.vineyard_id = 'fe952afe-437f-4be7-8cbf-fdd8e630411c'
  ),

  'all_pruning_by_vineyard', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'vineyard_id', t.vineyard_id,
      'vineyard', t.name,
      'entries', t.entries,
      'season_years', t.season_years
    )), '[]'::jsonb)
    from (
      select e.vineyard_id, v.name,
        count(*) as entries,
        (select coalesce(jsonb_agg(distinct s2.season_year), '[]'::jsonb)
         from public.pruning_seasons s2 where s2.vineyard_id = e.vineyard_id) as season_years
      from public.pruning_entries e
      join public.vineyards v on v.id = e.vineyard_id
      group by e.vineyard_id, v.name
    ) t
  ),

  'entry_year_mismatches', (
    select count(*)
    from public.pruning_entries e
    join public.pruning_seasons s on s.id = e.pruning_season_id
    where extract(year from e.entry_date)::integer <> s.season_year
  )
)) as pruning_diagnostic;
