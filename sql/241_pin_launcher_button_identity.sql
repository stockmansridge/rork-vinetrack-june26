-- Additive stable launcher-button identity for Repair/Growth pins.
-- Run before releasing mobile builds that write launcher_button_id.
-- Legacy pins remain readable and intentionally stay NULL when their historical
-- button relationship cannot be determined safely.

alter table public.pins
  add column if not exists launcher_button_id uuid null;

comment on column public.pins.launcher_button_id is
  'Stable id of the vineyard_button_configs config_data launcher button used to create or classify this pin. Nullable for legacy/ambiguous records.';

create index if not exists idx_pins_launcher_button_id
  on public.pins (vineyard_id, launcher_button_id)
  where launcher_button_id is not null and deleted_at is null;
