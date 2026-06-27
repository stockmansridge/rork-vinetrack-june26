-- 074_grape_variety_catalog_expand.sql
--
-- Expands the shared `public.grape_variety_catalog` with a much more
-- complete international list of wine grape varieties, including extra
-- aliases for existing built-ins. Also rewires
--   * public._variety_catalog_keys()
--   * public._variety_catalog_match(text)
-- to read from `grape_variety_catalog` so the SQL repair RPCs (and the
-- iOS/Lovable consumers via RPC) all share one source of truth and new
-- varieties / aliases flow through automatically.
--
-- Idempotent: re-running is safe. All inserts use `on conflict (key)
-- do update` and back-fills use `on conflict do nothing`.

set search_path = public;


-- =========================================================================
-- Seed: expanded built-in catalogue.
--
-- Existing keys (chardonnay … primitivo) are re-upserted with merged
-- aliases (e.g. tempranillo gains `Tinta Roriz`, pinot_gris gains `PG`).
-- New keys are added at the end. Slugs are stable and MUST NOT change.
-- =========================================================================
insert into public.grape_variety_catalog
    (key, canonical_name, display_name, aliases, optimal_gdd, is_builtin, is_active)
values
    -- ---- existing built-ins (alias merges) ---------------------------------
    ('chardonnay',          'Chardonnay',           'Chardonnay',            '[]'::jsonb,                                                                          1145, true, true),
    ('pinot_gris',          'Pinot Gris',           'Pinot Gris / Grigio',   '["Pinot Gris","Pinot Grigio","Pinot Gris / Grigio","PG","Grauburgunder","Ruländer"]'::jsonb, 1100, true, true),
    ('riesling',            'Riesling',             'Riesling',              '["Johannisberg Riesling","White Riesling"]'::jsonb,                                  1200, true, true),
    ('sauvignon_blanc',     'Sauvignon Blanc',      'Sauvignon Blanc',       '["Sauv Blanc","Sav Blanc","Savvy B","Fumé Blanc","Fume Blanc"]'::jsonb,             1150, true, true),
    ('semillon',            'Semillon',             'Semillon',              '["Sémillon"]'::jsonb,                                                                1200, true, true),
    ('chenin_blanc',        'Chenin Blanc',         'Chenin Blanc',          '["Steen","Pineau de la Loire"]'::jsonb,                                              1250, true, true),
    ('gewurztraminer',      'Gewurztraminer',       'Gewurztraminer',        '["Gewürztraminer","Traminer Aromatico"]'::jsonb,                                     1150, true, true),
    ('viognier',            'Viognier',             'Viognier',              '[]'::jsonb,                                                                          1260, true, true),
    ('shiraz',              'Shiraz',               'Shiraz / Syrah',        '["Syrah","Shiraz"]'::jsonb,                                                          1255, true, true),
    ('merlot',              'Merlot',               'Merlot',                '[]'::jsonb,                                                                          1250, true, true),
    ('cabernet_franc',      'Cabernet Franc',       'Cabernet Franc',        '["Cab Franc","Bouchet"]'::jsonb,                                                     1255, true, true),
    ('cabernet_sauvignon',  'Cabernet Sauvignon',   'Cabernet Sauvignon',    '["Cab Sav","Cab Sauv","Cab"]'::jsonb,                                                1310, true, true),
    ('pinot_noir',          'Pinot Noir',           'Pinot Noir',            '["Spätburgunder","Pinot Nero","Blauburgunder"]'::jsonb,                              1145, true, true),
    ('tempranillo',         'Tempranillo',          'Tempranillo',           '["Tinta Roriz","Aragonez","Tinto Fino","Cencibel"]'::jsonb,                          1230, true, true),
    ('sangiovese',          'Sangiovese',           'Sangiovese',            '["Brunello"]'::jsonb,                                                                1285, true, true),
    ('grenache',            'Grenache',             'Grenache / Garnacha',   '["Garnacha","Cannonau","Grenache Noir"]'::jsonb,                                     1365, true, true),
    ('mataro_mourvedre',    'Mataro / Mourvedre',   'Mataro / Mourvedre',    '["Mataro","Mourvedre","Mourvèdre","Monastrell"]'::jsonb,                             1440, true, true),
    ('barbera',             'Barbera',              'Barbera',               '[]'::jsonb,                                                                          1285, true, true),
    ('malbec',              'Malbec',               'Malbec',                '["Cot","Côt","Auxerrois"]'::jsonb,                                                   1230, true, true),
    ('colombard',           'Colombard',            'Colombard',             '["French Colombard"]'::jsonb,                                                        1300, true, true),
    ('muscat_gordo_blanco', 'Muscat Gordo Blanco',  'Muscat Gordo Blanco',   '["Muscat Gordo","Muscat of Alexandria","Moscatel de Alejandría"]'::jsonb,             1350, true, true),
    ('fiano',               'Fiano',                'Fiano',                 '[]'::jsonb,                                                                          1320, true, true),
    ('prosecco',            'Prosecco',             'Prosecco / Glera',      '["Glera","Prosecco"]'::jsonb,                                                        1410, true, true),
    ('vermentino',          'Vermentino',           'Vermentino',            '["Rolle","Pigato"]'::jsonb,                                                          1290, true, true),
    ('gruner_veltliner',    'Gruner Veltliner',     'Gruner Veltliner',      '["Grüner Veltliner","Gruner","GV"]'::jsonb,                                          1200, true, true),
    ('primitivo',           'Primitivo',            'Primitivo / Zinfandel', '["Zinfandel","Zin","Crljenak Kaštelanski"]'::jsonb,                                  1200, true, true),

    -- ---- new whites --------------------------------------------------------
    ('albarino',            'Albarino',             'Albariño',              '["Albarino","Alvarinho"]'::jsonb,                                                    1250, true, true),
    ('arneis',              'Arneis',               'Arneis',                '[]'::jsonb,                                                                          1280, true, true),
    ('chasselas',           'Chasselas',            'Chasselas',             '["Gutedel","Fendant"]'::jsonb,                                                       1150, true, true),
    ('marsanne',            'Marsanne',             'Marsanne',              '[]'::jsonb,                                                                          1290, true, true),
    ('muscadelle',          'Muscadelle',           'Muscadelle',            '[]'::jsonb,                                                                          1250, true, true),
    ('muscat_blanc',        'Muscat Blanc',         'Muscat Blanc',          '["Muscat Blanc à Petits Grains","Muscat Blanc a Petits Grains","Moscato Bianco","Moscato","Muscat Canelli"]'::jsonb, 1280, true, true),
    ('palomino',            'Palomino',             'Palomino',              '["Palomino Fino","Listán Blanco","Listan Blanco"]'::jsonb,                           1300, true, true),
    ('pedro_ximenez',       'Pedro Ximenez',        'Pedro Ximénez',         '["PX","Pedro Ximenez"]'::jsonb,                                                      1320, true, true),
    ('picpoul',             'Picpoul',              'Picpoul / Piquepoul',   '["Piquepoul","Picpoul Blanc","Piquepoul Blanc"]'::jsonb,                             1250, true, true),
    ('pinot_blanc',         'Pinot Blanc',          'Pinot Blanc',           '["Weissburgunder","Weißburgunder","Pinot Bianco"]'::jsonb,                           1150, true, true),
    ('roussanne',           'Roussanne',            'Roussanne',             '[]'::jsonb,                                                                          1300, true, true),
    ('trebbiano',           'Trebbiano',            'Trebbiano / Ugni Blanc','["Ugni Blanc","Trebbiano Toscano","St-Emilion"]'::jsonb,                              1290, true, true),
    ('verdejo',             'Verdejo',              'Verdejo',               '[]'::jsonb,                                                                          1260, true, true),
    ('verdelho',            'Verdelho',             'Verdelho',              '["Verdello"]'::jsonb,                                                                1280, true, true),

    -- ---- new reds ----------------------------------------------------------
    ('aglianico',           'Aglianico',            'Aglianico',             '[]'::jsonb,                                                                          1400, true, true),
    ('carmenere',           'Carmenere',            'Carmenère',             '["Carmenere","Grande Vidure"]'::jsonb,                                               1370, true, true),
    ('cinsault',            'Cinsault',             'Cinsault',              '["Cinsaut"]'::jsonb,                                                                 1350, true, true),
    ('dolcetto',            'Dolcetto',             'Dolcetto',              '[]'::jsonb,                                                                          1230, true, true),
    ('gamay',               'Gamay',                'Gamay',                 '["Gamay Noir","Gamay Noir à Jus Blanc"]'::jsonb,                                     1100, true, true),
    ('montepulciano',       'Montepulciano',        'Montepulciano',         '[]'::jsonb,                                                                          1380, true, true),
    ('nebbiolo',            'Nebbiolo',             'Nebbiolo',              '["Spanna","Chiavennasca","Picotendro"]'::jsonb,                                      1410, true, true),
    ('nero_davola',         'Nero d''Avola',        'Nero d''Avola',         '["Nero dAvola","Nero d Avola","Calabrese"]'::jsonb,                                  1420, true, true),
    ('petit_verdot',        'Petit Verdot',         'Petit Verdot',          '[]'::jsonb,                                                                          1390, true, true),
    ('petite_sirah',        'Petite Sirah',         'Petite Sirah / Durif',  '["Durif","Petite Syrah","Petite Sirah"]'::jsonb,                                     1390, true, true),
    ('pinot_meunier',       'Pinot Meunier',        'Pinot Meunier',         '["Meunier","Schwarzriesling"]'::jsonb,                                               1100, true, true),
    ('touriga_nacional',    'Touriga Nacional',     'Touriga Nacional',      '[]'::jsonb,                                                                          1380, true, true),
    ('zweigelt',            'Zweigelt',             'Zweigelt',              '["Blauer Zweigelt","Rotburger"]'::jsonb,                                             1180, true, true),

    -- ---- emerging / Australian / other useful ------------------------------
    ('assyrtiko',           'Assyrtiko',            'Assyrtiko',             '[]'::jsonb,                                                                          1320, true, true),
    ('chambourcin',         'Chambourcin',          'Chambourcin',           '[]'::jsonb,                                                                          1280, true, true),
    ('furmint',             'Furmint',              'Furmint',               '[]'::jsonb,                                                                          1280, true, true),
    ('lagrein',             'Lagrein',              'Lagrein',               '[]'::jsonb,                                                                          1350, true, true),
    ('mencia',              'Mencia',               'Mencía',                '["Mencia","Jaen"]'::jsonb,                                                           1300, true, true),
    ('savagnin',            'Savagnin',             'Savagnin',              '["Traminer","Heida","Païen"]'::jsonb,                                                1200, true, true),
    ('tannat',              'Tannat',               'Tannat',                '[]'::jsonb,                                                                          1430, true, true)

on conflict (key) do update
    set canonical_name = excluded.canonical_name,
        display_name   = excluded.display_name,
        aliases        = excluded.aliases,
        optimal_gdd    = coalesce(excluded.optimal_gdd, public.grape_variety_catalog.optimal_gdd),
        is_builtin     = true,
        is_active      = true,
        updated_at     = now();


-- =========================================================================
-- Rewire helpers to read from grape_variety_catalog. Keeps SQL repair
-- RPCs and consumer RPCs in sync with the table without further code
-- changes when new built-ins are added.
-- =========================================================================
create or replace function public._variety_catalog_keys()
returns table(key text, display_name text)
language sql
stable
as $$
    select c.key, c.display_name
      from public.grape_variety_catalog c
     where c.is_active = true
       and c.is_builtin = true;
$$;

grant execute on function public._variety_catalog_keys() to authenticated;


create or replace function public._variety_catalog_match(p_name text)
returns table(key text, display_name text, optimal_gdd numeric)
language sql
stable
as $$
    with expanded as (
        select c.key, c.display_name, c.optimal_gdd,
               public._variety_canonical(c.canonical_name) as cname
          from public.grape_variety_catalog c
         where c.is_active = true and c.is_builtin = true
        union all
        select c.key, c.display_name, c.optimal_gdd,
               public._variety_canonical(c.display_name) as cname
          from public.grape_variety_catalog c
         where c.is_active = true and c.is_builtin = true
        union all
        select c.key, c.display_name, c.optimal_gdd,
               public._variety_canonical(alias.value) as cname
          from public.grape_variety_catalog c
          cross join lateral jsonb_array_elements_text(coalesce(c.aliases, '[]'::jsonb)) as alias(value)
         where c.is_active = true and c.is_builtin = true
    )
    select key, display_name, optimal_gdd
      from expanded
     where cname is not null
       and cname <> ''
       and cname = public._variety_canonical(p_name)
     limit 1;
$$;

grant execute on function public._variety_catalog_match(text) to authenticated;


-- =========================================================================
-- Backfill: every active vineyard receives all new built-ins in
-- `vineyard_grape_varieties`. Existing rows (including any vineyard
-- customs) are untouched thanks to the unique (vineyard_id, variety_key)
-- constraint.
-- =========================================================================
insert into public.vineyard_grape_varieties
    (vineyard_id, variety_key, display_name, is_custom, is_active, optimal_gdd_override)
select v.id, c.key, c.display_name, false, true, null
  from public.vineyards v
  cross join public.grape_variety_catalog c
 where v.deleted_at is null
   and c.is_builtin = true
   and c.is_active  = true
on conflict (vineyard_id, variety_key) do nothing;
