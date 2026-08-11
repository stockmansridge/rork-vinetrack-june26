-- =============================================================================
-- 185: Cross-device sync integrity — pruning stale-write protection +
--      picking-record attribution guard (sync audit items #12 and #3)
--
-- 1. STALE-WRITE PROTECTION for the two pruning tables clients upsert
--    DIRECTLY (everything else pruning-related goes through RPCs that
--    already carry their own stale checks — sql/166 reverse/edit guards):
--
--      * public.pruning_seasons        (merge-duplicates upsert on id)
--      * public.pruning_yield_settings (merge-duplicates upsert on
--                                       vineyard_id, paddock_id)
--
--    A BEFORE UPDATE trigger silently SKIPS an update whose
--    client_updated_at is OLDER than the row's stored client_updated_at.
--    Conflict order this protects (the audit scenario):
--      1. Device A edits offline (client_updated_at = T1).
--      2. Device B saves a newer change online (T2 > T1) — applied.
--      3. Device A reconnects and replays its T1 edit — SKIPPED.
--      4. Device B's newer value remains authoritative; Device A's next
--         pull converges on it.
--
--    The skip is silent (no error): PostgREST reports success with an
--    empty representation, so replay queues resolve instead of retrying.
--    Writes that do NOT move client_updated_at backwards are unaffected:
--      * server-side updates / soft-delete RPCs never touch
--        client_updated_at (new = old → not stale);
--      * an equal timestamp is allowed (idempotent re-send of the same
--        write);
--      * rows with NULL client_updated_at on either side are never
--        blocked (legacy rows keep last-write-wins).
--    Clients replay with the ORIGINAL edit time (iOS: the dirty-mark
--    timestamp; Android: the outbox marker's enqueue time), so a late
--    replay is honestly dated.
--
-- 2. PICKING-RECORD ATTRIBUTION GUARD (audit #3): the iOS sync pushes
--    edits through the same upsert as creates and used to overwrite
--    created_by with the CURRENT editor. created_by is now write-once:
--      * INSERT: defaults to auth.uid() when the client omits it;
--      * UPDATE: the original created_by is always preserved;
--      * updated_by reflects the editor on every authenticated write.
--    This protects attribution for ALL clients (iOS, Android, portal),
--    whatever they send.
--
-- No schema changes, no backfill — additive triggers only.
-- Verification: sql/tests/185_sync_stale_write_tests.sql (rollback-only).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Shared stale-write guard
-- ---------------------------------------------------------------------------
create or replace function public.reject_stale_client_write()
returns trigger
language plpgsql
as $$
begin
  if new.client_updated_at is not null
     and old.client_updated_at is not null
     and new.client_updated_at < old.client_updated_at then
    -- A late offline replay must not overwrite a newer edit from another
    -- device/portal. Returning NULL skips this UPDATE silently — the
    -- client's replay resolves as success and its next pull converges on
    -- the newer authoritative row.
    return null;
  end if;
  return new;
end;
$$;

drop trigger if exists pruning_seasons_stale_write_guard on public.pruning_seasons;
create trigger pruning_seasons_stale_write_guard
before update on public.pruning_seasons
for each row execute function public.reject_stale_client_write();

drop trigger if exists pruning_yield_settings_stale_write_guard on public.pruning_yield_settings;
create trigger pruning_yield_settings_stale_write_guard
before update on public.pruning_yield_settings
for each row execute function public.reject_stale_client_write();

-- ---------------------------------------------------------------------------
-- 2. picking_records attribution guard (created_by write-once, updated_by
--    mirrors the editor). Kept separate from picking_records_before_write
--    (sql/180/184) so the vintage/normalisation trigger stays single-purpose.
-- ---------------------------------------------------------------------------
create or replace function public.picking_records_attribution_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := coalesce(new.created_by, auth.uid());
    new.updated_by := coalesce(auth.uid(), new.updated_by);
  else
    -- Editing never reassigns authorship — whatever the client sent.
    new.created_by := coalesce(old.created_by, new.created_by);
    new.updated_by := coalesce(auth.uid(), new.updated_by);
  end if;
  return new;
end;
$$;

drop trigger if exists picking_records_attribution_guard on public.picking_records;
create trigger picking_records_attribution_guard
before insert or update on public.picking_records
for each row execute function public.picking_records_attribution_guard();

notify pgrst, 'reload schema';
