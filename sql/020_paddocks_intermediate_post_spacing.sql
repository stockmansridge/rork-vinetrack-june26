-- Add intermediate post spacing (meters) to paddocks for trellis post counting.
alter table public.paddocks
  add column if not exists intermediate_post_spacing double precision null;
