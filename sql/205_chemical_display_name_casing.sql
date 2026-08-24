-- =============================================================================
-- 205: Chemical product names are stored in readable case, not SHOUTED.
--
-- Rork/VineTrack mobile is the SOURCE OF TRUTH for this contract. Lovable (the
-- web portal) and Android CONSUME it and MUST NOT independently create or
-- modify these objects.
--
-- ---------------------------------------------------------------------------
-- WHY
-- ---------------------------------------------------------------------------
-- The APVMA public register stores product names in capitals — "DITHANE
-- RAINSHIELD NEO TEC FUNGICIDE" — and that verbatim wording is what the
-- chemical lookup pipeline carries through as authoritative identity. Every
-- product that arrives from the register therefore lands in the operator's
-- Chemical Store shouting, and shows up shouting in the Spray Calculator, the
-- Program, the tank mix and every list that names a product.
--
-- Casing is presentation, not evidence: "Dithane Rainshield Neo Tec Fungicide"
-- and the register's capitals are the SAME product name. Fixing it in each
-- view would mean re-implementing the same rule in iOS, Android and the
-- portal, and three implementations would drift. It belongs here — one rule,
-- applied to what is stored, so every client that reads the row reads the same
-- readable name without doing anything.
--
-- ---------------------------------------------------------------------------
-- WHAT THIS MIGRATION DOES
-- ---------------------------------------------------------------------------
--   1. `public.vt_display_chemical_name(text)` — the one casing rule.
--   2. A BEFORE INSERT/UPDATE trigger on `saved_chemicals` so every future
--      write from any client is stored cased, without the client knowing.
--   3. A one-off backfill of existing live `saved_chemicals` rows.
--
-- ---------------------------------------------------------------------------
-- WHAT THIS MIGRATION DELIBERATELY DOES NOT TOUCH
-- ---------------------------------------------------------------------------
-- * `master_chemicals.registered_product_name` — the verbatim register name.
--   That column is EVIDENCE and an identity/matching key (sql/199 indexes
--   `lower(registered_product_name)`, the resolver matches it with `ilike`).
--   It stays byte-identical to the register. This migration changes what a
--   vineyard's own record is CALLED, never what the authority said.
-- * `spray_records` — historical spray snapshots are frozen evidence of what
--   was applied and are never rewritten, not even cosmetically.
-- * Any other column. `manufacturer` in particular is left alone: registrant
--   names are full of genuine acronyms (BASF, UPL, FMC, ADAMA) that this rule
--   would wrongly turn into words.
--
-- ---------------------------------------------------------------------------
-- THE RULE
-- ---------------------------------------------------------------------------
-- A name that already contains ANY lower-case letter is returned untouched.
-- That single guard is what makes this safe: it only ever rewrites a name that
-- is entirely capitals, so a name an operator deliberately typed, or a
-- manufacturer's own mixed-case styling ("Kocide Blue Xtra"), can never be
-- re-cased by this function.
--
-- Within a shouted name, each word becomes Capitalised except where capitals
-- carry meaning:
--   * anything containing a digit is kept verbatim  -> 500SC, 750DF, 2,4
--   * single characters are kept                    -> the D of 2,4-D
--   * words with no vowel are kept                  -> WG, SC, EC, MZ, XL, NT
--   * a short list of vowel-carrying formulation and
--     active codes is kept                          -> ULV, RTU, MCPA, OD
-- Hyphenated words are cased part by part; the hyphen is preserved.
--
--   'DITHANE RAINSHIELD NEO TEC FUNGICIDE' -> 'Dithane Rainshield Neo Tec Fungicide'
--   'TOPAS 100 EC'                         -> 'Topas 100 EC'
--   'PENNCOZEB 750DF'                      -> 'Penncozeb 750DF'
--   'Kocide Blue Xtra'                     -> 'Kocide Blue Xtra'   (untouched)
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. The casing rule
-- ---------------------------------------------------------------------------
-- IMMUTABLE: same input always gives the same output, so it is safe in an
-- index or a generated column later if that is ever wanted.
create or replace function public.vt_display_chemical_name(raw text)
returns text
language plpgsql
immutable
as $$
declare
  -- Vowel-carrying tokens that are codes, not words. Everything without a
  -- vowel is already handled by the general rule below, so this list only
  -- needs the exceptions to it.
  keep_upper constant text[] := array[
    'ULV', 'RTU', 'ME', 'EW', 'OD', 'GR', 'UL', 'EG', 'SE', 'ZC', 'AF',
    'MCPA', 'NPK', 'IPM', 'II', 'III'
  ];
  token       text;
  part        text;
  cased       text;
  out_tokens  text[] := '{}';
  out_parts   text[];
begin
  if raw is null then
    return null;
  end if;
  if btrim(raw) = '' then
    return raw;
  end if;

  -- Already carries lower case: cased by a human or by a manufacturer.
  -- Never touched. This is the whole safety of the migration.
  if raw <> upper(raw) then
    return raw;
  end if;

  foreach token in array regexp_split_to_array(btrim(raw), '\s+') loop
    out_parts := '{}';

    foreach part in array string_to_array(token, '-') loop
      if part = '' then
        cased := part;                       -- '--' or a leading hyphen
      elsif part ~ '[0-9]' then
        cased := part;                       -- 500SC, 750DF, 2,4
      elsif length(part) = 1 then
        cased := part;                       -- the D of 2,4-D
      elsif part = any (keep_upper) then
        cased := part;                       -- ULV, MCPA
      elsif part !~ '[AEIOUY]' then
        cased := part;                       -- WG, SC, EC, MZ, XL, NT
      else
        cased := initcap(part);
      end if;

      out_parts := out_parts || cased;
    end loop;

    out_tokens := out_tokens || array_to_string(out_parts, '-');
  end loop;

  return array_to_string(out_tokens, ' ');
end;
$$;

comment on function public.vt_display_chemical_name(text) is
  'Readable case for a SHOUTED chemical product name. Returns any name that '
  'already contains a lower-case letter unchanged. Never applied to '
  'master_chemicals.registered_product_name (register evidence) or to '
  'spray_records (frozen snapshots).';

-- ---------------------------------------------------------------------------
-- 2. Every future write, from every client
-- ---------------------------------------------------------------------------
-- The trigger is the reason no client needs to change: iOS, Android, the
-- portal and the external write API (sql/186) all reach the same rule. A
-- client that already sends a cased name writes it through unchanged.
create or replace function public.saved_chemicals_display_name()
returns trigger
language plpgsql
as $$
begin
  new.name := public.vt_display_chemical_name(new.name);
  return new;
end;
$$;

-- Fires before `saved_chemicals_set_updated_at` (BEFORE triggers run in name
-- order), which is irrelevant to correctness but keeps the ordering obvious.
create or replace trigger saved_chemicals_display_name
before insert or update on public.saved_chemicals
for each row execute function public.saved_chemicals_display_name();

-- ---------------------------------------------------------------------------
-- 3. The names already in the field
-- ---------------------------------------------------------------------------
-- Live rows only. A soft-deleted row that is ever restored passes through the
-- trigger on that update, so there is nothing to gain from churning it now.
--
-- This bumps `updated_at`, which is exactly what makes the change reach the
-- field: every client pulls by `updated_at`, so operators get the readable
-- name on their next sync without an app update.
update public.saved_chemicals c
   set name = public.vt_display_chemical_name(c.name)
 where c.deleted_at is null
   and c.name <> ''
   and public.vt_display_chemical_name(c.name) is distinct from c.name;

commit;
