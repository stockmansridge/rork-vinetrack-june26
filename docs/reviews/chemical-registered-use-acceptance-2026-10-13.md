# Registered-use acceptance: Crop Sil, REVUS, DiPel DF (read-only)

**13 October 2026.** Backend review note supporting the separate mobile-chemical acceptance tests at commit `5f13e2ff200133634daa58af1d3b3c20063b5cbb`. This is **not** an application-label approval, a production data correction or an acceptance of the Full Tank/Over-Row server release.

## Verified from live `public.saved_chemicals` metadata (read-only)

- **Crop Sil** is stored with inventory/product unit `Litres`. Its registered rate units include `L/ha` and `mL/100 L water`. Active ingredient concentration strings include `%` and `% (±1%)`; neither identifies w/w, w/v or v/v by itself. Application-rate units are dimensionally compatible, but the active-ingredient concentration basis **must remain unresolved** until authoritative evidence is reviewed.
- **DiPel® DF** is stored with product unit `Litres`, while its registered-use rates are written in `kg/ha`, `g/100 L` and `g/100L`. This is a genuine mass/volume mismatch. Its general `verification_status` is `verified`, demonstrating that general product verification does **not** prove dosing compatibility. No implicit density or product-unit conversion is permitted. Mobile calculated application remains blocked for this product until a separately reviewed canonical product/inventory unit correction and all affected dependencies are addressed. Preserve saved evidence and historical snapshots.
- **REVUS Fungicide**: an identity with verification status `verified` carries `mL/100 L` registered rates; other similarly named Saved Chemical records exist. Application must be linked by exact Saved Chemical identity and selected rate/condition, not product-name matching. The mobile fixture tests cover distinct 40 and 60 mL/100 L options and deliberate choice; this DB review does not certify a label or permission to concentrate spray.

No customer IDs, product full rows, authentication records, invoices, permissions or secrets were exported. No production writes, DDL or grants were performed.

## Mobile implementation/acceptance handoff

Per Rork's checkpoint: iOS chemical-focused acceptance 17 passed, Android host 28 passed and mocked persistence 2 passed, both platform builds passed. Seven expanded iOS unit/scoping failures remain **unclassified**, and mobile OS-process restart, authenticated UI/device testing and genuine server replay are not proven. These numbers are distinct from the Full Tank/Over-Row planning tests.

Immediate mobile tasks:
1. Give exact names/assertions of seven failing iOS tests, reproduce/categorise genuine regressions vs existing fixture issues, and fix only evidenced faults; keep chemical registered-use content and existing dosing engines unchanged.
2. Verify visual display of full conditions on both devices when possible, including REVUS explicit selection and DiPel product-unit block.
3. Keep unit review warnings informative; do **not** auto-select competing fixed rates, infer active concentration basis from `%`, or convert DiPel mass directions through stored `Litres`.
4. Preserve exact frozen selected registered rate/use/condition across local cache, edit and offline replay. Device process-restart and live-server acknowledgment-loss replay remain open.

## Backend responsibility and release distinction

- Backend owner reviews official product/registration/jurisdiction evidence and the impact on saved product units, inventory, costing and completed historical records **before proposing any DiPel data correction**. Never automatically rewrite historical spray records.
- Do not treat the Chemical Store `verified` field as concentrate permission. Planned authoritative server admission is a **separate project** described in `docs/spray-server-compliance-proposal.md`, and remains unimplemented.
- No production data corrections or SQL migration are approved by this note. Full Tank/Over-Row SQL v2 and server-gate staging, replay and trip/tank acceptance remain blocked pending validated isolated staging.

**Status: read-only audit and review note only.**
