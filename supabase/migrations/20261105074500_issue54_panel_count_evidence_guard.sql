-- Issue #54: validate only newly introduced Panel Count yield evidence.
-- Existing per-vine, Quadrant, spraying and Trip records take the no-op path.
CREATE FUNCTION public.guard_yield_panel_count_evidence()
RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE
  is_panel boolean;
  old_panel boolean := false;
  item jsonb;
  raw jsonb;
  m jsonb;
  total_bunches numeric;
  planted numeric;
  fruiting numeric;
  missing numeric;
  nonproductive numeric;
  length_m numeric;
  recorded_panels integer := 0;
BEGIN
  is_panel := coalesce(NEW.payload->>'countMethod' = 'panel', false)
      OR jsonb_path_exists(coalesce(NEW.payload, '{}'::jsonb), '$.sampleSites[*].panelCountEntry ? (@ != null)');
  IF TG_OP = 'UPDATE' THEN
    old_panel := coalesce(OLD.payload->>'countMethod' = 'panel', false)
       OR jsonb_path_exists(coalesce(OLD.payload, '{}'::jsonb), '$.sampleSites[*].panelCountEntry ? (@ != null)');
    -- A confirmed, sampled location-set reference is provenance; a client
    -- that cannot round-trip it must not erase it from a locked observation.
    IF (OLD.is_completed OR jsonb_path_exists(coalesce(OLD.payload, '{}'::jsonb),
          '$.sampleSites[*] ? (@.bunchCountEntry != null || @.panelCountEntry != null)'))
       AND coalesce(OLD.payload->'siteSetVersions','{}'::jsonb) <> '{}'::jsonb
       AND coalesce(NEW.payload->'siteSetVersions','{}'::jsonb)
           IS DISTINCT FROM OLD.payload->'siteSetVersions' THEN
      RAISE EXCEPTION 'Confirmed yield sampling site-set snapshot cannot be removed or replaced on a recorded session'
        USING ERRCODE = '23514';
    END IF;
    IF old_panel AND NEW.payload->>'countMethod' IS DISTINCT FROM 'panel' THEN
      RAISE EXCEPTION 'Panel Count method cannot be stripped from an existing session'
        USING ERRCODE = '23514';
    END IF;
    IF old_panel AND OLD.is_completed AND (
       NEW.payload IS DISTINCT FROM OLD.payload
       OR NEW.is_completed IS DISTINCT FROM OLD.is_completed
       OR NEW.completed_at IS DISTINCT FROM OLD.completed_at
    ) THEN
      RAISE EXCEPTION 'Completed raw Panel Count evidence is immutable' USING ERRCODE = '23514';
    END IF;
  END IF;

  IF NOT (is_panel OR old_panel) THEN RETURN NEW; END IF;

  IF NEW.payload->>'countMethod' IS DISTINCT FROM 'panel' THEN
    RAISE EXCEPTION 'Panel Count metadata is required for every panel observation'
      USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(NEW.payload->'sampleSites') NOT IN ('array') THEN
    -- Empty drafts from a client may omit the default empty array, but
    -- they may not be marked completed without a recorded panel.
    IF NEW.is_completed THEN
      RAISE EXCEPTION 'Completed Panel Count requires an array of recorded samples'
        USING ERRCODE = '22023';
    END IF;
    RETURN NEW;
  END IF;

  FOR item IN SELECT value FROM jsonb_array_elements(NEW.payload->'sampleSites') LOOP
    raw := item->'panelCountEntry';
    IF item->'bunchCountEntry' IS NOT NULL
        AND item->'bunchCountEntry' <> 'null'::jsonb THEN
      RAISE EXCEPTION 'Panel Count cannot mix per-vine or Quadrant measurements'
        USING ERRCODE = '22023';
    END IF;
    IF raw IS NULL OR raw = 'null'::jsonb THEN CONTINUE; END IF;
    m := raw->'measurement';
    IF jsonb_typeof(m) IS DISTINCT FROM 'object'
       OR jsonb_typeof(m->'totalBunches') IS DISTINCT FROM 'number'
       OR jsonb_typeof(m->'plantedPositions') IS DISTINCT FROM 'number'
       OR jsonb_typeof(m->'fruitingVines') IS DISTINCT FROM 'number'
       OR jsonb_typeof(m->'missingPositions') IS DISTINCT FROM 'number'
       OR jsonb_typeof(m->'nonproductiveVines') IS DISTINCT FROM 'number'
       OR m->>'calculationVersion' IS DISTINCT FROM '1' THEN
      RAISE EXCEPTION 'Panel Count requires all five raw integer measurements and calculation version one'
        USING ERRCODE = '22023';
    END IF;

    total_bunches := (m->>'totalBunches')::numeric;
    planted := (m->>'plantedPositions')::numeric;
    fruiting := (m->>'fruitingVines')::numeric;
    missing := (m->>'missingPositions')::numeric;
    nonproductive := (m->>'nonproductiveVines')::numeric;
    IF total_bunches < 0 OR total_bunches <> trunc(total_bunches)
       OR total_bunches > 2147483647
       OR planted <= 0 OR planted > 2147483647 OR planted <> trunc(planted)
       OR fruiting < 0 OR fruiting <> trunc(fruiting)
       OR missing < 0 OR missing <> trunc(missing)
       OR nonproductive < 0 OR nonproductive <> trunc(nonproductive)
       OR fruiting + missing + nonproductive <> planted THEN
      RAISE EXCEPTION 'Invalid post-to-post panel positions or bunch totals'
        USING ERRCODE = '22023';
    END IF;
    IF m->'panelLengthMetres' IS NOT NULL
       AND m->'panelLengthMetres' <> 'null'::jsonb THEN
      IF jsonb_typeof(m->'panelLengthMetres') IS DISTINCT FROM 'number' THEN
        RAISE EXCEPTION 'Panel length must be numerical or omitted' USING ERRCODE = '22023';
      END IF;
      length_m := (m->>'panelLengthMetres')::numeric;
      IF length_m <= 0 THEN
        RAISE EXCEPTION 'Panel length must be positive' USING ERRCODE = '22023';
      END IF;
    END IF;
    recorded_panels := recorded_panels + 1;
  END LOOP;
  IF NEW.is_completed AND recorded_panels = 0 THEN
    RAISE EXCEPTION 'Completed Panel Count requires at least one recorded post-to-post panel'
      USING ERRCODE = '22023';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER yield_panel_count_evidence_guard
  BEFORE INSERT OR UPDATE ON public.yield_estimation_sessions
  FOR EACH ROW EXECUTE FUNCTION public.guard_yield_panel_count_evidence();

REVOKE ALL ON FUNCTION public.guard_yield_panel_count_evidence() FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public.guard_yield_panel_count_evidence() IS
  'Issue54 validates panel raw evidence, protects immutable completed panel sessions and recorded permanent site-source snapshots. No effects for legacy yield and other workflows.';
