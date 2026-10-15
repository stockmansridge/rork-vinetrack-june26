# VineTrack legacy Save for Later — backend receipt contract v1

**Read-only handoff for Rork; last verified 15 October 2026.**
**Database:** VineTrackv2, Supabase project ref tbafuqwruefgkbyxrxyb (PostgreSQL 17).
**Applied migration:** 20261015102804_legacy_spray_pair_receipts_v1.
**Reference SQL:** [exact previously applied migration](legacy_spray_pair_v1_applied_migration.sql) — DO NOT REAPPLY.
**Synthetic fingerprint fixture:** [PostgreSQL-verified golden request/hash](legacy_spray_pair_v1_golden.json) — DO NOT SUBMIT TO LIVE DATABASE.

## 1. Endpoint contract (deployed)

These are PostgreSQL RPC functions exposed through the existing Supabase Data API; both take the *same* argument shape:

- POST /rest/v1/rpc/save_legacy_spray_pair_v1
- POST /rest/v1/rpc/recover_legacy_spray_pair_v1

Arguments (JSON envelope):

~~~json
{
  "p_operation_id": "33333333-3333-4333-8333-333333333333",
  "p_trip": { "...": "original, frozen Trip INSERT body" },
  "p_record": { "...": "original, frozen Spray Record INSERT body" }
}
~~~

Function SQL signatures:
- public.save_legacy_spray_pair_v1(p_operation_id uuid, p_trip jsonb, p_record jsonb) returns jsonb
- public.recover_legacy_spray_pair_v1(p_operation_id uuid, p_trip jsonb, p_record jsonb) returns jsonb

Use the user's Supabase access token with Authorization: Bearer <user JWT>, and the normal application publishable/anon API key headers. Never use a service-role key in mobile clients or call these with a different/current account than the one that originally prepared the request. The project reference alone is NOT credentials.

These RPCs apply **only** to newly journaled *legacy inactive no-route Save for Later* paired creates. The full server request comprises authenticated actor + operation UUID + vineyard UUID + Trip INSERT JSON + Spray Record INSERT JSON. No old REST row is adopted as a new operation.

## 2. Exact response formats and semantics

The SQL returns jsonb, not a list of rows. The timestamp below is illustrative (the actual one is assigned by PostgreSQL and is preserved on identical replay).

### A. Accepted — after BOTH inserts and receipt commit atomically

~~~json
{
  "version": 1,
  "status": "accepted",
  "operation_id": "33333333-3333-4333-8333-333333333333",
  "vineyard_id": "22222222-2222-4222-8222-222222222222",
  "trip_id": "44444444-4444-4444-8444-444444444444",
  "spray_record_id": "55555555-5555-4555-8555-555555555555",
  "request_sha256": "f1950e94f85c8c3c3c431d74fcc83a17b7428a0b13e38a6c23f33aedab992a23",
  "committed_at": "2026-10-15T03:00:01+00:00"
}
~~~

The fingerprint shown is the **synthetic golden request only**. Actual live requests have different fingerprints. An exact repeat of an accepted RPC with the same original operation, actor, vineyard and both frozen payloads returns the **identical stored receipt** without inserting again.

### B. Rejected — terminal, immutable outcome for an attempted new operation

~~~json
{
  "version": 1,
  "status": "rejected",
  "operation_id": "33333333-3333-4333-8333-333333333333",
  "vineyard_id": "22222222-2222-4222-8222-222222222222",
  "trip_id": "44444444-4444-4444-8444-444444444444",
  "spray_record_id": "55555555-5555-4555-8555-555555555555",
  "request_sha256": "f1950e94f85c8c3c3c431d74fcc83a17b7428a0b13e38a6c23f33aedab992a23",
  "committed_at": "2026-10-15T03:00:01+00:00",
  "code": "identity_conflict"
}
~~~

Currently possible *stored rejection* codes:
- identity_conflict: one or both original IDs already exist without this matching immutable receipt, or are owned by a different accepted pair.
- validation_or_reference_conflict: known SQL constraint/reference failures during transactional insert, with both attempted inserts rolled back.

Reject is not success; preserve the local attempted request, do not start or mark synced. A new different operation is a separate operator decision, NOT an automatic remediation.

### C. Unknown — recovery lookup found NO matching operation row

~~~json
{
  "version": 1,
  "status": "unknown",
  "operation_id": "33333333-3333-4333-8333-333333333333"
}
~~~

Unknown is **not** evidence of success or of non-delivery of an older REST request. The recovery endpoint has no side effects. With legacy REST-uncertain or pre-contract attempts, keep the local hold; do not create a fresh pair or adopt current tables. For a provably RPC-only new attempt, a further *identical same-operation RPC* can be considered under the new idempotent contract and the existing account/session fences, but may not mint new IDs, change request bytes or bypass uncertain-state safeguards.

### D. Conflict — operation ID already used with a different actor/scope/identity/body

~~~json
{
  "version": 1,
  "status": "conflict",
  "code": "operation_payload_mismatch"
}
~~~

Conflict is **not** an accepted/rejected receipt; it contains no identifiers or SHA and must never clear holds. Do not infer ownership or disclose another user's data from this status.

### E. SQL/PostgREST errors are NOT receipts

Malformed/unexpected fields, missing or revoked access, unsupported application mode and many validation errors raise SQL exceptions (typically SQLSTATE 22023 for invalid request or 42501 for permission failures). Unhandled trigger failures or other database errors also roll back the transaction. Do NOT coerce an HTTP error, 409, SQLSTATE or failed/empty JSON parse into any of the four JSON receipt statuses. Retain evidence and mark held/reconciliation required. A stored 'rejected' receipt only exists if the function deliberately persisted one.

## 3. Request and fingerprint rules — exact

An operation UUID must be created and durably stored together with full original **typed insert bodies** before ANY network send. IDs and timestamps must never be reminted on retries. For both iOS and Android, add this to *new* journal records only. Existing legacy WAL records without a proven operation UUID/identical original RPC body remain held.

The backend computes a server-authoritative fingerprint with these precise expressions:

~~~sql
v_hash := encode(
  extensions.digest(
    convert_to(
      jsonb_build_object(
        'v', 1,
        'actor', auth.uid(),
        'operation', p_operation_id,
        'vineyard', (p_trip->>'vineyard_id')::uuid,
        'trip', p_trip,
        'record', p_record
      )::text,
      'UTF8'
    ),
    'sha256'
  ),
  'hex'
);
~~~

This is **PostgreSQL's jsonb::text representation** of the combined object (then UTF-8 SHA-256). It is *not*:
- Hash of HTTP JSON bytes;
- Hash of Swift JSONEncoder/Kotlin serializer output;
- SortedKeys JSON, JavaScript JSON.stringify, RFC 8785/JCS, or a hash of only Trip/Record;
- A signature that can be trusted separately from the authenticated RPC response.

Whitespace/property ordering in submitted JSON is normalized by PostgreSQL parsing into jsonb. JSON number formatting and strings follow PostgreSQL jsonb semantics; do not guess a cross-platform encoder. PostgreSQL-derived golden:
- Auth actor: 11111111-1111-4111-8111-111111111111
- Operation: 33333333-3333-4333-8333-333333333333
- Vineyard: 22222222-2222-4222-8222-222222222222
- Original Trip ID: 44444444-4444-4444-8444-444444444444
- Original Spray Record ID: 55555555-5555-4555-8555-555555555555
- Canonical byte count: **944**
- SHA-256: **f1950e94f85c8c3c3c431d74fcc83a17b7428a0b13e38a6c23f33aedab992a23**

Exact JSON request, canonical jsonb text and hash are in the golden fixture. The actor is supplied by authenticated PostgreSQL auth.uid(), **not** as a user-controlled p_actor parameter; the fixture UUIDs are synthetic and do not grant access to a live vineyard.

**Recommended client acceptance gate:** retain immutable request JSON/IDs locally; send that exact request over the authenticated RPC; accept only an authenticated, well-formed version-1 'accepted' receipt carrying matching operation/vineyard/Trip/Record IDs and 64-lowercase-hex SHA. To verify content binding without implementing a potentially incorrect JSONB encoder, call recover with the exact frozen request and demand the matching stored receipt including the SHA. The server compares both jsonb bodies and the hash, as well as actor/scope/IDs. On any mismatch or lost follow-up, HOLD. An independent client fingerprint implementation is optional **only after it matches this golden and further real-payload PG vectors**.

## 4. Trip insert allowlist (exact)

Keys allowed in p_trip (all other keys rejected; no update/complete/tracking values):

id, vineyard_id, paddock_id, paddock_ids, paddock_name, tracking_pattern, start_time, is_active, is_paused, person_name, trip_function, trip_title, machine_id, tractor_id, work_task_id, operator_user_id, worker_type_id, total_distance, path_points, start_engine_hours, seeding_details, row_sequence, sequence_index, current_row_number, next_row_number, total_tanks, created_by, client_updated_at.

Mandatory guard:
- id, vineyard_id, start_time, client_updated_at must exist and parse as required;
- is_active is exactly false, is_paused false or absent;
- work_task_id must be absent/null;
- row_sequence and path_points empty arrays or omitted;
- total_distance zero or omitted;
- created_by when supplied must equal the authenticated actor;
- paddock_id and each paddock_ids item must belong to the vineyard.
- end_time, coverage/tank runtime, delete fields, created_at, updated_at and sync_version are **NOT** client-allowed. The server supplies audit values and initial version.

## 5. Spray Record insert allowlist (exact)

id, vineyard_id, date, start_time, temperature, wind_speed, wind_direction, humidity, spray_reference, notes, number_of_fans_jets, average_speed, equipment_type, tractor, tractor_gear, machine_id, tractor_id, spray_equipment_id, operation_type, trip_id, spray_job_id, is_template, tanks, gross_area_ha, treated_area_ha, application_mode, treated_area_method, band_width_total_metres, band_width_left_metres, band_width_right_metres, canonical_row_length_metres, row_spacing_metres, geometry_source, geometry_quality, carrier_volume_basis, total_carrier_litres, carrier_litres_per_hectare, dilute_litres_per_100m, applied_litres_per_100m, concentration_factor, targets, spray_head_target, ground_application_target, carrier_area_basis, application_blocks, entry_source, created_by, client_updated_at.

Mandatory guard:
- id, vineyard_id, trip_id, date, start_time, client_updated_at required;
- record.trip_id == trip.id; record.vineyard_id == trip.vineyard_id;
- is_template false or absent;
- tanks **must be a JSON array**, including [] when empty;
- entry_source, if supplied, must be tracked (manual spray is excluded);
- created_by, if supplied, must match auth.uid();
- no block_ids: the server's existing trigger derives them from application_blocks;
- no deleted_at, updated_at, created_at, sync_version or historical completion/end_time fields.

Use existing validated client insert projection. **Do not serialize complete Trip/SprayRecord models**: those include fields outside the permitted insert allowlists. Preserve exact original values/conditions/quantities from the prepared request. Unexpected new planning fields may be blocked; report them for backend-owner review rather than silently stripping necessary operational evidence or widening the RPC.

## 6. Authentication / authorization / persistence

- RPC permissions: EXECUTE granted to authenticated only; anon and public denied.
- Every request uses auth.uid() and requires existing vineyard role owner, manager, supervisor or operator via public.has_vineyard_role(vineyard, roles).
- A newly supplied actor ID is NOT trusted; created_by is validated when present and overwritten to auth.uid() at insert.
- The private table is vinetrack_private.legacy_spray_pair_receipts_v1. Its schema/table have no direct client permissions and RLS is enabled. The RPC intentionally uses SECURITY DEFINER with explicit authenticated role + vineyard checks and empty search_path.
- No direct client access to the receipt ledger. Never put service-role keys on a device.
- The exact same operation/payload returns the stored receipt; changed payload/op collision returns conflict; rows existing without matching receipt yield terminal identity_conflict rather than adoption.
- The new RPC does NOT retroactively govern old REST POSTs; unreceipted historical/rest-uncertain saves remain held.
- A new RPC attempt's Trip and Spray Record insert and immutable receipt are a single Postgres transaction; known insert constraint failures leave no orphan half-pair.
- Trigger behavior, live auth and network loss still require explicit controlled integration acceptance.

## 7. Controlled acceptance plan / existing runner status

**No dedicated real-JWT synthetic vineyard/users or authenticated runner was provisioned or verified as part of backend migration.** Do not claim authenticated device/API acceptance based on SQL Editor admin execution, service-role calls or simulated JWT variables.

Before remote write tests, arrange a distinct dedicated test vineyard with genuine separate Supabase Auth users A and B, explicit memberships, safe synthetic block data, and a verified cleanup path. Do not use customer records.

Test through authenticated /rest/v1/rpc requests or normal app transport with:
1. User A, initial same-actor pair save -> accepted, both rows + one receipt.
2. Repeat same full request -> byte-equivalent stored receipt, no extra rows.
3. Lose HTTP response after commit -> authenticated recover with exactly same arguments -> same accepted receipt.
4. Same op UUID + changed payload -> conflict, no changes.
5. New op UUID + already-used Trip or Record ID -> immutable rejected identity_conflict.
6. Synthetic invalid reference/constraint failure -> either immutably rejected or SQL error with atomic rollback; never orphan.
7. Simultaneous same-op retry -> one acceptance, same receipt; concurrent same-IDs/new op -> identity_conflict.
8. User B/foreign vineyard/revoked member -> denied, no data leakage.
9. Server-reachable but missing receipt for an old REST attempt -> unknown; retain hold.
10. Real handset kill/restart, token/actor change, offline recovery; no cross-account adoption, no dependent Start while held.
11. Independent unrelated records continue syncing, and frozen Live Trip/planning logic remain unchanged.

**Data handling:** Do not mutate production/customer records. Test-only documents must be explicit and segregated. Use normal authenticated client tokens, never service_role. For successful live test write and cleanup, use the appropriate authorised test-data lifecycle, not unconditional table delete on production.

## 8. Current verified state and gaps

Database migration is applied; functions exist with authenticated EXECUTE but no anon EXECUTE; private table RLS enabled; read-only SQL reports receipt_count=0 at first post-deployment verification. An unauthenticated recovery call correctly raised 42501 Authentication required. This does NOT prove that authenticated pair creation, trigger behavior, real HTTP reconnect or idempotency have passed.

Supabase Security Advisor flags the two SECURITY DEFINER functions as authenticated-executable. This is intentional for the RPC interface, but authorization and adversarial tests are mandatory; no broad generic RLS bypass should be assumed safe.

No code changes to customer data, existing REST flows, Live Trips, new spray planning, tank actuals or calculator equations were made by this migration.

**Rork should integrate client code only (no SQL/deployment or store access), then report exact source SHA, tests, native builds, and separately the blocked authenticated backend-test scope if user A/B credentials and isolated vineyard do not yet exist.**
