-- 089_grape_variety_hard_delete.sql
--
-- Safe hard-delete for vineyard-scoped CUSTOM grape varieties.
--
-- Existing related migrations:
--   * 073 — `vineyard_grape_varieties` table + `archive_vineyard_grape_variety`
--           (soft archive: `is_active = false`). Soft archive is preserved
--           as the recommended action for varieties referenced by history.
--   * 072 — `paddocks.variety_allocations` jsonb shape (`varietyKey`,
--           `varietyId`, `name`).
--   * 055 — `growth_stage_records.variety` / `.variety_id`.
--   * 059 — `trip_cost_allocations.variety` / `.variety_id`.
--
-- This migration adds a single SECURITY DEFINER RPC that:
--   * refuses to hard-delete built-in / system varieties (`is_custom = false`),
--   * refuses to hard-delete custom varieties referenced anywhere,
--   * requires the caller to be an owner/manager of the variety's vineyard,
--   * deletes only from `vineyard_grape_varieties` (never deletes paddocks,
--     trips, growth records, etc.),
--   * returns a structured `jsonb { success, status, message }` so iOS/Lovable
--     can show friendly alerts without parsing free-form errors.
--
-- Statuses returned:
--   hard_deleted        — row permanently removed from vineyard_grape_varieties
--   not_found           — no row with that id
--   not_custom          — built-in/system variety (is_custom = false)
--   system_variety      — built-in catalog row (variety_key without `custom:` prefix)
--   variety_in_use      — referenced by paddock/growth/trip records
--   not_authorised      — caller is not owner/manager of the vineyard
--   missing_id          — null id
--
-- Idempotent (`create or replace function`). Re-running is safe.

set search_path = public;

drop function if exists public.hard_delete_unused_custom_grape_variety(uuid);

create or replace function public.hard_delete_unused_custom_grape_variety(
    p_variety_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_row              public.vineyard_grape_varieties;
    v_key_text         text;
    v_display_name     text;
    v_paddock_hits     int := 0;
    v_growth_hits      int := 0;
    v_trip_cost_hits   int := 0;
    v_in_use_reason    text;
begin
    if p_variety_id is null then
        return jsonb_build_object(
            'success', false,
            'status',  'missing_id',
            'message', 'Variety id is required.'
        );
    end if;

    select * into v_row
      from public.vineyard_grape_varieties
     where id = p_variety_id
     limit 1;

    if v_row.id is null then
        return jsonb_build_object(
            'success', false,
            'status',  'not_found',
            'message', 'This grape variety could not be found. It may have already been deleted.'
        );
    end if;

    -- Built-in / system varieties: never hard-delete. Built-ins live in
    -- `grape_variety_catalog`; the vineyard row is just a per-vineyard
    -- selection mirror and must stay.
    if v_row.is_custom is distinct from true then
        return jsonb_build_object(
            'success', false,
            'status',  'not_custom',
            'message', 'Built-in grape varieties cannot be deleted. They can be archived if you no longer use them.'
        );
    end if;

    -- Defensive: a custom row MUST have a `custom:` key. If it doesn't,
    -- treat it as system to avoid accidentally hard-deleting a built-in
    -- mistakenly tagged `is_custom = true`.
    if v_row.variety_key is null or v_row.variety_key not like 'custom:%' then
        return jsonb_build_object(
            'success', false,
            'status',  'system_variety',
            'message', 'Built-in grape varieties cannot be deleted.'
        );
    end if;

    -- Authorisation: only owners/managers of this variety's vineyard.
    if not public.has_vineyard_role(v_row.vineyard_id, array['owner','manager']) then
        return jsonb_build_object(
            'success', false,
            'status',  'not_authorised',
            'message', 'You don''t have permission to delete grape varieties for this vineyard.'
        );
    end if;

    v_key_text     := v_row.variety_key;
    v_display_name := coalesce(nullif(trim(v_row.display_name), ''), '');

    -- =================================================================
    -- Reference scan #1 — paddocks.variety_allocations (jsonb array).
    -- Allocation shape (migration 072): { varietyId, varietyKey, name, percent, id }.
    -- We text-scan the array's JSON representation for the stable
    -- `variety_key`, then also match on `varietyId` directly. Scoped to
    -- the variety's vineyard so we don't false-positive on other
    -- vineyards that happen to have a custom with the same display name.
    -- =================================================================
    select count(*) into v_paddock_hits
      from public.paddocks p
     where p.vineyard_id = v_row.vineyard_id
       and (p.deleted_at is null)
       and p.variety_allocations is not null
       and (
            p.variety_allocations::text ilike '%' || replace(v_key_text, '%', '\%') || '%'
            or exists (
                select 1
                  from jsonb_array_elements(
                           case when jsonb_typeof(p.variety_allocations) = 'array'
                                then p.variety_allocations
                                else '[]'::jsonb
                           end
                       ) as alloc
                 where (alloc->>'varietyId')::text = v_row.id::text
                    or (alloc->>'variety_id')::text = v_row.id::text
                    or (v_display_name <> '' and (
                            lower(coalesce(alloc->>'name', '')) = lower(v_display_name)
                         or lower(coalesce(alloc->>'varietyName', '')) = lower(v_display_name)
                       ))
            )
       );

    if v_paddock_hits > 0 then
        v_in_use_reason := 'paddock';
    end if;

    -- =================================================================
    -- Reference scan #2 — growth_stage_records (sql/055).
    -- `variety_id` may be the vineyard variety row id; `variety` is the
    -- saved display-name snapshot. Either link blocks hard-delete.
    -- =================================================================
    if v_in_use_reason is null then
        select count(*) into v_growth_hits
          from public.growth_stage_records gsr
         where gsr.vineyard_id = v_row.vineyard_id
           and (gsr.deleted_at is null)
           and (
                gsr.variety_id = v_row.id
                or (v_display_name <> '' and lower(coalesce(gsr.variety, '')) = lower(v_display_name))
           );

        if v_growth_hits > 0 then
            v_in_use_reason := 'growth_record';
        end if;
    end if;

    -- =================================================================
    -- Reference scan #3 — trip_cost_allocations (sql/059).
    -- =================================================================
    if v_in_use_reason is null then
        select count(*) into v_trip_cost_hits
          from public.trip_cost_allocations tca
         where tca.vineyard_id = v_row.vineyard_id
           and (tca.deleted_at is null)
           and (
                tca.variety_id = v_row.id
                or (v_display_name <> '' and lower(coalesce(tca.variety, '')) = lower(v_display_name))
           );

        if v_trip_cost_hits > 0 then
            v_in_use_reason := 'trip_cost';
        end if;
    end if;

    if v_in_use_reason is not null then
        return jsonb_build_object(
            'success', false,
            'status',  'variety_in_use',
            'message', case v_in_use_reason
                          when 'paddock'       then 'This grape variety is used by one or more vineyard blocks and cannot be permanently deleted. You can archive it instead so historical records keep working.'
                          when 'growth_record' then 'This grape variety is used by existing growth-stage records and cannot be permanently deleted. You can archive it instead.'
                          when 'trip_cost'     then 'This grape variety is used by existing trip cost reports and cannot be permanently deleted. You can archive it instead.'
                          else 'This grape variety is referenced by existing vineyard records and cannot be permanently deleted. You can archive it instead.'
                       end,
            'reference_type', v_in_use_reason,
            'paddock_references', v_paddock_hits,
            'growth_record_references', v_growth_hits,
            'trip_cost_references', v_trip_cost_hits
        );
    end if;

    -- Safe to delete.
    delete from public.vineyard_grape_varieties
     where id = p_variety_id;

    return jsonb_build_object(
        'success', true,
        'status',  'hard_deleted',
        'message', 'Custom grape variety deleted.',
        'variety_id', v_row.id,
        'variety_key', v_row.variety_key
    );
end;
$$;

grant execute on function public.hard_delete_unused_custom_grape_variety(uuid)
    to authenticated;

comment on function public.hard_delete_unused_custom_grape_variety(uuid) is
    'Permanently delete a vineyard-scoped CUSTOM grape variety only when no '
    'paddock allocation, growth record, or trip cost allocation references it. '
    'Built-in/system varieties are always refused. Owner/manager only. '
    'Returns jsonb { success, status, message } — see sql/089 header for statuses.';
