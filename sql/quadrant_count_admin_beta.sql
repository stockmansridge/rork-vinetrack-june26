-- Applied to tbafuqwruefgkbyxrxyb as quadrant_count_admin_beta.
-- JSON-only addition: keep existing RLS and full-vine writes unchanged.
create or replace function public.guard_quadrant_count_beta()
returns trigger language plpgsql security invoker set search_path = ''
as $function$
declare
  new_quadrant boolean;
  old_quadrant boolean := false;
  site jsonb; entry jsonb; measurement jsonb;
  raw_count numeric; section_cm numeric; spacing_cm numeric; normalized numeric;
begin
  new_quadrant := coalesce(new.payload->>'countMethod' = 'quadrant', false)
    or jsonb_path_exists(new.payload, '$.sampleSites[*].bunchCountEntry.quadrant ? (@ != null)');
  if tg_op = 'UPDATE' then
    old_quadrant := coalesce(old.payload->>'countMethod' = 'quadrant', false)
      or jsonb_path_exists(old.payload, '$.sampleSites[*].bunchCountEntry.quadrant ? (@ != null)');
  end if;
  if not (new_quadrant or old_quadrant) then return new; end if;
  if not coalesce(public.is_system_admin(), false) then
    raise exception 'Quadrant Count is available to System Admins only during testing.' using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' and old_quadrant is distinct from new_quadrant then
    raise exception 'Counting method cannot change on an existing trip.' using errcode = '22023';
  end if;
  if (new.payload->>'countMethod') is distinct from 'quadrant'
     or jsonb_typeof(new.payload->'quadrantSectionLengthCm') is distinct from 'number'
     or (new.payload->>'quadrantSectionLengthCm')::numeric <= 0
     or jsonb_typeof(new.payload->'sampleSites') is distinct from 'array' then
    raise exception 'Invalid Quadrant Count trip metadata.' using errcode = '22023';
  end if;
  for site in select value from jsonb_array_elements(new.payload->'sampleSites') loop
    entry := site->'bunchCountEntry';
    if entry is null or entry = 'null'::jsonb then continue; end if;
    measurement := entry->'quadrant';
    if jsonb_typeof(measurement) is distinct from 'object'
       or jsonb_typeof(measurement->'rawBunchCount') is distinct from 'number'
       or jsonb_typeof(measurement->'sectionLengthCm') is distinct from 'number'
       or jsonb_typeof(measurement->'vineSpacingCm') is distinct from 'number'
       or measurement->>'calculationVersion' is distinct from '1'
       or jsonb_typeof(entry->'bunchesPerVine') is distinct from 'number' then
      raise exception 'Quadrant Count sample measurements are required.' using errcode = '22023';
    end if;
    raw_count := (measurement->>'rawBunchCount')::numeric;
    section_cm := (measurement->>'sectionLengthCm')::numeric;
    spacing_cm := (measurement->>'vineSpacingCm')::numeric;
    normalized := (entry->>'bunchesPerVine')::numeric;
    if raw_count < 0 or raw_count <> trunc(raw_count) or section_cm <= 0 or spacing_cm <= 0 then
      raise exception 'Invalid Quadrant Count measurements.' using errcode = '22023';
    end if;
    if abs(normalized - raw_count * spacing_cm / section_cm) > greatest(0.00000001, abs(normalized) * 0.000000000001) then
      raise exception 'Quadrant Count normalized result does not match its measurements.' using errcode = '22023';
    end if;
  end loop;
  return new;
end;
$function$;
revoke all on function public.guard_quadrant_count_beta() from public, anon, authenticated;
drop trigger if exists yield_quadrant_count_admin_beta on public.yield_estimation_sessions;
create trigger yield_quadrant_count_admin_beta before insert or update on public.yield_estimation_sessions
for each row execute function public.guard_quadrant_count_beta();
