-- Read-only controlled verification for one approved test pin.
-- Replace the zero UUID in every params CTE with the supplied test pin ID.
-- Run the queue gate first. Invoke the worker only when safe_to_invoke is true.

-- 1. Whole-queue gate. The worker claims up to 20 due rows and is not pin-scoped.
with params as (
  select '00000000-0000-0000-0000-000000000000'::uuid as test_pin_id
), open_queue as (
  select q.*,
    q.available_at <= now()
      and (q.lease_expires_at is null or q.lease_expires_at < now())
      and q.attempts < 8 as is_claimable_now
  from public.pin_location_enrichment_queue q
  where q.terminal_at is null
), summary as (
  select
    count(q.pin_id) as open_queue_rows,
    count(*) filter (where q.pin_id = p.test_pin_id) as approved_open_rows,
    count(*) filter (where q.pin_id <> p.test_pin_id) as unapproved_open_rows,
    count(*) filter (where q.is_claimable_now) as claimable_now_rows,
    count(*) filter (where q.is_claimable_now and q.pin_id = p.test_pin_id) as approved_claimable_now_rows,
    count(*) filter (where q.is_claimable_now and q.pin_id <> p.test_pin_id) as unapproved_claimable_now_rows,
    count(*) filter (where q.lease_expires_at >= now()) as actively_leased_rows
  from params p
  left join open_queue q on true
)
select s.*,
  s.open_queue_rows > 0
    and s.unapproved_open_rows = 0
    and s.claimable_now_rows between 1 and 20
    and s.approved_claimable_now_rows = s.claimable_now_rows
    and s.unapproved_claimable_now_rows = 0
    and s.actively_leased_rows = 0 as safe_to_invoke
from summary s;

-- 2. Inspect every open queue row before invocation. Every pin_id must be approved.
with params as (
  select '00000000-0000-0000-0000-000000000000'::uuid as test_pin_id
)
select
  q.pin_id,
  q.pin_id = p.test_pin_id as is_approved_test_pin,
  q.evidence_revision,
  q.resolver_version,
  q.available_at,
  q.attempts,
  q.lease_token,
  q.lease_expires_at,
  q.last_error,
  q.terminal_at
from public.pin_location_enrichment_queue q
cross join params p
where q.terminal_at is null
order by q.available_at, q.pin_id, q.evidence_revision;

-- 3. Original pin identity and immutable raw capture fields.
with params as (
  select '00000000-0000-0000-0000-000000000000'::uuid as test_pin_id
)
select
  p.id as pin_id,
  p.vineyard_id,
  p.trip_id,
  p.created_by,
  p.created_at as captured_at,
  p.latitude as raw_latitude,
  p.longitude as raw_longitude,
  p.heading as raw_heading,
  p.button_name,
  p.mode,
  p.title,
  p.notes,
  p.photo_path,
  p.deleted_at
from public.pins p
join params x on x.test_pin_id = p.id;

-- 4. Uploaded immutable evidence. The payload and observation history stay visible.
with params as (
  select '00000000-0000-0000-0000-000000000000'::uuid as test_pin_id
)
select
  e.pin_id,
  e.evidence_revision,
  e.resolver_version,
  e.captured_at,
  e.location_observed_at,
  e.raw_latitude,
  e.raw_longitude,
  e.horizontal_accuracy_m,
  e.heading_degrees,
  e.heading_source,
  e.heading_observed_at,
  e.pressed_side,
  e.supported_paddock_id,
  e.supported_driving_row,
  e.supported_pin_row,
  e.supported_pin_side,
  e.supported_snapped_latitude,
  e.supported_snapped_longitude,
  e.aisle_lock,
  e.observations,
  e.capture_provenance,
  e.geometry_revision,
  e.geometry_hash,
  e.received_at,
  e.payload_hash
from public.pin_capture_evidence e
join params p on p.test_pin_id = e.pin_id
order by e.evidence_revision;

-- 5. Current queue state for this pin. No row after a successful terminal outcome is expected.
with params as (
  select '00000000-0000-0000-0000-000000000000'::uuid as test_pin_id
)
select
  q.pin_id,
  q.evidence_revision,
  q.resolver_version,
  q.available_at,
  q.attempts,
  q.lease_token,
  q.lease_expires_at,
  q.last_error,
  q.terminal_at
from public.pin_location_enrichment_queue q
join params p on p.test_pin_id = q.pin_id
order by q.evidence_revision, q.resolver_version;

-- 6. Worker and optional-confirmation outcomes with placement before/after images.
with params as (
  select '00000000-0000-0000-0000-000000000000'::uuid as test_pin_id
)
select
  a.id as audit_id,
  a.pin_id,
  a.evidence_revision,
  a.resolver_version,
  a.outcome,
  a.before_placement,
  a.after_placement,
  a.detail,
  a.created_at
from public.pin_location_enrichment_audit a
join params p on p.test_pin_id = a.pin_id
order by a.created_at, a.id;

-- 7. Final placement and revision state. Compare raw coordinates to query 3.
with params as (
  select '00000000-0000-0000-0000-000000000000'::uuid as test_pin_id
)
select
  p.id as pin_id,
  p.created_at as captured_at,
  p.latitude as raw_latitude,
  p.longitude as raw_longitude,
  p.paddock_id as attached_paddock_id,
  p.driving_row_number as aisle,
  p.pin_row_number as attached_row,
  p.pin_side as side,
  p.snapped_latitude,
  p.snapped_longitude,
  p.along_row_distance_m,
  p.snapped_to_row,
  p.location_enrichment_status,
  p.location_enrichment_revision,
  p.location_resolver_version,
  p.location_enriched_at,
  p.location_confirmation_revision,
  p.location_confirmed_at,
  p.location_confirmed_by,
  p.sync_version,
  p.notes,
  p.photo_path
from public.pins p
join params x on x.test_pin_id = p.id;
