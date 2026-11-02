# PR #31 occurrence setup UUID correction: authorised deployment route

Status: NOT DEPLOYED. Live definition last observed: MD5 `b0e166d78be75c8ba770b2dccfd14256`,
old text comparison present, UUID identity comparison absent.

## Who can apply it

- `public.create_trip_with_occurrences_v1(uuid,jsonb,jsonb)` is owned by `vinetrack_occurrence_writer`
  (`sql/276_trip_occurrence_authority_v1.sql`, line 430).
- That role is deliberately `NOLOGIN NOINHERIT` and migration 276 refuses to run if it has any
  member. Nobody can log in as it and no role inherits it.
- PostgreSQL only lets the owner, a member of the owner role, or a superuser replace a function.
  The connected `postgres` role is none of these, so it was refused (SQLSTATE 42501).
- So the only authorised route that changes no privileges is the superuser-level session that
  originally applied migrations 276 and 278. Those migrations ran `ALTER FUNCTION ... OWNER TO`
  while the role had zero members, which is only possible with that authority. On Supabase that
  is the platform administrator session, not the project `postgres` login.
- The repository does not record which person or ticket holds that session; there is no
  migration-history entry for 276/278. The project owner must name it. Do not substitute another
  route.

Not authorised (do not do, even temporarily): `GRANT vinetrack_occurrence_writer TO postgres`,
`ALTER ROLE ... LOGIN`, `ALTER FUNCTION ... OWNER TO`, drop/recreate of the function, or a
new wrapper function. Each changes the security contract that 276 enforces.

## Exact steps for the authorised operator

1. **Read-only before-capture** (any role can run it):
   `sql/occurrence_setup_uuid_case_identity_verify.sql`. Expect exactly one row with:
   - `function_owner = vinetrack_occurrence_writer`
   - `definition_md5 = b0e166d78be75c8ba770b2dccfd14256` (if different, STOP and re-review the live function)
   - `security_definer = true`
   - `old_text_comparison_present = true`, `uuid_identity_comparison_present = false`
   - `actor_uid_guard_present = true`, `vineyard_role_guard_present = true`, `replay_actor_guard_present = true` (the function delegates `auth.uid()` through `trip_occurrence_actor_uid_v1()`, so no direct `auth.uid()` text is expected)
   - Record the two helper function MD5s and verify they do not change.
   Save `function_acl` and `function_search_path` verbatim.
2. **Apply inside one transaction** in the authorised session:
   ```sql
   begin;
   set local lock_timeout = '5s';
   set local statement_timeout = '30s';
   \i sql/occurrence_setup_uuid_case_identity.sql
   \i sql/occurrence_setup_uuid_case_identity_verify.sql
   -- COMMIT only if: owner, security_definer, function_acl and function_search_path are
   -- byte-identical to step 1; old_text_comparison_present = false;
   -- uuid_identity_comparison_present = true; all three delegated authority guards remain true and both helper-function MD5s remain identical.
   -- Otherwise ROLLBACK.
   commit;
   ```
   The script replaces exactly one occurrence of the comparison, or raises and changes nothing.
   It is idempotent if already applied. `CREATE OR REPLACE` keeps the owner, ACL, `SECURITY DEFINER`
   and `SET search_path` (all three come from `pg_get_functiondef`). The signature does not
   change, so no API schema reload is needed.
3. **Read-only after-capture**: run the verify query again from the normal role and record the new
   `definition_md5`. Only the main function MD5 and the two comparison flags may differ from step 1; delegated authority guards, helper hashes and security metadata must remain unchanged.
4. **No data step.** Do not replay, rewrite or delete existing `trip_occurrence_operations` rows
   or retained client requests. Affected devices retry their own original requests through
   normal recovery, keeping the same operation IDs.

Record the operator, timestamp, before and after MD5 values, and the commit/rollback decision in
`docs/reviews/evidence/p0-trip-start/`.
