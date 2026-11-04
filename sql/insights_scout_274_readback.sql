-- READ ONLY. Safe to run in the Supabase SQL editor. Changes nothing.
-- Single result set (the editor only displays the LAST statement's result).
-- Purpose: Issue #55 P-10 / P-11. Is migration 274 (scout stop_context) applied in production?
-- Android always sends `stop_context` on Scout assessments; if the column is missing PostgREST
-- answers HTTP 400 (PGRST204). Hypothesis check, not a confirmed cause.
select 'stop_context column (274 adds it)' as check_name,
       exists(select 1 from information_schema.columns
              where table_schema='public' and table_name='scout_block_assessments'
                and column_name='stop_context')::text as result
union all
select 'scout_stop_context_object_ck (274 adds it)',
       exists(select 1 from pg_constraint where conname='scout_stop_context_object_ck')::text
union all
select 'old one-stop unique index still present (274 drops it)',
       exists(select 1 from pg_indexes where schemaname='public'
              and indexname='scout_block_assessments_unique_active_idx')::text
union all
select 'upsert_vintage_note arguments',
       (select pg_get_function_identity_arguments(p.oid)
          from pg_proc p join pg_namespace n on n.oid=p.pronamespace
         where n.nspname='public' and p.proname='upsert_vintage_note' limit 1);
