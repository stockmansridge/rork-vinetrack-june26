-- 199: Master Chemical Catalogue — Stage 1 (schema + server read foundation).
--
-- NUMBERING NOTE
--   The catalogue was drafted as "sql/197" in docs/master-chemical-catalogue-design.md
--   before sql/197 (spray block attribution security repair) and sql/198 (revision
--   concurrency) shipped. THIS migration is 199. Do not reuse 197/198.
--
-- WHAT THIS CREATES
--   * public.master_chemicals          — one row per country-scoped REGISTERED
--     product identity (e.g. AU:apvma:66541). A shared reference layer that
--     feeds lookups and re-verification. It is never the operator's record.
--   * public.master_chemical_versions — append-only history of every canonical
--     state a master row has ever had ("Saved Chemical was created from
--     revision 4; master is now revision 5").
--   * saved_chemicals.master_chemical_id / master_source_revision — OPTIONAL
--     provenance link from a vineyard's own record to the master product and
--     the revision its chemistry was copied at.
--   * A single seeded CANDIDATE row: the audited Custodia parity fixture.
--
-- TRUST MODEL (see docs/master-chemical-catalogue-design.md)
--   review_status: candidate -> approved -> retired.
--     candidate — enqueued from an AI lookup or drafted by an admin. NEVER
--                 served to app/portal lookup flows.
--     approved  — a human admin confirmed the row against the register/label.
--                 The ONLY state lookup flows may return as a master match.
--     retired   — registration lapsed/cancelled; kept for history.
--   `review_status` is the CATALOGUE lifecycle. It is deliberately a separate
--   column from `verification_status`, which is the sql/194 EVIDENCE state of
--   the chemistry data itself. Never conflate them.
--   A CHECK constraint makes ai_interpretation-sourced rows impossible to
--   approve: AI output alone can never become catalogue authority.
--
-- CHEMISTRY CONTRACT
--   The JSONB columns reuse the sql/194 wire shapes byte-for-byte
--   (docs/chemical-intelligence-json-contract.md §4): active_ingredients,
--   registered_uses, verification_sources, verification_conflicts. No second
--   chemistry format exists. As in sql/194, activity_groups has NO value CHECK
--   (the FRAC/HRAC/IRAC vocabulary grows annually).
--
-- VERSIONING
--   catalogue_version is a SERVER-MANAGED revision, independent of updated_at.
--   A BEFORE trigger bumps it exactly when canonical content changes and
--   ignores whatever version a client sends (no forgery, no accidental skips).
--   An AFTER trigger appends the full row image to master_chemical_versions.
--   Master corrections NEVER rewrite vineyard rows or spray snapshots; linked
--   vineyards see drift only through the Re-verify diff flow
--   (saved_chemicals.master_source_revision < master_chemicals.catalogue_version).
--
-- SEED STRATEGY (Stage 1 decision)
--   Exactly one row is seeded: Custodia 320 SC (AU:apvma:66541), the audited
--   cross-platform regression fixture (docs/chemical-custodia-parity-fixture.md).
--   It is seeded as a CANDIDATE, not approved, because the audit's own caveat
--   requires re-confirming registration currency in APVMA PubCRIS before any
--   approval — and candidates are invisible to every lookup flow, so shipping
--   this migration changes production lookup behaviour by exactly nothing
--   until an admin approves the row through Stage 2 review tooling.
--   Provenance is documented on the row itself (sources, review_notes).
--
-- SAFETY CONTRACT
--   * Purely ADDITIVE: no existing column dropped/renamed/retyped; the two new
--     saved_chemicals columns are nullable; old clients that never SELECT or
--     write them keep working unchanged (PostgREST PATCH/upsert payloads that
--     omit the columns leave them untouched).
--   * NO backfill of any kind. Existing saved_chemicals are NOT matched or
--     linked by name — linking happens only through the apps' identity-key
--     flows or explicit reviewed matching, never in bulk here.
--   * Historical spray snapshots (spray_records.tanks[].chemicalSnapshot) are
--     not read, not written, not referenced. They are a different artefact
--     with a different job and are never used as master history.
--   * Idempotent; single transaction.
--
-- RLS (sql/182 catalogue precedent)
--   * authenticated users read APPROVED rows only; system admins read all.
--   * writes (create/update/approve/retire) are system-admin only.
--   * version history is system-admin only (it can contain pre-publication
--     candidate states).
--   * The edge function's candidate enqueue uses the service role, which
--     bypasses RLS by design. No vineyard RLS is touched.

begin;

-- ---------------------------------------------------------------------------
-- 1. master_chemicals
-- ---------------------------------------------------------------------------

create table if not exists public.master_chemicals (
  id uuid primary key default gen_random_uuid(),

  -- Country-scoped registered identity — the ONLY identity that exists.
  -- Product name is never a uniqueness mechanism ("Custodia" vs "Custodia
  -- Forte"; AU "Custodia" vs UK "Custodia").
  registration_country text not null,
  registration_scheme  text not null,
  registration_number  text not null,
  registration_identity_key text generated always as (
    registration_country || ':' || registration_scheme || ':' || upper(btrim(registration_number))
  ) stored,
  registrant text,
  registered_product_name text not null,
  -- Lower-cased search aliases ONLY ("custodia"). Alias matching is exact
  -- whole-string equality — never substring — so "custodia" can never reach
  -- "Custodia Forte". Aliases never establish identity.
  common_names text[] not null default '{}',

  product_category text,
  form_type text,

  -- Chemistry: sql/194 wire shapes, byte-for-byte.
  active_ingredients jsonb not null default '[]'::jsonb,
  activity_groups text[] not null default '{}',
  activity_group_scheme text,
  registered_uses jsonb not null default '[]'::jsonb,
  label_rate_bases text[] not null default '{}',
  label_reference text,
  label_version text,

  -- sql/194 verification contract — the EVIDENCE state of the chemistry.
  -- Separate from review_status (the catalogue lifecycle) by design.
  verification_status text not null default 'unverified',
  verification_sources jsonb,
  verification_conflicts jsonb,
  verification_unresolved_fields text[],
  verified_at timestamptz,

  -- Provenance of the row itself.
  source_kind text not null default 'ai_interpretation',
  source_reference text,
  retrieved_at timestamptz,

  -- Catalogue lifecycle + review audit.
  review_status text not null default 'candidate',
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz,
  review_notes text,

  -- Server-managed revision (see triggers) + contract versions.
  catalogue_version integer not null default 1,
  activity_group_table_version integer,
  intelligence_schema_version integer not null default 1,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint master_chemicals_identity_unique unique (registration_identity_key),
  constraint master_chemicals_country_check
    check (registration_country ~ '^[A-Z]{2}$'),
  constraint master_chemicals_number_check
    check (btrim(registration_number) <> ''),
  constraint master_chemicals_name_check
    check (btrim(registered_product_name) <> ''),
  constraint master_chemicals_registration_scheme_check
    check (registration_scheme in ('apvma','acvm','nz_epa','other')),
  constraint master_chemicals_activity_group_scheme_check
    check (activity_group_scheme is null or activity_group_scheme in
      ('frac','hrac','irac','not_applicable')),
  constraint master_chemicals_verification_status_check
    check (verification_status in
      ('verified','partially_verified','unverified','needs_match','conflict')),
  constraint master_chemicals_review_status_check
    check (review_status in ('candidate','approved','retired')),
  constraint master_chemicals_source_kind_check
    check (source_kind in ('official_register','manufacturer_label',
      'authoritative_classification','viticulture_reference',
      'ai_interpretation','manual_entry','legacy_record')),
  constraint master_chemicals_catalogue_version_check
    check (catalogue_version >= 1),
  -- THE approval gate: register/label provenance or it cannot be approved.
  constraint master_chemicals_approved_provenance_check
    check (review_status <> 'approved'
           or source_kind in ('official_register','manufacturer_label'))
);

comment on table public.master_chemicals is
  'Master Chemical Catalogue (sql/199). One row per country-scoped registered product '
  'identity (registration_identity_key, e.g. AU:apvma:66541). Only review_status=approved '
  'rows are served to lookup flows; candidates come from AI lookups or admin drafts and '
  'must be human-reviewed against the register/label before approval. catalogue_version '
  'is server-managed; history is append-only in master_chemical_versions.';
comment on column public.master_chemicals.review_status is
  'Catalogue lifecycle: candidate | approved | retired. NOT the same thing as '
  'verification_status (sql/194 evidence state of the chemistry data).';
comment on column public.master_chemicals.catalogue_version is
  'Server-managed revision. Bumped by trigger exactly when canonical content changes; '
  'client-supplied values are ignored. saved_chemicals.master_source_revision records '
  'which revision a vineyard record copied.';
comment on column public.master_chemicals.common_names is
  'Lower-cased exact-match search aliases only. Never identity, never fuzzy.';

-- ---------------------------------------------------------------------------
-- 2. master_chemical_versions — append-only history
-- ---------------------------------------------------------------------------

create table if not exists public.master_chemical_versions (
  id uuid primary key default gen_random_uuid(),
  master_chemical_id uuid not null references public.master_chemicals(id) on delete cascade,
  catalogue_version integer not null,
  -- Full row image at that version (to_jsonb of the row), so "what changed",
  -- "which label version", "when did registration data change" are all
  -- answerable later without guessing.
  snapshot jsonb not null,
  changed_by uuid references auth.users(id),
  changed_at timestamptz not null default now(),
  change_reason text,
  constraint master_chemical_versions_unique unique (master_chemical_id, catalogue_version)
);

comment on table public.master_chemical_versions is
  'Append-only canonical-state history for master_chemicals (sql/199). Trigger-written; '
  'never updated in place. NOT the same artefact as spray-line chemicalSnapshots, which '
  'freeze what was applied and are never consulted here.';

-- ---------------------------------------------------------------------------
-- 3. Server-managed revision + history triggers
-- ---------------------------------------------------------------------------

-- BEFORE trigger: owns id/created_at immutability, updated_at, and the
-- revision. The version a client sends is ALWAYS ignored — on insert it is 1,
-- on update it is OLD (no content change) or OLD+1 (content change).
create or replace function public.master_chemicals_before_write()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'INSERT' then
    new.catalogue_version := 1;
    new.created_at := now();
    new.updated_at := now();
    return new;
  end if;

  -- UPDATE
  new.id := old.id;
  new.created_at := old.created_at;
  new.updated_at := now();

  if (new.registration_country,          new.registration_scheme,
      new.registration_number,           new.registrant,
      new.registered_product_name,       new.product_category,
      new.form_type,                     new.active_ingredients,
      new.activity_groups,               new.activity_group_scheme,
      new.registered_uses,               new.label_rate_bases,
      new.label_reference,               new.label_version,
      new.verification_status,           new.verification_sources,
      new.verification_conflicts,        new.verification_unresolved_fields,
      new.verified_at,                   new.activity_group_table_version,
      new.intelligence_schema_version)
     is distinct from
     (old.registration_country,          old.registration_scheme,
      old.registration_number,           old.registrant,
      old.registered_product_name,       old.product_category,
      old.form_type,                     old.active_ingredients,
      old.activity_groups,               old.activity_group_scheme,
      old.registered_uses,               old.label_rate_bases,
      old.label_reference,               old.label_version,
      old.verification_status,           old.verification_sources,
      old.verification_conflicts,        old.verification_unresolved_fields,
      old.verified_at,                   old.activity_group_table_version,
      old.intelligence_schema_version)
  then
    new.catalogue_version := old.catalogue_version + 1;
  else
    -- Review/lifecycle/alias-only changes (approve, retire, notes,
    -- common_names) do not restate content, so they do not bump the revision
    -- linked vineyards compare against.
    new.catalogue_version := old.catalogue_version;
  end if;
  return new;
end$$;

-- AFTER trigger: appends the row image whenever a NEW revision exists.
-- SECURITY DEFINER (search_path pinned) so an authenticated admin's update can
-- write the RLS-protected history table — the sql/197/198 lesson: a guard that
-- silently fails to record is worse than no guard.
create or replace function public.master_chemicals_record_version()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' or new.catalogue_version <> old.catalogue_version then
    insert into public.master_chemical_versions
      (master_chemical_id, catalogue_version, snapshot, changed_by, change_reason)
    values
      (new.id, new.catalogue_version, to_jsonb(new), auth.uid(),
       nullif(current_setting('vinetrack.master_change_reason', true), ''));
  end if;
  return new;
end$$;

drop trigger if exists t10_master_before_write on public.master_chemicals;
create trigger t10_master_before_write
before insert or update on public.master_chemicals
for each row execute function public.master_chemicals_before_write();

drop trigger if exists t20_master_record_version on public.master_chemicals;
create trigger t20_master_record_version
after insert or update on public.master_chemicals
for each row execute function public.master_chemicals_record_version();

-- ---------------------------------------------------------------------------
-- 4. saved_chemicals — additive provenance link
-- ---------------------------------------------------------------------------
-- No cascade and no SET NULL: a master row referenced by any vineyard record
-- cannot be hard-deleted (retire it instead), and a vineyard record never
-- loses its provenance silently.

alter table public.saved_chemicals
  add column if not exists master_chemical_id uuid references public.master_chemicals(id),
  add column if not exists master_source_revision integer;

do $$
begin
  alter table public.saved_chemicals
    add constraint saved_chemicals_master_source_revision_check
    check (master_source_revision is null or master_source_revision >= 1);
exception
  when duplicate_object then null;
end $$;

comment on column public.saved_chemicals.master_chemical_id is
  'Optional link to the master catalogue product this record was derived from (sql/199). '
  'Set only by identity-exact flows; NEVER backfilled by name similarity. Null is valid '
  'forever — an unlinked chemical keeps working exactly as before.';
comment on column public.saved_chemicals.master_source_revision is
  'master_chemicals.catalogue_version at the moment the structured chemistry was copied. '
  'master.catalogue_version > this  =>  "Updated verified information available" via the '
  'Re-verify diff flow. Master updates never rewrite the vineyard row.';

-- ---------------------------------------------------------------------------
-- 5. Indexes
-- ---------------------------------------------------------------------------

create index if not exists idx_master_chemicals_country_name
  on public.master_chemicals (registration_country, lower(registered_product_name));
create index if not exists idx_master_chemicals_common_names
  on public.master_chemicals using gin (common_names);
create index if not exists idx_master_chemicals_groups
  on public.master_chemicals using gin (activity_groups);
create index if not exists idx_master_chemicals_review
  on public.master_chemicals (review_status);
create index if not exists idx_saved_chemicals_master_chemical
  on public.saved_chemicals (master_chemical_id)
  where master_chemical_id is not null;

-- ---------------------------------------------------------------------------
-- 6. RLS
-- ---------------------------------------------------------------------------

alter table public.master_chemicals         enable row level security;
alter table public.master_chemical_versions enable row level security;

-- Reads: approved rows for everyone signed in; everything for system admins.
-- Candidates are structurally invisible to normal lookup paths (¶ candidate
-- isolation) — no client filter needed or trusted.
drop policy if exists master_chemicals_read on public.master_chemicals;
create policy master_chemicals_read
  on public.master_chemicals for select to authenticated
  using (review_status = 'approved' or public.is_system_admin());

-- Writes: system admins only. Vineyard users can never alter canonical
-- master data. (The edge function's candidate enqueue is service-role.)
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

grant select, insert, update, delete on public.master_chemicals to authenticated;
grant select, insert, update, delete on public.master_chemical_versions to authenticated;
grant all on public.master_chemicals to service_role;
grant all on public.master_chemical_versions to service_role;

-- ---------------------------------------------------------------------------
-- 7. Seed — the audited Custodia parity fixture, as a CANDIDATE
-- ---------------------------------------------------------------------------
-- Values are the authoritative audit resolution of 2026-08-18
-- (docs/chemical-custodia-parity-fixture.md §1): AWRI registration update
-- (Sept 2012) + APVMA label mirror (agrobaseapp AU) + Adama Australia
-- literature. NOT taken from any earlier portal test value (the old synthetic
-- "62764" fixture is unrelated and must not reappear here).
--
-- Deliberately NOT approved: the fixture's own currency caveat requires
-- re-confirming the registration in APVMA PubCRIS before approval. An admin
-- approves it in Stage 2 review; until then no lookup can return it.

insert into public.master_chemicals (
  id,
  registration_country, registration_scheme, registration_number,
  registrant, registered_product_name, common_names,
  product_category, form_type,
  active_ingredients, activity_groups, activity_group_scheme,
  registered_uses, label_rate_bases,
  verification_status, verification_sources, verification_conflicts,
  verification_unresolved_fields, verified_at,
  source_kind, source_reference, retrieved_at,
  review_status, review_notes,
  activity_group_table_version, intelligence_schema_version
) values (
  'c0570d1a-2026-4a66-9541-a99f66541001',
  'AU', 'apvma', '66541',
  'Adama Australia Pty Ltd', 'Custodia 320 SC',
  array['custodia', 'custodia 320 sc'],
  'fungicide', 'liquid',
  '[
    {"name":"Azoxystrobin","concentration":120,"concentration_unit":"g/L",
     "activity_group":{"scheme":"frac","code":"11","common_name":"QoI / Strobilurin"},
     "group_source":"authoritative_classification","identity_source":"manufacturer_label"},
    {"name":"Tebuconazole","concentration":200,"concentration_unit":"g/L",
     "activity_group":{"scheme":"frac","code":"3","common_name":"DMI / Triazole"},
     "group_source":"authoritative_classification","identity_source":"manufacturer_label"}
  ]'::jsonb,
  array['3','11'], 'frac',
  '[
    {"crop":"Grapevines","target":"powdery_mildew","target_raw":"Powdery mildew",
     "rates":[
       {"label":"Dilute spraying","basis":"per_100_litres","value":65,"unit":"mL"},
       {"label":"Concentrate spraying","basis":"per_hectare","value":1,"unit":"L"}],
     "withholding_period_days":28,
     "restrictions":"Protectant only. DO NOT apply more than 2 sprays per season. Export grapes: do not use later than 80% capfall. Do not re-enter treated areas until the spray has dried."},
    {"crop":"Wheat","target_raw":"Stripe rust",
     "rates":[
       {"label":"Standard","basis":"range_per_hectare","min_value":315,"max_value":630,"unit":"mL"}],
     "withholding_period_days":42,
     "restrictions":"Harvest WHP 6 weeks. Grazing WHP 21 days."}
  ]'::jsonb,
  array['per_100_litres','per_hectare','range_per_hectare'],
  'partially_verified',
  '[
    {"kind":"manufacturer_label","name":"APVMA label — Custodia 320 SC (mirror via agrobaseapp AU)","reference":null,"retrieved_at":"2026-08-18T00:00:00Z"},
    {"kind":"viticulture_reference","name":"AWRI Agrochemicals registered for use in Australian viticulture — registration update (Sept 2012)","reference":null,"retrieved_at":"2026-08-18T00:00:00Z"},
    {"kind":"authoritative_classification","name":"VineTrack activity group reference v1 (FRAC/HRAC/IRAC)","reference":null,"retrieved_at":"2026-08-18T00:00:00Z"}
  ]'::jsonb,
  '[]'::jsonb,
  array['label_reference','label_version','re_entry_period_hours'],
  null,
  'manufacturer_label',
  'Audited cross-platform parity fixture (docs/chemical-custodia-parity-fixture.md). Sibling registrations that must NEVER merge with this identity: Custodia Forte AU:apvma:91636 (222/370 g/L); UK Custodia MAPP 16393 (GB:other:16393).',
  '2026-08-18T00:00:00Z',
  'candidate',
  'Seeded by sql/199 from the audited fixture. Approval WITHHELD by design: re-confirm registration currency in APVMA PubCRIS (Adama''s current AU grape offering is Custodia Forte; the original registration may lapse at a renewal cycle), then approve via Stage 2 admin review. Candidates are never served to lookups.',
  1, 1
)
on conflict on constraint master_chemicals_identity_unique do nothing;

commit;
