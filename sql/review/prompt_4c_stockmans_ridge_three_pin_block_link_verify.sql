-- Prompt 4C — Stockmans Ridge three-pin block-link repair verification
-- READ ONLY. Run after the APPLY file commits.
-- Both reports share one repeatable-read snapshot. They check the exact three
-- IDs, joined block name, audited transition, and every unrelated pin field.

begin transaction isolation level repeatable read read only;

with params as (
  select
    'a778659b-1a13-4e56-bc1b-f1a340bcb5da'::uuid as run_id,
    'fe952afe-437f-4be7-8cbf-fdd8e630411c'::uuid as vineyard_id,
    '53128d1c-d745-4d99-8194-52e0ba08767b'::uuid as target_paddock_id,
    array[
      '2e4f7cc6-4876-47d5-b280-30d1ea1259ac'::uuid,
      '2c981eca-2981-435a-ac2a-a10aaaabf0ee'::uuid,
      'b46d0087-76ec-443b-936f-f010c8baffe3'::uuid
    ]::uuid[] as expected_ids
), expected as (
  select unnest(x.expected_ids) as pin_id
  from params x
), audited as (
  select e.pin_id as expected_pin_id, a.*
  from expected e
  cross join params x
  left join public.pin_block_link_repair_audit a
    on a.run_id = x.run_id and a.pin_id = e.pin_id
), changed_keys as (
  select
    a.expected_pin_id as pin_id,
    coalesce(array_agg(keys.key order by keys.key)
      filter (where keys.key is not null), array[]::text[]) as all_changed_keys
  from audited a
  left join lateral (
    select coalesce(before_item.key, after_item.key) as key
    from jsonb_each(coalesce(a.before_row, '{}'::jsonb)) before_item
    full join jsonb_each(coalesce(a.after_row, '{}'::jsonb)) after_item using (key)
    where before_item.value is distinct from after_item.value
  ) keys on true
  group by a.expected_pin_id
)
select
  x.run_id,
  a.status as audit_status,
  a.expected_pin_id as pin_id,
  p.button_name as pin_type,
  p.is_completed,
  p.deleted_at,
  p.latitude,
  p.longitude,
  p.paddock_id as current_block_id,
  pd.name as current_block_name,
  a.target_paddock_id as audited_target_block_id,
  a.before_row->>'paddock_id' as before_block_id,
  a.after_row->>'paddock_id' as audited_after_block_id,
  (a.before_row->>'sync_version')::integer as before_sync_version,
  (a.after_row->>'sync_version')::integer as audited_after_sync_version,
  p.sync_version as current_sync_version,
  a.before_row->>'updated_at' as before_updated_at,
  a.after_row->>'updated_at' as audited_after_updated_at,
  p.updated_at as current_updated_at,
  ck.all_changed_keys,
  coalesce(
    ck.all_changed_keys <@ array['paddock_id', 'sync_version', 'updated_at']::text[],
    false
  ) as only_authorized_columns_changed,
  coalesce(to_jsonb(p) = a.after_row, false) as current_row_matches_audited_after_image,
  coalesce(
    (to_jsonb(p) - array['paddock_id', 'sync_version', 'updated_at']::text[])
    =
    (a.before_row - array['paddock_id', 'sync_version', 'updated_at']::text[]),
    false
  ) as all_unrelated_pin_fields_unchanged,
  coalesce(
    a.pin_id = a.expected_pin_id
    and a.run_id = x.run_id
    and a.vineyard_id = x.vineyard_id
    and p.vineyard_id = x.vineyard_id
    and a.target_paddock_id = x.target_paddock_id
    and a.before_row->>'paddock_id' is null
    and (a.after_row->>'paddock_id')::uuid = x.target_paddock_id
    and (a.after_row->>'sync_version')::integer
        = (a.before_row->>'sync_version')::integer + 1
    and p.paddock_id = x.target_paddock_id
    and pd.id = x.target_paddock_id
    and pd.vineyard_id = x.vineyard_id
    and pd.deleted_at is null
    and pd.name = 'Pinot Noir'
    and a.status = 'applied'
    and to_jsonb(p) = a.after_row
    and ck.all_changed_keys <@ array['paddock_id', 'sync_version', 'updated_at']::text[],
    false
  ) as repair_verified
from audited a
cross join params x
left join public.pins p on p.id = a.expected_pin_id
left join public.paddocks pd on pd.id = p.paddock_id
left join changed_keys ck on ck.pin_id = a.expected_pin_id
order by a.expected_pin_id;

-- Expected package-level result: 3 expected, 3 audited, 3 verified, true.
with params as (
  select
    'a778659b-1a13-4e56-bc1b-f1a340bcb5da'::uuid as run_id,
    'fe952afe-437f-4be7-8cbf-fdd8e630411c'::uuid as vineyard_id,
    '53128d1c-d745-4d99-8194-52e0ba08767b'::uuid as target_paddock_id,
    array[
      '2e4f7cc6-4876-47d5-b280-30d1ea1259ac'::uuid,
      '2c981eca-2981-435a-ac2a-a10aaaabf0ee'::uuid,
      'b46d0087-76ec-443b-936f-f010c8baffe3'::uuid
    ]::uuid[] as expected_ids
), expected as (
  select unnest(x.expected_ids) as pin_id
  from params x
), checks as (
  select
    e.pin_id,
    coalesce(
      a.pin_id = e.pin_id
      and a.vineyard_id = x.vineyard_id
      and a.target_paddock_id = x.target_paddock_id
      and a.status = 'applied'
      and a.before_row->>'paddock_id' is null
      and (a.after_row->>'paddock_id')::uuid = x.target_paddock_id
      and (a.after_row->>'sync_version')::integer
          = (a.before_row->>'sync_version')::integer + 1
      and p.paddock_id = x.target_paddock_id
      and pd.name = 'Pinot Noir'
      and pd.vineyard_id = x.vineyard_id
      and pd.deleted_at is null
      and to_jsonb(p) = a.after_row
      and (
        to_jsonb(p) - array['paddock_id', 'sync_version', 'updated_at']::text[]
      ) = (
        a.before_row - array['paddock_id', 'sync_version', 'updated_at']::text[]
      ),
      false
    ) as is_verified
  from expected e
  cross join params x
  left join public.pin_block_link_repair_audit a
    on a.run_id = x.run_id and a.pin_id = e.pin_id
  left join public.pins p on p.id = e.pin_id
  left join public.paddocks pd on pd.id = p.paddock_id
), audit_scope as (
  select
    count(a.pin_id)::integer as run_audit_count,
    count(a.pin_id) filter (where a.pin_id = any(x.expected_ids))::integer as expected_id_audit_count
  from params x
  left join public.pin_block_link_repair_audit a on a.run_id = x.run_id
)
select
  count(*)::integer as expected_pin_count,
  s.run_audit_count as audited_pin_count,
  count(*) filter (where c.is_verified)::integer as verified_pin_count,
  (
    count(*) = 3
    and s.run_audit_count = 3
    and s.expected_id_audit_count = 3
    and bool_and(coalesce(c.is_verified, false))
  ) as package_verified
from checks c
cross join audit_scope s
group by s.run_audit_count, s.expected_id_audit_count;

commit;
