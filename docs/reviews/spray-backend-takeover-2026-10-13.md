# VineTrack Spray Planning — Backend Takeover Review

**Status:** read-only production audit, 13 October 2026. **No production SQL applied, no workflow activated, no release.**

**Supabase:** VineTrackv2 `tbafuqwruefgkbyxrxyb`, PostgreSQL 17.6. This document is a verified *object/contract inventory*, not a server-gate implementation and not a staging pass.

## Decisions already agreed

- Full Tank partial area is **planned-only**; no invented partial-block or row coverage. Trip actuals remain separate.
- Standard Pass = one row equivalent, sprayer sprays facing sides of two rows across the aisle. Over-Row = two row equivalents.
- Controller L/100m of travel is distinct from physical row L/100m and canonical L/ha.
- Missing verified permission/limits for a **concentrated dilute-rate product** is *not* approval. No CF-only or acknowledgement bypass. Preserve area-based rates and established dosing equations.
- Historical records remain frozen, local offline records remain durable, and new planning execution stays blocked pending server/staging acceptance.

## Observations verified directly against the production catalogs (read-only)

- Core relations present: `public.spray_records`, `public.spray_jobs`, `public.trips`, `public.spray_tank_actuals`, `public.chemical_v3_rate_options`, `public.chemical_v3_product_revisions`, `public.chemical_v3_documents`, `public.saved_chemicals`, `public.master_chemicals`.
- The 14 proposed SQL v2 planning column names are **absent** in `spray_records`/`spray_jobs`. No v2 deployment.
- Existing RLS: spray-record inserts/updates allow owner/manager/supervisor/operator; jobs require owner/manager. RLS is separate from chemical-label admission. `chemical_v3_rate_options` has a readable authenticated policy but no admission policy inferred from that.
- Existing record triggers include: `trg_spray_records_manual_guard_v1`, `trg_spray_records_manual_compatibility_v1`, `trg_spray_records_validate_block_vineyard`, `trg_spray_records_derive_block_ids`, `spray_records_validate_job_link_trg`, `trg_integration_evt_spray_records`. No installed named shared spray-label admission trigger was found.
- Existing job triggers include `spray_jobs_freeze_completed_provenance_trg`, `spray_jobs_validate_plan_provenance_trg`, `spray_jobs_validate_refs_trg`. Their presence is **not** proof of new planning-field immutability.
- Trip triggers include `trg_trips_manual_guard_v1`, `zz_trips_completed_invariant`, `trg_integration_evt_trips`. No installed named shared spray-label admission trigger was found.
- Tank-actual trigger: `spray_tank_actuals_before_write`. This guards actuals, not automatically planned operational tank start.
- Current functions include `save_spray_trip_worksheet_v1`, `upsert_spray_tank_actual`, `validate_spray_tank_actual_chemicals_v1`, `complete_spray_record`, `save_manual_spray_v1`, and `spray_jobs_freeze_completed_provenance`. Several are SECURITY DEFINER with `search_path=public`; any new security-sensitive procedure needs a reviewed, fixed search path and restricted execute privileges.
- Existing data supports chemical identity, verification and rate evidence, but no established typed concentration-permission and maximum-concentration rule was found. `max_value` on `chemical_v3_rate_options` is a *rate maximum*, not necessarily an allowed concentration factor.
- There are currently **no Supabase development branches**. Migration history is incomplete as a bootstrap (only 29 recorded migrations at prior audit), so a branch created from migrations cannot be assumed to reproduce the live schema.

## Required sequence — do not skip gates

1. **Private faithful schema-only staging**. Run the existing `scripts/export-vinetrack-review-schema.sh` with an authorized local PostgreSQL credential; review roles/managed schema, restore privately into PostgreSQL 17-compatible isolated staging. No customer/auth rows, production secrets, live network side effects or active schedules. Verify parity of schemas, object hashes, functions, owners, triggers, RLS, grants, extensions, and roles. The dump cannot be generated from the current Supabase connector's SQL API.
2. **SQL v2 storage test**. Execute the repo's `sql/review/spray_configuration_full_tank_planning_draft.sql` and validation harness *only in verified staging*, with synthetic fixtures. Prove nullability, no historical changes, explicit clearing, old-client paths, RLS, triggers, snapshot freezing and online save/reopen/replay.
3. **Review typed label evidence**. Reuse `chemical_v3_rate_options` and current approved revision/doc linkage as proposed in `docs/spray-server-compliance-proposal.md`; a nullable, reviewed/versioned permission field stays unknown until actual applicable approved label evidence is attached. Do not auto-seed from generic product approval, rate maxima, AI text or preferred rates.
4. **Independent reference and dose validation**. Trusted server-side checks must derive/calibrate dilute reference and rate/area/tank context from reviewed, server-bound evidence. Never trust client CF, arbitrary JSON or declarations. If evidence is insufficient, block executable concentrated dilute mixes; preserve area-only dosage and historical factual entry.
5. **Complete route inventory and enforcement**. Trace every record INSERT/UPDATE, executable job transition, spray Trip creation/activation/relink, tank session start and RPC/worksheet path. Install shared admission consistently, before side effects, transactionally. Account for `trips.tank_sessions` JSONB and `spray_tank_actuals` as distinct authorities; never assume one trigger covers all.
6. **Synthetic staging acceptance**. Prove allowed/bounded, prohibited, unknown, spoofed CF=1, stale hash, wrong registration/country/method, ambiguous older-client recipe, multi-product/multi-tank and area-only recipes. Validate rejection SQLSTATE/reason and exact zero operational side effects, including audit fields and RLS-hidden rows. Native restart/idempotent replay and end-to-end online execution remain separate mobile acceptance.
7. **Approval**. Present SQL diff, role grants, rollback, actor/RLS cases, staging logs and client acceptance; obtain explicit approval before *any* production DDL, new operational activation or release.

## Outstanding blockers

- No faithful restored isolated schema or authenticated staging environment.
- No deployed server label-authority gate; repo acceptance harness remains unexecuted.
- No certified reviewer-bound applicable concentration permissions or server dilute-reference contract.
- iOS wider baseline classification and real mobile visual/process-restart acceptance still pending.

## Security and operations requirements

No production DDL, migrations, grants, role provisioning, data exports, production writes, billing, new branch/project creation, chemical authorizations or releases in this review. Secrets and full schema dumps stay off GitHub/chat. Client CF is a computed display value, not legal approval. Do not alter dosing equations, historical amounts, manual factual records or existing tank actuals.

**Next deliverable:** a faithful staging clone and server admission implementation proposal with exact touched objects and tests. This review branch carries only review documentation, not an executable migration.
