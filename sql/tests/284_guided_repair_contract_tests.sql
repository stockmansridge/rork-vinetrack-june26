-- Disposable local fixture only. Runner creates an isolated PostgreSQL cluster.
-- Exact deployed functions/triggers, catalog-derived columns, reduced schema;
-- no claim of production RLS, FK, live HTTP or concurrent-session validation.
begin;
select set_config('pr52.phase', :'phase', true);
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',true);

create function pg_temp.check_contract(label text, ok boolean) returns void language plpgsql as $$
begin
  if ok is distinct from true then raise exception 'FAIL: %',label; end if;
  raise notice 'PASS: %',label;
end $$;

create function pg_temp.expect_error(label text, statement text, expected text) returns void language plpgsql as $$
begin
  begin
    execute statement;
  exception when others then
    if position(expected in sqlerrm)>0 then raise notice 'PASS: %',label; return; end if;
    raise;
  end;
  raise exception 'FAIL (unexpected success): %',label;
end $$;

insert into vineyard_members values
 ('00000000-0000-0000-0000-000000000010','00000000-0000-0000-0000-000000000001','owner'),
 ('00000000-0000-0000-0000-000000000010','00000000-0000-0000-0000-000000000002','manager');
insert into trips(id,vineyard_id,tank_sessions,entry_source) values
 ('00000000-0000-0000-0000-000000000020','00000000-0000-0000-0000-000000000010',
  '[{"id":"original-session","tankNumber":1}]','tracked');
insert into spray_records(id,vineyard_id,trip_id,entry_source) values
 ('00000000-0000-0000-0000-000000000030','00000000-0000-0000-0000-000000000010',
  '00000000-0000-0000-0000-000000000020','tracked');
insert into spray_tank_actuals(id,vineyard_id,spray_record_id,trip_id,tank_session_id,tank_number,
  water_volume_l,chemicals,confirmed_at,confirmed_by,client_updated_at) values
 ('00000000-0000-0000-0000-000000000040','00000000-0000-0000-0000-000000000010',
  '00000000-0000-0000-0000-000000000030','00000000-0000-0000-0000-000000000020','original-session',1,
  350,'[{"id":"00000000-0000-0000-0000-000000000050","actualAmountBase":702,"unit":"g"}]',
  '2026-11-01T10:00:00.123456Z','00000000-0000-0000-0000-000000000001','2026-11-01T10:00:00.123456Z');
insert into trip_cost_allocations(vineyard_id,trip_id,season_year,total_cost) values
 ('00000000-0000-0000-0000-000000000010','00000000-0000-0000-0000-000000000020',2026,25);
update trips set deleted_at='2026-11-01T11:00:00.123456Z';

-- No receipt or archive: a broad deleted-parent write must still be rejected.
select pg_temp.expect_error('unarchived deleted-parent tombstone held',
 $$update spray_tank_actuals set deleted_at=now(),updated_by=auth.uid()$$,'Trip not found');

do $$
declare
  op uuid := '00000000-0000-0000-0000-000000000060';
  trip uuid := '00000000-0000-0000-0000-000000000020';
  vineyard uuid := '00000000-0000-0000-0000-000000000010';
  evidence jsonb := '{"confirmed_recorded_actuals_not_applied":true,"retained_initial_mix_drafts":[{"water":350,"chemical":702}]}';
  result jsonb;
  original_actual jsonb;
  original_trip jsonb;
  receipt_statement text;
begin
  select to_jsonb(a) into original_actual from spray_tank_actuals a;
  select to_jsonb(t) into original_trip from trips t;
  if current_setting('pr52.phase')='baseline' then
    perform pg_temp.expect_error('baseline real reconciliation abort reproduced with live Actual',
      format('select reconcile_deleted_trip_activity_v1(%L,%L,%L,%L,%L,%L::jsonb)',
        op,trip,vineyard,'not_applied','Verified original paper application record',evidence),'Trip not found');
    perform pg_temp.check_contract('baseline abort rolls archive/receipt back',
      not exists(select 1 from trip_compliance_archive) and not exists(select 1 from trip_activity_cancellation_receipts));
    perform pg_temp.check_contract('baseline original Actual bytes retained',
      (select to_jsonb(a)=original_actual from spray_tank_actuals a));
    return;
  end if;

  -- A synthetic pre-existing archive must not authorize any changed original
  -- fields. Roll this entire fixture back without deleting immutable evidence.
  begin
    insert into trip_compliance_archive(operation_id,trip_id,vineyard_id,source,facts,retain_until,created_by)
    values(gen_random_uuid(),trip,vineyard,'reviewed_legacy_trip_deletion',
      jsonb_build_object('contract','vinetrack.guided-deleted-trip-reconciliation-v1',
        'actor_user_id',auth.uid(),'application_classification','applied',
        'original_trip',original_trip,'original_tank_actuals',jsonb_build_array(original_actual)),
      current_date+1096,auth.uid());
    perform pg_temp.expect_error('archived transition cannot change quantities',
      'update spray_tank_actuals set deleted_at=now(),updated_by=auth.uid(),water_volume_l=351','Trip not found');
    perform pg_temp.expect_error('archived transition cannot change session identity',
      $statement$update spray_tank_actuals set deleted_at=now(),updated_by=auth.uid(),tank_session_id='replacement'$statement$,'Trip not found');
    perform pg_temp.expect_error('archived transition cannot change confirmation time',
      'update spray_tank_actuals set deleted_at=now(),updated_by=auth.uid(),confirmed_at=now()','Trip not found');
    perform pg_temp.expect_error('archived transition cannot change correction version',
      'update spray_tank_actuals set deleted_at=now(),updated_by=auth.uid(),correction_version=2','Trip not found');
    perform set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',true);
    perform pg_temp.expect_error('another manager cannot use original actor archive',
      'update spray_tank_actuals set deleted_at=now(),updated_by=auth.uid()','Trip not found');
    raise exception using errcode='Z0001',message='ROLLBACK_DISPOSABLE_ARCHIVE';
  exception when sqlstate 'Z0001' then null;
  end;
  perform pg_temp.check_contract('negative fixtures retain original Actual and leave no archive',
    not exists(select 1 from trip_compliance_archive) and (select to_jsonb(a)=original_actual from spray_tank_actuals a));

  result := reconcile_deleted_trip_activity_v1(op,trip,vineyard,'not_applied',
    'Verified original paper application record',evidence);
  perform pg_temp.check_contract('authoritative cancellation receipt created',
    result->>'status'='CANCELLED_ACKED' and result->>'operation_id'=op::text);
  perform pg_temp.check_contract('original Actual archived byte-for-byte before deletion',
    (select facts->'original_tank_actuals' @> jsonb_build_array(original_actual)
      and facts->'client_original_evidence'=evidence from trip_compliance_archive));
  perform pg_temp.check_contract('deleted Trip never resurrected or changed',
    (select to_jsonb(t)=original_trip from trips t));
  perform pg_temp.check_contract('all linked rows tombstoned',
    (select bool_and(deleted_at is not null) from spray_tank_actuals) and
    (select bool_and(deleted_at is not null) from spray_records) and
    (select bool_and(deleted_at is not null) from trip_cost_allocations));
  perform pg_temp.check_contract('Actual quantities, confirmation, identity retained',
    (select (to_jsonb(a)-array['deleted_at','updated_by','sync_version','updated_at'])=
       (original_actual-array['deleted_at','updated_by','sync_version','updated_at']) from spray_tank_actuals a));
  perform pg_temp.check_contract('same frozen request replays same receipt',
    reconcile_deleted_trip_activity_v1(op,trip,vineyard,'not_applied',
      'Verified original paper application record',evidence)->>'operation_id'=op::text);
  perform pg_temp.check_contract('replay creates no duplicate archive or receipt',
    (select count(*)=1 from trip_compliance_archive) and (select count(*)=1 from trip_activity_cancellation_receipts));

  receipt_statement := format('select reconcile_deleted_trip_activity_v1(%L,%L,%L,%L,%L,%L::jsonb)',
    op,trip,vineyard,'not_applied','Changed operator attestation from paper record',evidence);
  perform pg_temp.expect_error('changed attestation replay held',receipt_statement,'TRIP_REVIEW_REPLAY_EVIDENCE_CONFLICT');
  perform pg_temp.expect_error('changed evidence replay held',
    format('select reconcile_deleted_trip_activity_v1(%L,%L,%L,%L,%L,%L::jsonb)',
      op,trip,vineyard,'not_applied','Verified original paper application record','{}'),'TRIP_REVIEW_REPLAY_EVIDENCE_CONFLICT');
  perform pg_temp.expect_error('changed classification replay held',
    format('select reconcile_deleted_trip_activity_v1(%L,%L,%L,%L,%L,%L::jsonb)',
      op,trip,vineyard,'applied','Verified original paper application record',evidence),'TRIP_REVIEW_RECEIPT_OPERATION_CONFLICT');
  perform set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',true);
  perform pg_temp.expect_error('different authorized manager cannot claim original actor receipt',
    format('select reconcile_deleted_trip_activity_v1(%L,%L,%L,%L,%L,%L::jsonb)',
      op,trip,vineyard,'not_applied','Verified original paper application record',evidence),'TRIP_REVIEW_REPLAY_EVIDENCE_CONFLICT');
  perform set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000099',true);
  perform pg_temp.expect_error('nonmember review held',
    format('select reconcile_deleted_trip_activity_v1(%L,%L,%L,%L,%L,%L::jsonb)',
      op,trip,vineyard,'not_applied','Verified original paper application record',evidence),'TRIP_REVIEW_FORBIDDEN');
  perform set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',true);
  perform pg_temp.expect_error('receipt-backed Actual cannot be changed afterwards',
    'update spray_tank_actuals set water_volume_l=351','TRIP_CANCELLED_TOMBSTONE');
end $$;
rollback;
