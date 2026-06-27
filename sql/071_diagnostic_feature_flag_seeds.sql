-- 071_diagnostic_feature_flag_seeds.sql
--
-- Add system feature flag rows for the diagnostic surfaces that were
-- previously hard-coded / always-visible (or DEBUG-only) inside the iOS
-- app. After this migration, normal users see clean operational screens
-- and system admins can flip these on individually from
-- Settings -> System Admin -> Feature Flags.
--
-- All flags default to OFF (is_enabled = false) so production behaviour
-- becomes "diagnostics hidden" immediately on roll-out.
--
-- Idempotent: re-running this migration is a no-op for existing rows.
-- We deliberately do NOT overwrite an admin's existing toggle state.

insert into public.system_feature_flags
    (key, value, value_type, category, label, description, is_enabled)
values
    (
        'show_variety_diagnostics',
        'false'::jsonb,
        'boolean',
        'diagnostics',
        'Variety Diagnostics',
        'Show grape variety allocation diagnostics (paddock id, allocation id, varietyId, resolver path, sync metadata) inside Block/Paddock Settings. System admins only.',
        false
    ),
    (
        'show_irrigation_diagnostics',
        'false'::jsonb,
        'boolean',
        'diagnostics',
        'Irrigation Diagnostics',
        'Show the irrigation rate resolver diagnostics section inside the Irrigation Advisor. System admins only.',
        false
    )
on conflict (key) do nothing;
