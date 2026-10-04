-- Jonathan: apply before releasing preferred-rate clients. No backfill or deployment is performed by this file.
-- Portal uses this same column; no spray_jobs or registered/default-rate schema changes.
begin;
alter table public.saved_chemicals add column if not exists vineyard_preferred_rate jsonb;
alter table public.saved_chemicals drop constraint if exists saved_chemicals_vineyard_preferred_rate_valid;
alter table public.saved_chemicals add constraint saved_chemicals_vineyard_preferred_rate_valid check (
  vineyard_preferred_rate is null or coalesce(
    jsonb_typeof(vineyard_preferred_rate) = 'object'
    and jsonb_typeof(vineyard_preferred_rate->'amount') = 'number'
    and (vineyard_preferred_rate->>'amount')::numeric > 0
    and vineyard_preferred_rate->>'unit' in ('L','mL','kg','g')
    and vineyard_preferred_rate->>'basis' in ('per_hectare','per_100_litres')
    and (not vineyard_preferred_rate ? 'note' or jsonb_typeof(vineyard_preferred_rate->'note') in ('string','null')),
    false)
);
comment on column public.saved_chemicals.vineyard_preferred_rate is
'Exact vineyard operational preference {amount:number>0,unit:L|mL|kg|g,basis:per_hectare|per_100_litres,note?:string,updated_at?:ISO8601,updated_by?:uuid}. NULL clears. Not registered label evidence; never project into default_rates/rates/rate_per_ha. Existing vineyard member reads and owner/manager writes apply.';
-- Existing table grants and owner/manager RLS cover the new column; do not widen policies.
notify pgrst, 'reload schema';
commit;
