-- READ ONLY: capture before and after the existing owner-authorised repair.
-- This query does not deploy, SET ROLE, grant privileges, change ownership,
-- read customer rows, or establish the outcome of any retained operation.
-- Compare owner/security/ACL/search-path fields between the two captures;
-- only the definition hash and the two comparison flags should change.
with target as (
  select p.*, pg_get_functiondef(p.oid) as definition
  from pg_proc p
  where p.oid = to_regprocedure('public.create_trip_with_occurrences_v1(uuid,jsonb,jsonb)')
)
select
  oid::regprocedure::text as function_signature,
  pg_get_userbyid(proowner) as function_owner,
  md5(definition) as definition_md5,
  prosecdef as security_definer,
  proacl::text as function_acl,
  array(select setting from unnest(proconfig) setting where setting like 'search_path=%') as function_search_path,
  strpos(definition, $old$not provided_blocks ? (i->>'blockId')$old$) > 0 as old_text_comparison_present,
  strpos(definition, $new$not exists(select 1 from jsonb_array_elements_text(provided_blocks) selected(id) where selected.id::uuid = (i->>'blockId')::uuid)$new$) > 0 as uuid_identity_comparison_present,
  -- The function delegates auth.uid() through the protected actor helper. A direct
  -- auth.uid() string in this caller is NOT required and was an invalid gate.
  strpos(definition, 'if public.trip_occurrence_actor_uid_v1() is null') > 0 as actor_uid_guard_present,
  strpos(definition, 'public.has_vineyard_role(vineyard,array[''owner'',''manager'',''supervisor'',''operator''])') > 0 as vineyard_role_guard_present,
  strpos(definition, 'if prior.actor_id<>public.trip_occurrence_actor_uid_v1()') > 0 as replay_actor_guard_present,
  md5(pg_get_functiondef('public.trip_occurrence_actor_uid_v1()'::regprocedure)) as actor_helper_definition_md5,
  md5(pg_get_functiondef('public.has_vineyard_role(uuid,text[])'::regprocedure)) as vineyard_role_helper_definition_md5
from target;
-- Zero rows or any unexpected owner/definition/security/ACL change means STOP.
-- This source-shape check is not a substitute for reviewing the complete
-- deployed function and authenticating the original request/receipt identities.
