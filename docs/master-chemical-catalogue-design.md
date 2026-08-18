# Master Chemical Catalogue — design (PROPOSED, not applied)

**Status:** Design document produced by the Chemical Lookup Parity audit (2026-08-18).
**No database changes have been applied.** The SQL in section 6 is the exact proposed
scope for a future migration (`sql/197_master_chemical_catalogue.sql`) and must be
reviewed before it is created. The web portal (Lovable) must NOT invent its own
catalogue schema — this document is the authority for the shared design.

---

## 1. What exists today (audit finding)

| Layer | Exists? | Role |
|---|---|---|
| `public.saved_chemicals` | Yes | Per-vineyard operational store. sql/194 added structured intelligence columns (actives, groups, registration, uses, verification). This is the ONLY product store today. |
| `chemical_lookup_cache` | **No — does not exist** | Referenced in portal-side conversation only. There is no lookup cache table anywhere in `sql/`, the apps, or the edge functions. Every lookup is a live AI call. |
| Master catalogue | **No — does not exist** | Nothing global holds registered products. |
| `AuthoritativeActivityGroups` | Yes (×3: iOS, Android, edge function, all v1) | Active-ingredient → FRAC/HRAC/IRAC reference. Authoritative for the GROUP only — it has no product identity, no rates, no registration numbers. |
| `spray_records.tanks[].chemicalSnapshot` | Yes | Frozen per-spray chemistry. Historical evidence; never re-read from current rows. |
| Global catalogue precedent | Yes | sql/182 `grape_clone_catalog` / `rootstock_catalog`: authenticated read, `public.is_system_admin()` write. The same RLS pattern applies here. |

Consequences of not having a master catalogue:

- The same registered product is re-extracted by AI once per vineyard, at AI cost
  and AI variance.
- Nothing accumulates verified knowledge: an operator verifying "Custodia,
  APVMA 66541" in one vineyard teaches the system nothing for the next vineyard.
- There is no admin surface to QA what the AI has been telling growers.

## 2. Recommendation

**Create `public.master_chemicals` (with an append-only version history).** One row
per country-scoped registered product identity. It is a shared reference layer that
feeds lookups and re-verification; it is never the operator's record — the vineyard's
`saved_chemicals` row stays the editable, owned object, exactly as today.

## 3. Identity — the stable key

The natural key is the **registration identity key** the apps already compute and
freeze into spray snapshots:

```
{ISO-2 COUNTRY}:{scheme}:{REGISTRATION NUMBER uppercased}   e.g.  AU:apvma:66541
```

- Country is part of the key: AU "Custodia" (APVMA 66541) and UK "Custodia"
  (MAPP 16393) are different products with different labels.
- Brand names are aliases for SEARCH only (`common_names[]`), never identity.
  "Custodia" vs "Custodia Forte" (APVMA 91636) is the canonical counter-example.
- Products with no registration number cannot enter the catalogue. An
  unregistered biostimulant stays a per-vineyard record — the catalogue must
  never hold unprovable identities.

## 4. Trust model

- `review_status`: `candidate` → `approved` → `retired`.
  - **candidate** — enqueued from an AI lookup or an admin draft. NEVER served to
    apps or portal lookup flows.
  - **approved** — a human admin confirmed the row against the register/label;
    provenance columns say what was consulted. Served to all lookup flows.
  - **retired** — registration lapsed/cancelled (e.g. at an APVMA renewal cycle).
    Kept for history; re-verify surfaces "the register has moved on".
- `source_kind` reuses the contract's DataSourceKind vocabulary. An approved row
  should carry `official_register` or `manufacturer_label`; approval must be
  blocked while the only provenance is `ai_interpretation`.
- Applying an approved master row in the apps supplies genuinely authoritative
  sources, so the existing evidence gate (`resolvedVerificationStatus`) can reach
  `verified` after the operator's confirm step — with zero changes to the gate
  itself. AI-only candidates keep today's `partially_verified` ceiling.
- A master correction NEVER rewrites vineyard rows or spray history. Linked
  vineyards see it only through Re-verify's diff-and-accept flow.

## 5. Lookup priority (apps and portal, identical)

1. **Master catalogue (approved, country-scoped).** By identity key when the
   record holds one; otherwise exact-name/alias search that lists candidates —
   never fuzzy auto-apply.
2. **AI lookup** (`chemical-info-lookup`, unchanged honesty rules). The edge
   function should consult the master table first server-side and return
   register-backed data when a hit exists; on a miss it extracts via AI as
   today AND enqueues a `candidate` master row (deduplicated on identity key,
   service-role write) so the catalogue grows from real demand without
   laundering AI output into authority.
3. **Manual entry** (unchanged; stays Unverified).

Re-verify follows the same ladder: master first (deterministic, free), AI second.
`label_version` / `catalogue_version` drift is what powers an honest "label has
changed" prompt.

Offline: approved rows for the vineyard's country are a small dataset (hundreds).
Apps may sync them with an `updated_at` cursor for offline lookup in a later stage.

## 6. Proposed migration scope (`sql/197_master_chemical_catalogue.sql` — DRAFT, DO NOT APPLY without review)

Purely additive. JSONB columns reuse the sql/194 wire shapes byte-for-byte
(`docs/chemical-intelligence-json-contract.md` §4) so all existing encoders/decoders
work unchanged.

```sql
begin;

create table if not exists public.master_chemicals (
  id uuid primary key default gen_random_uuid(),

  -- Country-scoped registered identity (the only identity that exists).
  registration_country text not null,
  registration_scheme  text not null,
  registration_number  text not null,
  registration_identity_key text generated always as (
    registration_country || ':' || registration_scheme || ':' || upper(registration_number)
  ) stored,
  registrant text,
  registered_product_name text not null,
  common_names text[] not null default '{}',   -- search aliases only, never identity

  product_category text,
  form_type text,

  -- Same JSONB shapes as saved_chemicals (contract §4.1 / §4.5).
  active_ingredients jsonb not null default '[]'::jsonb,
  activity_groups text[] not null default '{}',
  activity_group_scheme text,
  registered_uses jsonb not null default '[]'::jsonb,
  label_rate_bases text[] not null default '{}',
  label_reference text,
  label_version text,

  -- Provenance and review.
  source_kind text not null default 'ai_interpretation',
  source_reference text,
  retrieved_at timestamptz,
  review_status text not null default 'candidate',
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz,
  review_notes text,

  -- Versioning.
  catalogue_version integer not null default 1,
  activity_group_table_version integer,
  intelligence_schema_version integer not null default 1,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint master_chemicals_identity_unique unique (registration_identity_key),
  constraint master_chemicals_registration_scheme_check
    check (registration_scheme in ('apvma','acvm','nz_epa','other')),
  constraint master_chemicals_activity_group_scheme_check
    check (activity_group_scheme is null or activity_group_scheme in
      ('frac','hrac','irac','not_applicable')),
  constraint master_chemicals_review_status_check
    check (review_status in ('candidate','approved','retired')),
  constraint master_chemicals_source_kind_check
    check (source_kind in ('official_register','manufacturer_label',
      'authoritative_classification','viticulture_reference',
      'ai_interpretation','manual_entry','legacy_record')),
  -- Approval requires register/label provenance — AI output cannot be approved.
  constraint master_chemicals_approved_provenance_check
    check (review_status <> 'approved'
           or source_kind in ('official_register','manufacturer_label'))
);
-- NOTE: deliberately NO CHECK on activity_groups values (same reasoning as sql/194).

create table if not exists public.master_chemical_versions (
  id uuid primary key default gen_random_uuid(),
  master_chemical_id uuid not null references public.master_chemicals(id) on delete cascade,
  catalogue_version integer not null,
  snapshot jsonb not null,                    -- full row image at that version
  changed_by uuid references auth.users(id),
  changed_at timestamptz not null default now(),
  change_reason text,
  constraint master_chemical_versions_unique unique (master_chemical_id, catalogue_version)
);

-- Additive link from the vineyard store to the catalogue (provenance only).
alter table public.saved_chemicals
  add column if not exists master_chemical_id uuid references public.master_chemicals(id);

create index if not exists idx_saved_chemicals_master_chemical
  on public.saved_chemicals (master_chemical_id) where master_chemical_id is not null;
create index if not exists idx_master_chemicals_country_name
  on public.master_chemicals (registration_country, lower(registered_product_name));
create index if not exists idx_master_chemicals_groups
  on public.master_chemicals using gin (activity_groups);
create index if not exists idx_master_chemicals_review
  on public.master_chemicals (review_status);

-- RLS: global reference data — sql/182 catalogue pattern.
alter table public.master_chemicals          enable row level security;
alter table public.master_chemical_versions  enable row level security;

drop policy if exists master_chemicals_read on public.master_chemicals;
create policy master_chemicals_read
  on public.master_chemicals for select to authenticated
  using (review_status = 'approved' or public.is_system_admin());

drop policy if exists master_chemicals_admin_write on public.master_chemicals;
create policy master_chemicals_admin_write
  on public.master_chemicals for all to authenticated
  using (public.is_system_admin()) with check (public.is_system_admin());

drop policy if exists master_chemical_versions_read on public.master_chemical_versions;
create policy master_chemical_versions_read
  on public.master_chemical_versions for select to authenticated
  using (public.is_system_admin());

drop policy if exists master_chemical_versions_admin_write on public.master_chemical_versions;
create policy master_chemical_versions_admin_write
  on public.master_chemical_versions for all to authenticated
  using (public.is_system_admin()) with check (public.is_system_admin());

commit;
```

Candidate enqueueing from the edge function uses the service role (bypasses RLS);
apps and portal users never write the catalogue directly in stage 1.

## 7. Migration & backfill strategy

- **No automatic backfill.** Existing `saved_chemicals` rows are NOT converted
  into master rows — an unreviewed vineyard record is not register evidence.
- Optional, admin-driven seeding: group existing rows by
  `registration_country/scheme/number` where a number exists, propose each
  distinct identity as a `candidate`, and approve only after checking the
  register. The Custodia parity fixture (`docs/chemical-custodia-parity-fixture.md`,
  AU:apvma:66541) is the natural first seed — approve only after re-confirming
  currency in APVMA PubCRIS.
- Linking existing vineyard rows to master rows happens only through the
  existing Match & Verify / Re-verify flows (identity-key equality), never by
  name similarity, and never in bulk without review.
- Nothing above changes any existing flow: every column is additive, apps that
  ignore `master_chemical_id` keep working, snapshots are untouched.

## 8. Staged implementation (proposed)

1. **Stage 1 — schema + server read.** Apply the migration; edge function
   consults `master_chemicals` (approved) before AI and enqueues candidates on
   miss. Apps unchanged.
2. **Stage 2 — admin review.** Portal admin screen: candidate queue, diff
   against register/label, approve / retire, version history.
3. **Stage 3 — app integration.** Lookup priority in Match & Verify, populate
   `master_chemical_id` on apply, `verified` promotion via approved-row
   provenance.
4. **Stage 4 — re-verify + offline.** Re-verify against the catalogue first;
   country-scoped offline cache with `updated_at` cursor.

Each stage is independently shippable and reversible; no stage rewrites data.
