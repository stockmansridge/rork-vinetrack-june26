-- Stable provenance for vineyard Saved Chemicals. Existing rows are left untouched.
-- Chemical Search UI versions must never become entry_source values.
alter table public.saved_chemicals
  drop constraint if exists saved_chemicals_entry_source_check;

alter table public.saved_chemicals
  add constraint saved_chemicals_entry_source_check
  check (entry_source is null or entry_source in (
    'customer_entered', 'register_lookup', 'master_catalogue', 'label_lookup'
  ));

comment on column public.saved_chemicals.entry_source is
  'Stable evidence provenance: customer_entered (user confirmed without external evidence), master_catalogue (VineTrack Master), register_lookup (verified regulatory registration), label_lookup (genuine label discovery without verified registration); NULL for legacy rows. Not a UI version.';
