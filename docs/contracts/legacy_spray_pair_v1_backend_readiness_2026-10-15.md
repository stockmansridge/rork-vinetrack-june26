# Legacy spray pair receipt v1 — backend readiness and planning-field scope audit
Date: 2026-10-15 (read-only verification)
Project: VineTrackv2 (`tbafuqwruefgkbyxrxyb`)
Status: deployed receipt-v1, authenticated server acceptance NOT established. New planning schema NOT deployed.

## Verified production catalog (read-only)

- `public.save_legacy_spray_pair_v1(uuid,jsonb,jsonb)` and `public.recover_legacy_spray_pair_v1(uuid,jsonb,jsonb)` exist. Their v1 receipt is bound to actor, operation, vineyard, frozen Trip and Spray Record identities and full exact JSONB payload.
- The private receipt ledger `vinetrack_private.legacy_spray_pair_receipts_v1` exists with RLS on; no `anon`/`authenticated` direct table access or private-schema USAGE. Authenticated RPC execution exists with internal actor + vineyard-role checks.
- Authentication and actual two-row creation have not been verified with genuine client JWTs. This is a release blocker. Neither SQL Editor nor mock claims nor service role qualifies.
- Read-only receipt count at last check: zero; no matching accepted historical operation can be inferred from ordinary old REST-created rows.
- No Supabase development branches were listed for the project at inspection time.

**Mismatch:**
`information_schema.columns` confirms that all 14 new planning fields are absent from `public.spray_records`; the seven input fields are also absent from `public.spray_jobs`. This is not only an RPC allowlist issue.

The absent `spray_records` fields:
`sprayer_configuration`,
`spray_planning_method`,
`full_tank_specification`,
`planning_input_provenance`,
`planning_intended_tank_litres`,
`planning_target_area_ha`,
`planning_calibrated_litres_per_hectare`,
`planned_application_area_ha`,
`resolved_planning_carrier_litres`,
`resolved_planning_litres_per_hectare`,
`resolved_planning_physical_row_litres_per_100m`,
`resolved_planning_concentration_factor`,
`controller_litres_per_100m_travel`,
`effective_working_width_metres`.

The seven operator-input fields (first seven above) are also missing from `spray_jobs`. Explicit NULL fields remain schema keys, and may not be ignored as harmless.

## Existing checked-in planning migration is NOT approved/applied

- `sql/review/spray_configuration_full_tank_planning_draft.sql` is a **REVIEW DRAFT v2** with explicit "DO NOT APPLY ANYWHERE WITHOUT REVIEW/APPROVAL" warning.
- `sql/review/spray_configuration_full_tank_planning_validation.sql` requires a full current schema/custom-role restored clone with synthetic rows. It specifically refuses non-review databases.
- `docs/reviews/spray-planning-operational-integration-2026-10-15.md` records **NO-GO** for new-planning Save/Start and calls for freeze/admission/RPC consumers validation. The draft nullable columns/checks alone do NOT authorize new planning execution or verify persisted provenance.
- Therefore DO NOT widen v1's allowlist to admit new keys: server columns do not exist, and a widened RPC could not safely store all planning evidence.

## Ownership and next steps

**Rork/mobile** — continue preserving device-local held mixes with unsupported planning fields, without silently removing, reclassifying or remapping them; keep all old REST-uncertain attempts held. Rerun bounded iOS `KeyboardInteractionUITests` and `LegacySprayRecoveryUITests` and report individual results or exact runner failure; full UI run stopped after four visible passes and was not accepted. Existing native build/host evidence remains valid only for its exact tested source revision.

**Backend** — do *not* run draft planning DDL in production. Next complete a full schema+role clone acceptance: checked-in storage validation, historical preservation, RLS/column grants, trigger/freeze rules, existing RPC consumers, exact versioned planning admission, negative/fault/replay tests. Separate this from the narrower legacy-v1 paired-create receipt test. A genuine isolated test vineyard and separate authenticated users A/B are still required for v1 server integration. No production/customer test writes.

**Contract versioning** — keep `save_legacy_spray_pair_v1` and its receipt version 1 unchanged for ordinary no-route legacy saves. Evaluate *separate versioned planning storage/admission* if full-tank/over-row saves need new fields; adding a name to a list does not make persistence or operational admission correct. Backward compatibility and existing accepted receipt lookup must not be affected.

## Evidence and limitations

Source review:
- `docs/reviews/final-mobile-acceptance-legacy-save-recovery-2026-10-15.md` (Rork receipt-v1 closeout)
- `docs/reviews/spray-planning-operational-integration-2026-10-15.md` (planning NO-GO)
- `sql/review/spray_configuration_full_tank_planning_draft.sql` and `sql/review/spray_configuration_full_tank_planning_validation.sql`

Database checks: `information_schema.columns` for exact 14 names in both tables, `pg_proc`, role/table ACLs and RLS, private receipt ledger count, and project branch listing. All read-only.

No new schema migration, SQL data writes, project branch creation, customer mutation, device release or authenticated test assertion occurred during this audit.
