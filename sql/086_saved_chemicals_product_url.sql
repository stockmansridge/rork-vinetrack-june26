-- 086_saved_chemicals_product_url.sql
--
-- Adds a separate product_url column to saved_chemicals so we can store a
-- manufacturer/product page link distinctly from the official label PDF
-- (label_url). The two must never be conflated in UI — a product marketing
-- page must not be presented as a "Label".
--
-- Also performs a CONSERVATIVE cleanup of clearly bogus label_url values
-- that earlier (un-validated) AI lookups wrote. Only obvious offenders are
-- nulled:
--   - empty / whitespace-only strings (already default '' but be tolerant)
--   - placeholder hosts (example.com, manufacturer.com, etc.)
--   - bare homepages (no path beyond '/')
--   - generic /products/<slug> shaped paths that are NOT PDFs and NOT on a
--     known regulator host (APVMA / EPA / ACVM / EU register)
--   - the specific known hallucination hortitrol.com.au/products/winter-oil
--
-- We deliberately DO NOT touch:
--   - URLs ending in .pdf
--   - URLs whose path contains /label, /labels, /sds, /msds
--   - URLs hosted on apvma.gov.au, epa.gov, epa.govt.nz, acvm.govt.nz,
--     ec.europa.eu, efsa.europa.eu
--
-- Where label_url is cleared, we promote it to product_url so the operator
-- can still see "Product page" rather than losing the lookup entirely.

begin;

alter table public.saved_chemicals
    add column if not exists product_url text not null default '';

-- Helper expressions inlined below; we only run the cleanup once.

with candidates as (
    select
        id,
        coalesce(label_url, '') as url,
        lower(coalesce(label_url, '')) as lurl
    from public.saved_chemicals
    where coalesce(label_url, '') <> ''
),
classified as (
    select
        id,
        url,
        case
            -- Keep: PDFs and label/SDS document paths.
            when lurl ~ '\.pdf($|\?)' then false
            when lurl ~ '/(label|labels|sds|msds)(/|$|\?)' then false
            -- Keep: official regulator hosts.
            when lurl ~ '://([^/]+\.)?(apvma\.gov\.au|epa\.gov|epa\.govt\.nz|acvm\.govt\.nz|ec\.europa\.eu|efsa\.europa\.eu)(/|$)' then false
            -- Drop: placeholder hosts.
            when lurl ~ '://([^/]+\.)?(example\.com|example\.org|example\.net|placeholder\.com|yourdomain\.com|domain\.com|manufacturer\.com|website\.com|company\.com|test\.com)(/|$)' then true
            -- Drop: bare homepages (no path or just '/').
            when lurl ~ '^https?://[^/]+/?$' then true
            -- Drop: generic /products/<slug> on non-regulator hosts.
            when lurl ~ '/products?/[^/]+/?$' then true
            -- Drop: the specific known hallucination.
            when lurl like '%hortitrol.com.au/products/winter-oil%' then true
            else false
        end as is_bogus
    from candidates
)
update public.saved_chemicals s
set
    product_url = case
        when coalesce(s.product_url, '') = '' then c.url
        else s.product_url
    end,
    label_url = ''
from classified c
where s.id = c.id and c.is_bogus = true;

commit;
