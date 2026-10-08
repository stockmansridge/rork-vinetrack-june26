-- Source-only correction; Jonathan must apply separately. 266–271 are reserved
-- by the previously confirmed Portal/server migrations, although absent here.
-- Requires the existing 236/237/240/243 Insights contract; never rewrites them.
begin;

create or replace function public._vineyard_insights_set_vintage()
returns trigger language plpgsql security definer
set search_path = pg_catalog, public as $$
declare
  v_field text;
  v_raw text;
  v_date date;
begin
  if tg_nargs <> 1 or tg_when <> 'BEFORE' or tg_level <> 'ROW'
     or tg_op not in ('INSERT', 'UPDATE') then
    raise exception using errcode = '22023', message = 'INVALID_INSIGHTS_VINTAGE_TRIGGER_CONFIGURATION';
  end if;
  v_field := tg_argv[0];
  if not ((tg_table_schema = 'public' and tg_table_name = 'scout_visits' and v_field = 'scout_date')
       or (tg_table_schema = 'public' and tg_table_name = 'vintage_notes' and v_field = 'note_date')) then
    raise exception using errcode = '22023', message = 'UNSUPPORTED_INSIGHTS_VINTAGE_TABLE_OR_DATE_FIELD';
  end if;
  -- A generic record must not statically reference fields of the other table.
  v_raw := to_jsonb(new) ->> v_field;
  if v_raw is null or btrim(v_raw) = '' then
    raise exception using errcode = '23502', message = format('INSIGHTS_REQUIRED_DATE_MISSING: %I.%I', tg_table_name, v_field);
  end if;
  begin
    v_date := v_raw::date;
  exception when invalid_datetime_format or datetime_field_overflow then
    raise exception using errcode = '22007', message = format('INSIGHTS_INVALID_DATE: %I.%I', tg_table_name, v_field);
  end;
  if not isfinite(v_date) then
    raise exception using errcode = '22007', message = 'INSIGHTS_DATE_MUST_BE_FINITE';
  end if;
  new.vintage_year := public.resolve_vineyard_vintage_year(new.vineyard_id, v_date);
  return new;
end $$;
revoke all on function public._vineyard_insights_set_vintage() from public, anon, authenticated;

-- Inspect EVERY installed use, including an unexpected trigger added elsewhere.
-- Abort instead of silently accepting an unsupported field or disabling a trigger.
do $$
declare t record;
begin
  for t in select * from pg_trigger
    where tgfoid = 'public._vineyard_insights_set_vintage()'::regprocedure and not tgisinternal
  loop
    if t.tgnargs <> 1 or t.tgenabled = 'D' or not (
      (t.tgrelid = 'public.scout_visits'::regclass and t.tgargs = convert_to('scout_date','UTF8') || decode('00','hex'))
      or (t.tgrelid = 'public.vintage_notes'::regclass and t.tgargs = convert_to('note_date','UTF8') || decode('00','hex'))
    ) then
      raise exception 'Unsupported Insights vintage trigger configuration: %', t.tgname using errcode = '22023';
    end if;
  end loop;
end $$;

-- Retain date-change and vineyard-change recalculation, including retry upserts.
drop trigger if exists scout_visits_set_vintage on public.scout_visits;
create trigger scout_visits_set_vintage
before insert or update of scout_date, vineyard_id on public.scout_visits
for each row execute function public._vineyard_insights_set_vintage('scout_date');
drop trigger if exists vintage_notes_set_vintage on public.vintage_notes;
create trigger vintage_notes_set_vintage
before insert or update of note_date, vineyard_id on public.vintage_notes
for each row execute function public._vineyard_insights_set_vintage('note_date');

create or replace function public.hard_delete_scout_visit(
  p_vineyard_id uuid, p_visit_id uuid, p_operation_id uuid,
  p_deleted_at timestamptz default now()
) returns boolean language plpgsql security definer
set search_path = pg_catalog, public as $$
declare v_existing public.vineyard_insights_deletions%rowtype;
begin
  if auth.uid() is null or not coalesce(public.can_use_vineyard_insights(p_vineyard_id), false)
     or not public.has_vineyard_role(p_vineyard_id, array['owner','manager']) then
    raise exception using errcode = '42501', message = 'SCOUT_DELETE_REQUIRES_VINEYARD_OWNER_OR_MANAGER';
  end if;
  if p_visit_id is null or p_operation_id is null then
    raise exception using errcode = '22023', message = 'SCOUT_DELETE_IDENTITY_REQUIRED';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('scout_visit:' || p_visit_id::text, 0));
  select * into v_existing from public.vineyard_insights_deletions where operation_id = p_operation_id;
  if found and (v_existing.vineyard_id <> p_vineyard_id or v_existing.entity_type <> 'scout_visit' or v_existing.entity_id <> p_visit_id) then
    raise exception using errcode = '22023', message = 'DELETE_OPERATION_CONFLICT';
  end if;
  if not found then
    select * into v_existing from public.vineyard_insights_deletions where entity_type = 'scout_visit' and entity_id = p_visit_id;
  end if;
  if found then
    if v_existing.vineyard_id <> p_vineyard_id or v_existing.entity_type <> 'scout_visit' or v_existing.entity_id <> p_visit_id then
      raise exception using errcode = '22023', message = 'DELETE_OPERATION_CONFLICT';
    end if;
    return true;
  end if;
  if exists (select 1 from public.scout_visits where id = p_visit_id and vineyard_id <> p_vineyard_id) then
    raise exception using errcode = '42501', message = 'WRONG_VINEYARD';
  end if;
  insert into public.vineyard_insights_deletions
    (vineyard_id, entity_type, entity_id, deleted_at, deleted_by, operation_id)
  values (p_vineyard_id, 'scout_visit', p_visit_id, now(), auth.uid(), p_operation_id);
  insert into public.scout_photo_cleanup_queue (vineyard_id, scout_visit_id, photo_id, storage_path)
  select p_vineyard_id, p_visit_id, p.id, p.storage_path
  from public.scout_observation_photos p
  join public.scout_observations o on o.id = p.observation_id
  join public.scout_block_assessments a on a.id = o.assessment_id
  where a.scout_visit_id = p_visit_id and p.storage_path is not null
  on conflict (photo_id, storage_path) do nothing;
  -- Existing cascades clean Scout children; canonical Growth Stage data stays.
  delete from public.scout_visits where id = p_visit_id and vineyard_id = p_vineyard_id;
  return true;
end $$;
revoke all on function public.hard_delete_scout_visit(uuid,uuid,uuid,timestamptz) from public, anon;
grant execute on function public.hard_delete_scout_visit(uuid,uuid,uuid,timestamptz) to authenticated;

-- Defence in depth for alternative SECURITY DEFINER/direct root write paths.
-- The existing resurrection trigger already rejects deleted_at writes. A hard
-- DELETE must also have the canonical ledger transaction, not just a role.
create or replace function public._guard_scout_permanent_deletion()
returns trigger language plpgsql security definer
set search_path = pg_catalog, public as $$
begin
  if tg_op = 'UPDATE' then
    if new.vineyard_id is distinct from old.vineyard_id then
      raise exception using errcode = '42501', message = 'SCOUT_VINEYARD_CANNOT_BE_CHANGED';
    end if;
    return new;
  end if;
  if auth.uid() is null then
    -- Only trusted maintenance/service sessions may bypass end-user membership.
    if coalesce(auth.role(), '') <> 'service_role' and session_user not in ('postgres', 'supabase_admin') then
      raise exception using errcode = '42501', message = 'SCOUT_DELETE_REQUIRES_AUTHENTICATION';
    end if;
  else
    if not coalesce(public.can_use_vineyard_insights(old.vineyard_id), false)
       or not public.has_vineyard_role(old.vineyard_id, array['owner','manager']) then
      raise exception using errcode = '42501', message = 'SCOUT_DELETE_REQUIRES_VINEYARD_OWNER_OR_MANAGER';
    end if;
    if not exists (select 1 from public.vineyard_insights_deletions d
      where d.vineyard_id = old.vineyard_id and d.entity_type = 'scout_visit'
        and d.entity_id = old.id and d.deleted_by = auth.uid()) then
      raise exception using errcode = '42501', message = 'HARD_DELETE_RPC_REQUIRED';
    end if;
  end if;
  return old;
end $$;
revoke all on function public._guard_scout_permanent_deletion() from public, anon, authenticated;
create trigger scout_visits_guard_permanent_deletion
before delete or update of vineyard_id on public.scout_visits
for each row execute function public._guard_scout_permanent_deletion();
revoke delete on public.scout_visits, public.scout_block_assessments,
  public.scout_observations, public.scout_observation_photos from authenticated;

commit;
