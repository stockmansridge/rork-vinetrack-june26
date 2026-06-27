-- Phase: Pin audit trail — capture completed_by as a real user UUID.
--
-- The pins table already records:
--   created_by uuid references auth.users(id)
--   completed_by text       (display name only — not auditable)
--   completed_at timestamptz
--
-- This migration adds an auditable user reference for completion alongside
-- the existing display-name text column. The text column is preserved for
-- backwards compatibility so existing rows and older clients keep working.
--
-- Safe / additive:
--   * New nullable column, no default value rewrites
--   * No backfill (created_by = updated_by would be wrong for completion)
--   * No RLS / policy changes — pins_update_members already covers updates
--   * No RPC changes — admin_list_pins() can be extended later

alter table public.pins
  add column if not exists completed_by_user_id uuid null
    references auth.users(id) on delete set null;

create index if not exists idx_pins_completed_by_user_id
  on public.pins (completed_by_user_id);

comment on column public.pins.completed_by_user_id is
  'auth.users.id of the user who marked the pin completed. The companion text column completed_by is kept for backwards compatibility / display fallback.';
