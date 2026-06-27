-- 060_willyweather_provider.sql
-- Allow 'willyweather' as a vineyard weather integration provider.
-- WillyWeather is used as an optional forecast provider for Australian
-- vineyards. The API key is stored in api_key (server-only via the
-- existing role-aware RPCs); api_secret remains null. station_id stores
-- the WillyWeather location id and station_name stores the location
-- name. station_latitude / station_longitude cache the location coords.
--
-- Nothing else on the integration table changes — the existing
-- SECURITY DEFINER RPCs (get_vineyard_weather_integration,
-- save_vineyard_weather_integration,
-- reveal_vineyard_weather_integration_credentials,
-- delete_vineyard_weather_integration) all accept any text provider.

alter table public.vineyard_weather_integrations
  drop constraint if exists vineyard_weather_integrations_provider_check;

alter table public.vineyard_weather_integrations
  add constraint vineyard_weather_integrations_provider_check
  check (provider in ('davis_weatherlink','wunderground','willyweather'));
