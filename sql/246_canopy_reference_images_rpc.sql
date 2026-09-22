-- 246_canopy_reference_images_rpc.sql
-- Canopy Reference Images — narrow, read-only cross-platform contract.
--
-- Purpose: let iOS and Android read ONLY the Canopy Reference Images
-- configuration (config key `spray.canopy_reference_images`) without using the
-- broad get_system_feature_flags() RPC.
--
-- Nothing here touches canopy calculation logic, water rates, canopy sizes,
-- density, L/100 m, L/ha or concentration factors. Presentation assets only.
--
-- Stability contract for mobile caching: the returned `path` and `updated_at`
-- values are stored verbatim and change ONLY when a System Admin replaces or
-- resets that slot. No cache-busting token is generated on read.

create or replace function public.get_canopy_reference_images_v1()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
    v_value jsonb;
    v_updated_at timestamptz;
    v_images jsonb := '{}'::jsonb;
    v_key text;
    v_entry jsonb;
begin
    -- Signed-in VineTrack users only.
    if auth.uid() is null then
        raise exception 'authentication required' using errcode = '42501';
    end if;

    select f.value, f.updated_at
    into v_value, v_updated_at
    from public.system_feature_flags f
    where f.key = 'spray.canopy_reference_images'
    limit 1;

    if v_value is not null and jsonb_typeof(v_value) = 'object' then
        for v_key, v_entry in select * from jsonb_each(v_value)
        loop
            -- Only the eight permanent semantic keys, and only well-formed entries.
            if v_key in (
                'canopy.vsp.small',
                'canopy.vsp.medium',
                'canopy.vsp.large',
                'canopy.vsp.full',
                'canopy.sprawl.small',
                'canopy.sprawl.medium',
                'canopy.sprawl.large',
                'canopy.sprawl.full'
            )
            and jsonb_typeof(v_entry) = 'object'
            and coalesce(v_entry->>'path', '') <> ''
            then
                v_images := v_images || jsonb_build_object(
                    v_key,
                    jsonb_strip_nulls(jsonb_build_object(
                        'path', v_entry->>'path',
                        'updated_at', v_entry->>'updated_at'
                    ))
                );
            end if;
        end loop;
    end if;

    return jsonb_build_object(
        'bucket', 'guide-images',
        'config_updated_at', v_updated_at,
        'images', v_images
    );
end;
$$;

comment on function public.get_canopy_reference_images_v1() is
    'Read-only Canopy Reference Images config for signed-in VineTrack clients. Returns {bucket, config_updated_at, images:{<semantic key>:{path,updated_at}}}. Missing key = use the bundled default image.';

revoke all on function public.get_canopy_reference_images_v1() from public;
revoke all on function public.get_canopy_reference_images_v1() from anon;
grant execute on function public.get_canopy_reference_images_v1() to authenticated;
grant execute on function public.get_canopy_reference_images_v1() to service_role;
