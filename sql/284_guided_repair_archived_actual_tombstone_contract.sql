-- PR52: narrow compatibility correction; NO data mutation or trigger disable.
-- Fail closed if either deployed function differs from the reviewed catalog.
-- Run only after the disposable PostgreSQL contract selection passes.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '30s';

do $migration$
declare
    definition text;
    anchor text := E'begin\r\n  select * into v_trip from public.trips where id=new.trip_id and deleted_at is null;';
    replacement text := $patch$begin
  -- PR52_ARCHIVED_LEGACY_ACTUAL_TOMBSTONE: exact retained OLD only.
  -- A client cannot insert/update the immutable compliance archive. This
  -- branch permits only the tombstone transition the reviewed RPC archived
  -- in this transaction, not any amount, identity, time or version edits.
  if tg_op='UPDATE' then
    if old.deleted_at is null and new.deleted_at is not null
       and auth.uid() is not null
       and new.updated_by=auth.uid()
       and (to_jsonb(new)-array['deleted_at','updated_by']) =
           (to_jsonb(old)-array['deleted_at','updated_by'])
       and public.vineyard_role(old.vineyard_id) in ('owner','manager')
       and exists (
         select 1 from public.trip_compliance_archive a
         join public.trips t on t.id=old.trip_id and t.vineyard_id=old.vineyard_id
         where a.trip_id=old.trip_id and a.vineyard_id=old.vineyard_id
           and a.source='reviewed_legacy_trip_deletion' and a.created_by=auth.uid()
           and t.deleted_at is not null
           and a.facts->>'contract'='vinetrack.guided-deleted-trip-reconciliation-v1'
           and a.facts->>'actor_user_id'=auth.uid()::text
           and a.facts->>'application_classification' in ('applied','not_applied')
           and a.facts->'original_trip'=to_jsonb(t)
           and a.facts->'original_tank_actuals' @> jsonb_build_array(to_jsonb(old))
       ) then
      new.updated_by:=auth.uid();
      new.sync_version:=old.sync_version+1;
      return new;
    end if;
  end if;
  select * into v_trip from public.trips where id=new.trip_id and deleted_at is null;$patch$;
begin
    definition := pg_get_functiondef('public.spray_tank_actuals_before_write()'::regprocedure);
    -- Hashes are filled from exact catalog and exact replacement by the
    -- checked-in contract runner; no wholesale stale definition is deployed.
    if md5(definition) = '2c361a16b999b3b05fb769d9c5558ec5' then return; end if;
    if md5(definition) <> 'c6b262c21ccb8d5352b4eee968dc621a' then
        raise exception 'PR52_TRIGGER_DEFINITION_DRIFT: inspect before migration';
    end if;
    if position(anchor in definition)=0 then raise exception 'PR52_TRIGGER_ANCHOR_MISSING'; end if;
    execute replace(definition,anchor,replacement);
end
$migration$;

do $migration$
declare
    definition text;
    anchor text := E'        return public.trip_cancellation_receipt_json_v1(v_existing)\n';
    replacement text := $patch$        -- PR52_EXACT_REVIEW_REPLAY: the actor and exact frozen body matter.
        if v_existing.actor_user_id is distinct from v_uid or not exists (
            select 1 from public.trip_compliance_archive a
            where a.id=v_existing.compliance_archive_id
              and a.operation_id=p_operation_id and a.trip_id=p_trip_id
              and a.vineyard_id=p_vineyard_id and a.created_by=v_uid
              and a.source='reviewed_legacy_trip_deletion'
              and a.facts->>'contract'='vinetrack.guided-deleted-trip-reconciliation-v1'
              and a.facts->>'actor_user_id'=v_uid::text
              and a.facts->>'application_classification'=p_application
              and a.facts->>'operator_attestation'=btrim(p_attestation)
              and a.facts->'client_original_evidence'=p_client_evidence
        ) then
            raise exception 'TRIP_REVIEW_REPLAY_EVIDENCE_CONFLICT' using errcode='23505';
        end if;
        return public.trip_cancellation_receipt_json_v1(v_existing)
$patch$;
begin
    definition := pg_get_functiondef('public.reconcile_deleted_trip_activity_v1(uuid,uuid,uuid,text,text,jsonb)'::regprocedure);
    if md5(definition) = 'b0800f82f1e869cb68b0dc01cfc43b92' then return; end if;
    if md5(definition) <> '337f6977740d542f187009c7aed377d4' then
        raise exception 'PR52_REPLAY_DEFINITION_DRIFT: inspect before migration';
    end if;
    -- Deployed definition uses CRLF; normalize only this reviewed function's
    -- line endings before locating the exact return anchor.
    definition := replace(definition,E'\r\n',E'\n');
    if position(anchor in definition)=0 then raise exception 'PR52_REPLAY_ANCHOR_MISSING'; end if;
    execute replace(definition,anchor,replacement);
end
$migration$;
commit;
