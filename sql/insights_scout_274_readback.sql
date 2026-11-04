-- READ ONLY. Safe to run in the Supabase SQL editor. Changes nothing.
-- Purpose: Issue #55 P-10 / P-11. Is migration 274 (scout stop_context) applied in production?
-- Android always sends `stop_context` on Scout assessments; if the column is missing PostgREST
-- answers HTTP 400 (PGRST204). This is a hypothesis check, not a confirmed cause.
select 'stop_context column' as check_name,
       exists(select 1 from information_schema.columns
              where table_schema='public' and table_name='scout_block_assessments'
                and column_name='stop_context') as present;
select 'scout_stop_context_object_ck' as check_name,
       exists(select 1 from pg_constraint where conname='scout_stop_context_object_ck') as present;
select 'old one-stop unique index still present (274 drops it)' as check_name,
       exists(select 1 from pg_indexes where schemaname='public'
              and indexname='scout_block_assessments_unique_active_idx') as present;
select 'upsert_vintage_note signature' as check_name,
       pg_get_function_identity_arguments(p.oid) as args
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname='upsert_vintage_note';
