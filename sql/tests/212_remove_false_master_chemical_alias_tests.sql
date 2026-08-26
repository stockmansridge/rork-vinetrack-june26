-- Tests for sql/212 — READ-ONLY. Safe to run before and after the migration.
--
-- Nothing here writes. Run it BEFORE 212 to see the contamination, and AFTER
-- 212 to prove it is gone and that nothing else moved.
--
-- ONE STATEMENT, ON PURPOSE
--
--   This is a single query returning a verdict table, so it runs identically
--   in the Supabase SQL editor, in psql, and through any client that returns
--   only the last result set. It contains no psql meta-commands (\echo and
--   friends are client-side directives, not SQL — the server sees a stray
--   backslash and rejects the statement).
--
-- READING THE OUTPUT
--
--   check_name  what is being asserted
--   verdict     PASS / FAIL / INFO
--   detail      the actual state, so a FAIL explains itself
--
--   Before 212 runs, checks 2 and 3 are EXPECTED to FAIL — that failure is
--   the contamination this migration exists to remove. Every other check
--   must PASS both before and after.

with
-- The exact contamination: the typed phrase as a whole-string alias.
false_alias as (
  select
    m.registration_country as country,
    m.registration_number  as number,
    m.registered_product_name as product,
    a.alias
  from public.master_chemicals m,
       lateral unnest(m.common_names) as a(alias)
  where lower(trim(a.alias)) = 'hortitrol winter oil'
),
-- Anything resembling it, anywhere, in any country. Moving a bad alias is
-- not removing it.
hortitrol_like as (
  select
    m.registration_country as country,
    m.registration_number  as number,
    m.registered_product_name as product,
    a.alias
  from public.master_chemicals m,
       lateral unnest(m.common_names) as a(alias)
  where lower(a.alias) like '%hortitrol%'
),
row_50067 as (
  select *
  from public.master_chemicals
  where registration_country = 'AU' and registration_number = '50067'
),
row_33182 as (
  select *
  from public.master_chemicals
  where registration_country = 'AU' and registration_number = '33182'
),
-- Catalogue-wide sweep: an alias sharing no substantive word with its own
-- product name is the SHAPE of this defect, wherever else it occurs.
orphan_aliases as (
  select
    m.registration_country as country,
    m.registration_number  as number,
    m.registered_product_name as product,
    a.alias
  from public.master_chemicals m,
       lateral unnest(m.common_names) as a(alias)
  where not exists (
    select 1
    from regexp_split_to_table(lower(a.alias), '[^a-z0-9]+') as w(word)
    where length(w.word) > 2
      and lower(m.registered_product_name) like '%' || w.word || '%'
  )
)

select 1 as seq,
       'APVMA 50067 still exists' as check_name,
       case when exists (select 1 from row_50067) then 'PASS' else 'FAIL' end as verdict,
       coalesce(
         (select registered_product_name || ' | review_status=' || coalesce(review_status, '-')
                 || ' | aliases=' || cardinality(common_names)
          from row_50067),
         'ROW MISSING — the cleanup must never delete a product'
       ) as detail

union all
select 2,
       'The false alias is gone from 50067',
       case when exists (select 1 from false_alias) then 'FAIL' else 'PASS' end,
       coalesce(
         (select string_agg(country || ':' || number || ' -> "' || alias || '"', '; ')
          from false_alias),
         'no row carries "hortitrol winter oil"'
       )

union all
select 3,
       'Nothing anywhere acquired a hortitrol alias',
       case when exists (select 1 from hortitrol_like) then 'FAIL' else 'PASS' end,
       coalesce(
         (select string_agg(country || ':' || number || ' (' || product || ') -> "' || alias || '"', '; ')
          from hortitrol_like),
         'clean across every country and every row'
       )

union all
select 4,
       'APVMA 33182 was NOT promoted or altered',
       case
         when not exists (select 1 from row_33182) then 'INFO'
         when exists (
           select 1 from row_33182 r, lateral unnest(r.common_names) as a(alias)
           where lower(a.alias) like '%hortitrol%'
         ) then 'FAIL'
         else 'PASS'
       end,
       coalesce(
         (select 'review_status=' || coalesce(review_status, '-')
                 || ' | verification=' || coalesce(verification_status, '-')
                 || ' | unresolved=[' || coalesce(array_to_string(verification_unresolved_fields, ','), '') || ']'
                 || ' | aliases=[' || coalesce(array_to_string(common_names, ', '), '') || ']'
          from row_33182),
         'not present in this catalogue — the repair must not create it'
       )

union all
select 5,
       '50067 kept the alias derived from its REGISTERED name',
       case
         when not exists (select 1 from row_50067) then 'FAIL'
         when exists (
           select 1 from row_50067 r, lateral unnest(r.common_names) as a(alias)
           where lower(trim(a.alias)) = lower(trim(r.registered_product_name))
         ) then 'PASS'
         else 'INFO'
       end,
       coalesce(
         (select 'aliases=[' || coalesce(array_to_string(common_names, ', '), '') || ']'
          from row_50067),
         'row missing'
       )

union all
select 6,
       'Rows left with no aliases at all',
       'INFO',
       (select count(*)::text || ' row(s) have an empty common_names array'
        from public.master_chemicals
        where cardinality(common_names) = 0)

union all
select 7,
       'Catalogue-wide alias sanity (review by hand)',
       case when (select count(*) from orphan_aliases) = 0 then 'PASS' else 'INFO' end,
       coalesce(
         (select count(*)::text || ' alias(es) share no word with their own product name: '
                 || string_agg(country || ':' || number || ' -> "' || alias || '"', '; ')
          from (select * from orphan_aliases order by country, number limit 15) t),
         'every alias relates to its own registered product name'
       )

order by seq;
