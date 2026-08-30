-- 215 — Durable, SEPARATE persistence for the three chemical link concepts.
--
-- ADDITIVE ONLY. No column is dropped, renamed, retyped or repurposed, and no
-- stored value is rewritten. Running this twice is a no-op.
--
-- ---------------------------------------------------------------------------
-- The problem
-- ---------------------------------------------------------------------------
--
-- A registered product has THREE genuinely different documents, and conflating
-- any two of them is a safety problem rather than a cosmetic one:
--
--   1. the REGULATOR's approved label (APVMA eLabels and equivalents) — the
--      legally approved label, authoritative for registration;
--   2. the MANUFACTURER-hosted label — the same label as the registrant
--      publishes it, usually the more readable rendering and the one a grower
--      physically holds;
--   3. the manufacturer's PRODUCT INFORMATION page — marketing material, which
--      is NOT a label and must never be presented as one.
--
-- The resolver already discovers and classifies all three, and the wire
-- contract already carries all three (`label_reference`,
-- `manufacturer_label_url`, `manufacturer_product_url`). Storage did not: only
-- `label_reference` existed. So a manufacturer label that had been found and
-- validated was carried to the device, shown once, and then silently dropped
-- the moment the grower opened and saved the chemical — and the only place it
-- could have been kept was the regulator's field, where it would have started
-- claiming to be the approved label.
--
-- ---------------------------------------------------------------------------
-- What this does
-- ---------------------------------------------------------------------------
--
-- Gives each concept its own column on both tables that serve chemical
-- identity, so the three can never collapse into one another:
--
--   * `label_reference`         — UNCHANGED in meaning: the regulator/approved
--                                 label. Existing rows keep exactly what they
--                                 have. Nothing is migrated INTO or OUT OF it.
--   * `manufacturer_label_url`  — new. The registrant-hosted label document.
--   * `manufacturer_product_url`— new. The registrant's product page. Marketing
--                                 only; never a label, never a rate source.
--
-- Deliberately NOT done here:
--   * no backfill — a URL nobody has validated is not evidence, and guessing
--     which of the three an existing `label_reference` really was would invent
--     provenance the record never had;
--   * no repurposing of `label_reference` — the regulator's field means what it
--     has always meant, forever;
--   * no `regulator_label_url` column — `label_reference` IS that field. Adding
--     a synonym would create two places to store one fact and guarantee they
--     eventually disagree. The wire may carry both names; storage keeps one.

begin;

-- ---------------------------------------------------------------------------
-- saved_chemicals — a vineyard's own chemical records
-- ---------------------------------------------------------------------------

alter table public.saved_chemicals
  -- The registrant-hosted label document. Separate from `label_reference` on
  -- purpose: a manufacturer rendering may LEAD in the UI but can never
  -- substitute for the approved label behind it.
  add column if not exists manufacturer_label_url text,
  -- The registrant's product information page. Marketing, not a label. Kept so
  -- a grower can read about a product without the app ever implying that a
  -- brochure is something to spray by.
  add column if not exists manufacturer_product_url text;

comment on column public.saved_chemicals.label_reference is
  'The REGULATOR''s approved label (APVMA eLabels and equivalents). '
  'Authoritative for registration. Never overwritten with a manufacturer '
  'document or a product page — see manufacturer_label_url / '
  'manufacturer_product_url.';

comment on column public.saved_chemicals.manufacturer_label_url is
  'The registrant/manufacturer-hosted LABEL document. A separate concept from '
  'label_reference (the approved regulator label) and from '
  'manufacturer_product_url (marketing). May lead in the UI; never substitutes '
  'for the approved label.';

comment on column public.saved_chemicals.manufacturer_product_url is
  'The registrant''s PRODUCT INFORMATION page. Marketing material only — never '
  'a label, never a source of rates, and never presented as either.';

-- ---------------------------------------------------------------------------
-- master_chemicals — the shared catalogue an approved row is served from
-- ---------------------------------------------------------------------------
--
-- Without these the catalogue could not RETAIN what the resolver found: an
-- approved master row served its consumers a regulator label and nothing else,
-- so every product served from the catalogue lost the manufacturer documents
-- even when they had been discovered and validated.

alter table public.master_chemicals
  add column if not exists manufacturer_label_url text,
  add column if not exists manufacturer_product_url text;

comment on column public.master_chemicals.manufacturer_label_url is
  'The registrant/manufacturer-hosted LABEL document for this registration. '
  'Separate from label_reference (approved regulator label) forever.';

comment on column public.master_chemicals.manufacturer_product_url is
  'The registrant''s PRODUCT INFORMATION page for this registration. Marketing '
  'material only — never a label.';

commit;

-- ---------------------------------------------------------------------------
-- Verification (safe to run on production; reads only)
-- ---------------------------------------------------------------------------
--
--   select table_name, column_name
--     from information_schema.columns
--    where table_schema = 'public'
--      and table_name in ('saved_chemicals','master_chemicals')
--      and column_name in ('label_reference',
--                          'manufacturer_label_url',
--                          'manufacturer_product_url')
--    order by table_name, column_name;
--
-- Expect six rows: all three columns present on both tables. Existing
-- label_reference values are untouched, and the two new columns are null
-- everywhere until a resolver pass populates them.
