-- Rollback-only structural checks. Run after SQL 224 and 225.
begin;

do $$ begin
  if to_regclass('public.trip_report_assets') is null then raise exception 'trip_report_assets missing'; end if;
  if to_regprocedure('public.get_spray_report_v1(uuid)') is null then raise exception 'canonical report RPC missing'; end if;
  if to_regprocedure('public.spray_report_tanks_v1(jsonb,uuid)') is null then raise exception 'canonical tank normalizer missing'; end if;
  if to_regprocedure('public.spray_report_rows_v1(public.trips,jsonb)') is null then raise exception 'canonical row normalizer missing'; end if;
  if to_regprocedure('public.spray_report_active_seconds_v1(timestamptz,timestamptz,jsonb,jsonb)') is null then raise exception 'duration normalizer missing'; end if;
  if has_table_privilege('anon','public.trip_report_assets','select') then raise exception 'anon can read route metadata'; end if;
  if has_table_privilege('authenticated','public.trip_report_assets','insert') then raise exception 'authenticated can write route metadata directly'; end if;
  if not exists(select 1 from storage.buckets where id='trip-report-assets' and public=false) then raise exception 'private route bucket missing'; end if;
end $$;

do $$ declare seconds bigint; begin
  seconds := public.spray_report_active_seconds_v1(
    '2026-09-04 00:00:00+00', '2026-09-04 03:35:00+00',
    '["2026-09-04T01:00:00Z"]'::jsonb, '["2026-09-04T01:34:00Z"]'::jsonb
  );
  if seconds <> 10860 then raise exception 'pause-adjusted duration expected 10860, got %', seconds; end if;
end $$;

rollback;
