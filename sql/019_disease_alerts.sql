-- 019_disease_alerts.sql
-- Phase 17B: Vineyard disease risk alerts.
--
-- Adds per-vineyard preferences for downy mildew, powdery mildew and
-- botrytis risk alerts. Risk is calculated client-side using forecast
-- humidity, dew point, rainfall and temperature plus an estimated
-- wetness proxy (rain > 0 OR RH >= 90% OR (T - dewPoint) <= 2°C).
--
-- The wetness column is intentionally a *proxy*. The schema reserves
-- room for future measured leaf wetness from an ag-weather provider
-- (override flag) but never stores Weather Underground/Open-Meteo
-- humidity as if it were measured leaf wetness.

alter table public.vineyard_alert_preferences
    add column if not exists disease_alerts_enabled boolean not null default true;

alter table public.vineyard_alert_preferences
    add column if not exists disease_downy_enabled boolean not null default true;

alter table public.vineyard_alert_preferences
    add column if not exists disease_powdery_enabled boolean not null default true;

alter table public.vineyard_alert_preferences
    add column if not exists disease_botrytis_enabled boolean not null default true;

-- When true, the client should prefer measured leaf wetness from an
-- ag-weather provider over the humidity/dew-point proxy. False today
-- (no provider wired up); leaving the column makes it cheap to flip
-- per-vineyard later without another migration.
alter table public.vineyard_alert_preferences
    add column if not exists disease_use_measured_wetness boolean not null default false;
