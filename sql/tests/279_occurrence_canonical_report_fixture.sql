-- DISPOSABLE TEST SCHEMA ONLY. Reader-compatible tables, no remote database or historical adoption.
-- Used after 276 bootstrap, before the actual canonical report reader functions.
drop function public.get_spray_report_v1(uuid);
alter table public.vineyards add column name text default 'Fixture vineyard', add column timezone text default 'UTC', add column currency_code text default 'AUD';
alter table public.vineyard_machines add column name text, add column fuel_usage_l_per_hour numeric;
alter table public.tractors add column name text, add column fuel_usage_l_per_hour numeric;
alter table public.worker_types add column cost_per_hour numeric;
alter table public.vineyard_members add column worker_type_id uuid;
create table public.profiles(id uuid primary key, full_name text, email text);
create table public.spray_equipment(id uuid primary key, name text, deleted_at timestamptz);
create table public.fuel_purchases(vineyard_id uuid, deleted_at timestamptz, total_cost numeric, volume_litres numeric);
create table public.trip_cost_allocations(trip_id uuid, deleted_at timestamptz, labour_cost numeric);
create table public.saved_chemicals(id uuid primary key, vineyard_id uuid, deleted_at timestamptz, name text, purchase jsonb);
create table public.spray_jobs(id uuid primary key, name text, status text, planned_date date, operation_type text, target text, notes text);
create table public.spray_records(
 id uuid primary key, trip_id uuid, vineyard_id uuid, deleted_at timestamptz, updated_at timestamptz default now(),
 is_template boolean default false, spray_job_id uuid, machine_id uuid, tractor_id uuid, spray_equipment_id uuid,
 tractor text, equipment_type text, spray_reference text, application_blocks jsonb, tanks jsonb default '[]',
 tractor_gear text, number_of_fans_jets text, average_speed numeric, operation_type text, application_mode text,
 gross_area_ha numeric, treated_area_ha numeric, treated_area_method text, geometry_source text, geometry_quality text,
 carrier_volume_basis text, total_carrier_litres numeric, carrier_litres_per_hectare numeric,
 dilute_litres_per_100m numeric, applied_litres_per_100m numeric, concentration_factor numeric, notes text,
 entry_source text default 'tracked', manual_entry_id uuid, temperature numeric, humidity numeric, wind_speed numeric,
 wind_direction text, start_time timestamptz, date timestamptz
);
create table public.spray_tank_actuals(
 id uuid primary key, trip_id uuid, vineyard_id uuid, spray_record_id uuid, tank_number integer,
 deleted_at timestamptz, client_updated_at timestamptz default now(), correction_version bigint default 1,
 water_volume_l numeric, chemicals jsonb default '[]'
);
create table public.spray_tank_actual_amendments(
 id uuid, operation_id uuid, trip_id uuid, vineyard_id uuid, tank_number integer, chemical_actual_id text,
 planned_chemical_id text, saved_chemical_id uuid, field_name text, change_kind text, previous_value jsonb, new_value jsonb,
 previous_unit text, new_unit text, revision bigint, edited_by uuid, editor_name text, edited_at timestamptz
);
create table public.spray_trip_corrections(
 trip_id uuid, version bigint, machine_id uuid, tractor_id uuid, spray_equipment_id uuid, operator_user_id uuid,
 machine_name_snapshot text, spray_unit_name_snapshot text, operator_name_snapshot text,
 fuel_consumption_l_per_hour numeric, start_engine_hours numeric, end_engine_hours numeric
);
create table public.spray_trip_correction_amendments(
 trip_id uuid, id uuid, operation_id uuid, revision bigint, previous_value jsonb, new_value jsonb,
 edited_by uuid, editor_name text, edited_at timestamptz
);
alter table public.spray_row_assignment_evidence add column row_identity text, add column block_id uuid,
 add column block_name_snapshot text, add column assignment_source text, add column confidence numeric,
 add column tank_number integer, add column tank_session_id text, add column original_evidence jsonb;
create table public.trip_report_assets(
 id uuid primary key, trip_id uuid, bucket text, object_path text, sha256 text, route_hash text, style_version text, created_at timestamptz default now()
);
create table public.trip_weather_observations(
 trip_id uuid, sample_slot timestamptz, observed_at timestamptz, source text, source_kind text, is_stale boolean,
 temperature_c numeric, humidity_pct numeric, wind_speed_kmh numeric, wind_gust_kmh numeric,
 wind_direction_deg numeric, rain_mm numeric, provider text, station_id text, station_name text,
 retrieval_mode text, provider_record_id text, retrieved_at timestamptz
);
create table public.trip_weather_retrieval_attempts(
 trip_id uuid, sample_slot timestamptz, provider text, station_id text, station_name text,
 retrieval_mode text, outcome text, observed_at timestamptz, source text, temperature_c numeric,
 humidity_pct numeric, wind_speed_kmh numeric, wind_gust_kmh numeric, wind_direction_deg numeric,
 rain_mm numeric, is_stale boolean, provider_record_id text, retrieved_at timestamptz
);
