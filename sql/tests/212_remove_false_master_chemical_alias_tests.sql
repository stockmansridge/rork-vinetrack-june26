-- Tests for sql/212 — READ-ONLY. Safe to run before and after the migration.
--
-- Nothing here writes. Run it BEFORE 212 to see the contamination, and AFTER
-- 212 to prove it is gone and that nothing else moved.

\echo '== 212 PRE/POST: APVMA 50067 exists and is untouched =========='

select
  registration_country,
  registration_scheme,
  registration_number,
  registered_product_name,
  review_status,
  cardinality(common_names) as alias_count,
  common_names
from public.master_chemicals
where registration_country = 'AU'
  and registration_number = '50067';

\echo '== 212 POST: the false alias must return ZERO rows ============'

select
  registration_number,
  alias
from public.master_chemicals,
     unnest(common_names) as alias
where registration_country = 'AU'
  and lower(trim(alias)) = 'hortitrol winter oil';

\echo '== 212 POST: nothing acquired the alias elsewhere ============='
\echo '   (moving a bad alias is not removing it — this must be empty'
\echo '    for EVERY country and every row, 33182 included)'

select
  registration_country,
  registration_number,
  registered_product_name,
  alias
from public.master_chemicals,
     unnest(common_names) as alias
where lower(trim(alias)) like '%hortitrol%';

\echo '== 212 POST: APVMA 33182 was NOT promoted or altered =========='
\echo '   The repair must not decide which product the user meant.'

select
  registration_number,
  registered_product_name,
  review_status,
  common_names,
  verification_status,
  verification_unresolved_fields
from public.master_chemicals
where registration_country = 'AU'
  and registration_number = '33182';

\echo '== 212 POST: no row lost its own registered name as an alias ==='
\echo '   The cleanup targets one string; every row must still carry the'
\echo '   alias derived from its REGISTERED name.'

select
  registration_country,
  registration_number,
  registered_product_name,
  common_names
from public.master_chemicals
where cardinality(common_names) = 0
order by registration_country, registration_number
limit 25;

\echo '== 212 POST: catalogue-wide alias sanity ======================'
\echo '   An alias that matches no word of its own product name is the'
\echo '   shape of the defect. Review anything listed here by hand.'

select
  m.registration_country,
  m.registration_number,
  m.registered_product_name,
  a.alias
from public.master_chemicals m,
     unnest(m.common_names) as a(alias)
where not exists (
  select 1
  from regexp_split_to_table(lower(a.alias), '[^a-z0-9]+') as alias_word
  where length(alias_word) > 2
    and lower(m.registered_product_name) like '%' || alias_word || '%'
)
order by m.registration_country, m.registration_number
limit 50;
