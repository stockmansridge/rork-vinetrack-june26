-- Read-only verification for 281. Always raises so nothing persists.
-- Deployed 2026-11-02 result (recorded in docs/sync/P0_TRIP_CANCELLATION_PHASE_A_RESULTS_20261102.md):
--   cancel_trip_activity_v1  owner=postgres secdef=t acl=authenticated,service_role,postgres  md5=f14c6be3c8053ce31d35fffa0894de6c
--   guard_cancelled_trip_v1  owner=postgres secdef=t acl=postgres,service_role               md5=0a4b2f8663682ef33cc89bf342e3a225
--   4 tombstone triggers + 2 immutability triggers enabled; both tables RLS on, authenticated=select only.
--   receipts=0 archive=0; original Trip 3bfb7f81-... unchanged (active, not deleted).
do $$ declare r text; begin
select string_agg(x, ' | ') into r from (
 select format('fn %s owner=%s secdef=%s acl=%s md5=%s', p.proname, pg_get_userbyid(p.proowner), p.prosecdef,
   coalesce(p.proacl::text,'default'), md5(pg_get_functiondef(p.oid))) x
 from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in
   ('cancel_trip_activity_v1','guard_cancelled_trip_v1','trip_cancellation_immutable_v1','trip_cancellation_receipt_json_v1')
 union all select format('trg %s on %s enabled=%s', t.tgname, t.tgrelid::regclass, t.tgenabled) from pg_trigger t
 where t.tgname in ('aa0_trip_cancellation_tombstone_guard','trip_cancel_receipts_immutable','trip_compliance_archive_immutable')
 union all select format('tbl %s owner=%s rls=%s acl=%s', c.relname, pg_get_userbyid(c.relowner), c.relrowsecurity, c.relacl::text)
 from pg_class c where c.relnamespace='public'::regnamespace and c.relname in ('trip_activity_cancellation_receipts','trip_compliance_archive')
 union all select format('receipts=%s archive=%s original_trip_deleted_at=%s original_trip_active=%s',
   (select count(*) from public.trip_activity_cancellation_receipts), (select count(*) from public.trip_compliance_archive),
   (select deleted_at::text from public.trips where id='3bfb7f81-2ae2-4f33-8fd8-6666b2b45393'),
   (select is_active::text from public.trips where id='3bfb7f81-2ae2-4f33-8fd8-6666b2b45393'))
) s;
raise exception 'VERIFY %', r; end $$;
