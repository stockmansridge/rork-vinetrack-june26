-- 078_soil_aware_irrigation_v2_flag.sql
--
-- Add the system feature flag that gates the Soil-Aware Irrigation v2
-- recommendation model (RAW caps, split-event suggestions, urgency,
-- heavy-clay/sandy/shallow cautions). v1 calculation still runs when
-- the flag is OFF so users can compare side-by-side before rolling
-- v2 out as the default.
--
-- Defaults to OFF. System admins can enable it from
-- Settings → System Admin → Feature Flags, or per-tester via a future
-- per-user override. Idempotent.

insert into public.system_feature_flags
    (key, value, value_type, category, label, description, is_enabled)
values
    (
        'enable_soil_aware_irrigation_v2',
        'false'::jsonb,
        'boolean',
        'beta',
        'Soil-Aware Irrigation v2',
        'Use the soil-aware irrigation v2 model: caps single events at readily available water (RAW), suggests split irrigations for sandy/shallow soils, adds urgency (now/soon/monitor/delay), and warns about waterlogging on heavy clay when rain is forecast. When OFF, the v1 descriptive-only soil advice is used.',
        false
    )
on conflict (key) do nothing;
