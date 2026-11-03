-- READ ONLY: capture before and after sql/occurrence_tank_link_uuid_case_identity.sql.
-- This query does not deploy, SET ROLE, grant privileges, change ownership, read customer
-- rows, or establish the outcome of any retained operation.
-- Compare the two captures: owner, security_definer, function_acl and function_search_path must be
-- IDENTICAL. Only definition_md5 and the two comparison flags change
-- (old_text_comparison_present true -> false, case_insensitive_comparison_present false -> true).
with targets(signature, old_text, new_text) as (
  values
    ('public.guard_trip_occurrence_authority_v1()'::regprocedure,
     $old$s->>'id'=linked$old$,
     $new$lower(s->>'id')=lower(linked)$new$),
    ('public.apply_trip_occurrence_action_v1(uuid,uuid,bigint,bigint,jsonb)'::regprocedure,
     $old$s->>'id'=session_id$old$,
     $new$lower(s->>'id')=lower(session_id)$new$)
), target as (
  select t.old_text, t.new_text, p.*, pg_get_functiondef(p.oid) as definition
  from targets t
  join pg_proc p on p.oid = t.signature
)
select
  oid::regprocedure::text as function_signature,
  pg_get_userbyid(proowner) as function_owner,
  md5(definition) as definition_md5,
  prosecdef as security_definer,
  proacl::text as function_acl,
  array(select setting from unnest(proconfig) setting where setting like 'search_path=%') as function_search_path,
  strpos(definition, old_text) > 0 as old_text_comparison_present,
  strpos(definition, new_text) > 0 as case_insensitive_comparison_present
from target
order by function_signature;
-- Expect exactly 2 rows. Zero rows, one row, or any unexpected owner/ACL/security change means STOP.
-- This source-shape check is not a substitute for reviewing the complete deployed functions.
