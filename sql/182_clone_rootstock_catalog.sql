-- 182_clone_rootstock_catalog.sql
--
-- Shared Clone + Rootstock catalogues, mirroring the grape variety
-- catalogue architecture from sql/073.
--
-- Architecture
-- ============
--   public.grape_clone_catalog      -- global built-in CLONE catalogue.
--                                      Every clone belongs to ONE grape
--                                      variety (variety_key).
--   public.vineyard_grape_clones    -- vineyard-scoped CUSTOM clones.
--   public.rootstock_catalog        -- global built-in ROOTSTOCK catalogue.
--                                      Rootstocks are INDEPENDENT of scion
--                                      variety (no variety -> rootstock link).
--   public.vineyard_rootstocks      -- vineyard-scoped CUSTOM rootstocks.
--
--   iOS / Android / Lovable are CONSUMERS: they read via RPCs, cache
--   locally, and fall back to a bundled copy when Supabase is unreachable.
--
-- Stable keys
-- ===========
--   * Built-in clone keys embed the owning variety and are immutable:
--       `shiraz:pt23`, `chardonnay:bernard_95`, `pinot_noir:mv6`.
--   * Built-in rootstock keys: `1103_paulsen`, `101_14`, `ramsey`, ...
--   * Custom clone keys:    `custom:<vineyard_id>:<variety_slug>:<slug>`
--   * Custom rootstock keys:`custom:<vineyard_id>:<slug>`
--   * Never identify records by display text — display names may gain
--     aliases/corrections over time; keys never change.
--
-- Selection-system identity
-- =========================
--   A clone/selection number is only meaningful WITH its selection system:
--   FPS 07 (UC Davis) and ENTAV-INRA 07 are NOT the same plant material.
--   `clone_code` + `selection_system` + `source_country` are therefore
--   preserved separately and must never be collapsed by visible number.
--
-- Block allocation contract (paddocks.variety_allocations JSONB)
-- ==============================================================
--   Each allocation element MAY carry (all optional, additive to sql/072):
--     "cloneKey":     stable key from grape_clone_catalog.key or
--                     vineyard_grape_clones.clone_key, OR the reserved
--                     sentinel 'mass_selection'. Absent/null = clone not
--                     specified / unknown.
--     "clone":        display-string snapshot (kept for legacy rows,
--                     sql/180 picking log, and human-readable exports).
--     "rootstockKey": stable key from rootstock_catalog.key or
--                     vineyard_rootstocks.rootstock_key, OR the reserved
--                     sentinel 'own_roots'. Absent/null = not recorded.
--     "rootstock":    display-string snapshot (same role as "clone").
--
--   Sentinels are DELIBERATELY not catalogue rows:
--     'mass_selection' -> vines propagated by mass selection (no certified
--                          clone identity).
--     'own_roots'      -> ungrafted / own-rooted vines (not a biological
--                          rootstock).
--   Legacy allocations that carry only free-text "clone"/"rootstock" stay
--   valid forever; clients preserve the text and never silently map
--   ambiguous text onto a catalogue record.
--
--   A block may hold MULTIPLE allocations of the SAME variety with
--   different clone/rootstock (e.g. 50% Shiraz PT23 on 1103 Paulsen +
--   50% Shiraz BVRC12 on Ramsey). Clients must NOT merge allocations of
--   the same variety.
--
-- Seed sources (source_reference column)
-- ======================================
--   * SARDI 'Grapevine clones used in Australia' (Nicholas, 2006)
--   * Barossa Vine Improvement Shiraz clones dossier (2022)
--   * AWRI / Yalumba Nursery Chardonnay clone timeline (Dry)
--   * ENTAV-INRA authorised clone catalogue
--   * FPS UC Davis Foundation Plant Services registered selections
--   * Geisenheim Institute clone register
--   * Rootstocks: Wine Australia / AWRI rootstock references;
--     CSIRO Merbein series
--
-- This migration is idempotent. Re-running it is safe. Re-seeding updates
-- display metadata/aliases of built-ins but never touches custom rows and
-- never changes a key.

set search_path = public;


-- =========================================================================
-- Table: public.grape_clone_catalog (global built-in clones)
-- =========================================================================
create table if not exists public.grape_clone_catalog (
    key              text primary key,
    variety_key      text not null,
    display_name     text not null,
    clone_code       text not null,
    selection_system text,
    source_country   text,
    aliases          jsonb not null default '[]'::jsonb,
    source_reference text,
    is_builtin       boolean not null default true,
    is_active        boolean not null default true,
    created_at       timestamptz not null default now(),
    updated_at       timestamptz not null default now()
);

create index if not exists grape_clone_catalog_variety_idx
    on public.grape_clone_catalog (variety_key, is_active);


-- =========================================================================
-- Table: public.vineyard_grape_clones (vineyard-scoped custom clones)
-- =========================================================================
create table if not exists public.vineyard_grape_clones (
    id           uuid primary key default gen_random_uuid(),
    vineyard_id  uuid not null references public.vineyards(id) on delete cascade,
    clone_key    text not null,
    variety_key  text not null,
    display_name text not null,
    is_custom    boolean not null default true,
    is_active    boolean not null default true,
    created_at   timestamptz not null default now(),
    updated_at   timestamptz not null default now(),
    unique (vineyard_id, clone_key)
);

create index if not exists vineyard_grape_clones_vineyard_idx
    on public.vineyard_grape_clones (vineyard_id, is_active);

create index if not exists vineyard_grape_clones_variety_idx
    on public.vineyard_grape_clones (vineyard_id, variety_key, is_active);


-- =========================================================================
-- Table: public.rootstock_catalog (global built-in rootstocks)
-- =========================================================================
create table if not exists public.rootstock_catalog (
    key              text primary key,
    canonical_name   text not null,
    display_name     text not null,
    aliases          jsonb not null default '[]'::jsonb,
    parentage        text,
    source_reference text,
    is_builtin       boolean not null default true,
    is_active        boolean not null default true,
    created_at       timestamptz not null default now(),
    updated_at       timestamptz not null default now()
);

create index if not exists rootstock_catalog_active_idx
    on public.rootstock_catalog (is_active);


-- =========================================================================
-- Table: public.vineyard_rootstocks (vineyard-scoped custom rootstocks)
-- =========================================================================
create table if not exists public.vineyard_rootstocks (
    id            uuid primary key default gen_random_uuid(),
    vineyard_id   uuid not null references public.vineyards(id) on delete cascade,
    rootstock_key text not null,
    display_name  text not null,
    is_custom     boolean not null default true,
    is_active     boolean not null default true,
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now(),
    unique (vineyard_id, rootstock_key)
);

create index if not exists vineyard_rootstocks_vineyard_idx
    on public.vineyard_rootstocks (vineyard_id, is_active);


-- =========================================================================
-- updated_at triggers (reuse the sql/073 touch function)
-- =========================================================================
drop trigger if exists trg_grape_clone_catalog_touch on public.grape_clone_catalog;
create trigger trg_grape_clone_catalog_touch
    before update on public.grape_clone_catalog
    for each row execute function public._grape_variety_catalog_touch();

drop trigger if exists trg_vineyard_grape_clones_touch on public.vineyard_grape_clones;
create trigger trg_vineyard_grape_clones_touch
    before update on public.vineyard_grape_clones
    for each row execute function public._grape_variety_catalog_touch();

drop trigger if exists trg_rootstock_catalog_touch on public.rootstock_catalog;
create trigger trg_rootstock_catalog_touch
    before update on public.rootstock_catalog
    for each row execute function public._grape_variety_catalog_touch();

drop trigger if exists trg_vineyard_rootstocks_touch on public.vineyard_rootstocks;
create trigger trg_vineyard_rootstocks_touch
    before update on public.vineyard_rootstocks
    for each row execute function public._grape_variety_catalog_touch();


-- =========================================================================
-- Seed: built-in clone catalogue (curated, source-attributed)
-- =========================================================================
insert into public.grape_clone_catalog
    (key, variety_key, display_name, clone_code, selection_system, source_country, aliases, source_reference, is_builtin, is_active)
values
    -- Chardonnay — AWRI/Yalumba clone timeline; SARDI 2006
    ('chardonnay:gin_gin',    'chardonnay', 'Gin Gin',        'Gin Gin', 'Australian selection', 'Australia', '["Gingin"]'::jsonb,               'AWRI/Yalumba Nursery Chardonnay clone timeline; SARDI 2006', true, true),
    ('chardonnay:mendoza',    'chardonnay', 'Mendoza',        'Mendoza', 'Australian selection', 'Australia', '["C2V16","FPS 01A"]'::jsonb,       'AWRI/Yalumba Nursery Chardonnay clone timeline; SARDI 2006', true, true),
    ('chardonnay:i10v1',      'chardonnay', 'I10V1',          'I10V1',   'Australian selection', 'Australia', '["FPS 06"]'::jsonb,                'AWRI/Yalumba Nursery Chardonnay clone timeline; SARDI 2006', true, true),
    ('chardonnay:i10v5',      'chardonnay', 'I10V5',          'I10V5',   'Australian selection', 'Australia', '["FPS 08"]'::jsonb,                'AWRI/Yalumba Nursery Chardonnay clone timeline; SARDI 2006', true, true),
    ('chardonnay:p58',        'chardonnay', 'P58',            'P58',     'Australian selection', 'Australia', '["Penfolds 58"]'::jsonb,           'SARDI 2006', true, true),
    ('chardonnay:entav_76',   'chardonnay', 'ENTAV-INRA 76',  '76',      'ENTAV-INRA',           'France',    '["Bernard 76","Dijon 76"]'::jsonb, 'ENTAV-INRA authorised clone catalogue', true, true),
    ('chardonnay:entav_95',   'chardonnay', 'ENTAV-INRA 95',  '95',      'ENTAV-INRA',           'France',    '["Bernard 95","Dijon 95"]'::jsonb, 'ENTAV-INRA authorised clone catalogue', true, true),
    ('chardonnay:entav_96',   'chardonnay', 'ENTAV-INRA 96',  '96',      'ENTAV-INRA',           'France',    '["Bernard 96","Dijon 96"]'::jsonb, 'ENTAV-INRA authorised clone catalogue', true, true),
    ('chardonnay:entav_277',  'chardonnay', 'ENTAV-INRA 277', '277',     'ENTAV-INRA',           'France',    '["Bernard 277","Dijon 277"]'::jsonb, 'ENTAV-INRA authorised clone catalogue', true, true),
    ('chardonnay:entav_548',  'chardonnay', 'ENTAV-INRA 548', '548',     'ENTAV-INRA',           'France',    '[]'::jsonb,                        'ENTAV-INRA authorised clone catalogue', true, true),
    ('chardonnay:entav_809',  'chardonnay', 'ENTAV-INRA 809', '809',     'ENTAV-INRA',           'France',    '[]'::jsonb,                        'ENTAV-INRA authorised clone catalogue', true, true),
    ('chardonnay:entav_1066', 'chardonnay', 'ENTAV-INRA 1066','1066',    'ENTAV-INRA',           'France',    '[]'::jsonb,                        'ENTAV-INRA authorised clone catalogue', true, true),

    -- Shiraz — Barossa Vine Improvement dossier 2022; SARDI 2006
    ('shiraz:pt23',      'shiraz', 'PT23',           'PT23',   'Australian selection', 'Australia', '["PT 23"]'::jsonb,     'Barossa Vine Improvement Shiraz clones dossier (2022); SARDI 2006', true, true),
    ('shiraz:1654',      'shiraz', '1654',           '1654',   'Australian selection', 'Australia', '[]'::jsonb,            'Barossa Vine Improvement Shiraz clones dossier (2022); SARDI 2006', true, true),
    ('shiraz:bvrc12',    'shiraz', 'BVRC12',         'BVRC12', 'Australian selection', 'Australia', '["BVRC 12"]'::jsonb,   'Barossa Vine Improvement Shiraz clones dossier (2022)', true, true),
    ('shiraz:bvrc30',    'shiraz', 'BVRC30',         'BVRC30', 'Australian selection', 'Australia', '["BVRC 30"]'::jsonb,   'Barossa Vine Improvement Shiraz clones dossier (2022)', true, true),
    ('shiraz:entav_174', 'shiraz', 'ENTAV-INRA 174', '174',    'ENTAV-INRA',           'France',    '[]'::jsonb,            'ENTAV-INRA authorised clone catalogue (Syrah)', true, true),
    ('shiraz:entav_300', 'shiraz', 'ENTAV-INRA 300', '300',    'ENTAV-INRA',           'France',    '[]'::jsonb,            'ENTAV-INRA authorised clone catalogue (Syrah)', true, true),
    ('shiraz:entav_470', 'shiraz', 'ENTAV-INRA 470', '470',    'ENTAV-INRA',           'France',    '[]'::jsonb,            'ENTAV-INRA authorised clone catalogue (Syrah)', true, true),
    ('shiraz:entav_524', 'shiraz', 'ENTAV-INRA 524', '524',    'ENTAV-INRA',           'France',    '[]'::jsonb,            'ENTAV-INRA authorised clone catalogue (Syrah)', true, true),
    ('shiraz:fps_01',    'shiraz', 'FPS 01',         'FPS 01', 'FPS (UC Davis)',       'USA',       '[]'::jsonb,            'FPS UC Davis Foundation Plant Services (Syrah)', true, true),
    ('shiraz:fps_07',    'shiraz', 'FPS 07',         'FPS 07', 'FPS (UC Davis)',       'USA',       '[]'::jsonb,            'FPS UC Davis Foundation Plant Services (Syrah)', true, true),

    -- Pinot Noir — SARDI 2006; ENTAV; FPS
    ('pinot_noir:mv6',       'pinot_noir', 'MV6',            'MV6',     'Australian selection', 'Australia', '["MV 6"]'::jsonb,            'SARDI 2006 (Busby-era selection)', true, true),
    ('pinot_noir:d5v12',     'pinot_noir', 'D5V12',          'D5V12',   'Australian selection', 'Australia', '[]'::jsonb,                  'SARDI 2006', true, true),
    ('pinot_noir:d2v5',      'pinot_noir', 'D2V5',           'D2V5',    'Australian selection', 'Australia', '[]'::jsonb,                  'SARDI 2006', true, true),
    ('pinot_noir:g5v15',     'pinot_noir', 'G5V15',          'G5V15',   'Australian selection', 'Australia', '[]'::jsonb,                  'SARDI 2006', true, true),
    ('pinot_noir:g8v3',      'pinot_noir', 'G8V3',           'G8V3',    'Australian selection', 'Australia', '[]'::jsonb,                  'SARDI 2006', true, true),
    ('pinot_noir:entav_114', 'pinot_noir', 'ENTAV-INRA 114', '114',     'ENTAV-INRA',           'France',    '["Dijon 114"]'::jsonb,       'ENTAV-INRA authorised clone catalogue', true, true),
    ('pinot_noir:entav_115', 'pinot_noir', 'ENTAV-INRA 115', '115',     'ENTAV-INRA',           'France',    '["Dijon 115"]'::jsonb,       'ENTAV-INRA authorised clone catalogue', true, true),
    ('pinot_noir:entav_667', 'pinot_noir', 'ENTAV-INRA 667', '667',     'ENTAV-INRA',           'France',    '["Dijon 667"]'::jsonb,       'ENTAV-INRA authorised clone catalogue', true, true),
    ('pinot_noir:entav_777', 'pinot_noir', 'ENTAV-INRA 777', '777',     'ENTAV-INRA',           'France',    '["Dijon 777"]'::jsonb,       'ENTAV-INRA authorised clone catalogue', true, true),
    ('pinot_noir:entav_828', 'pinot_noir', 'ENTAV-INRA 828', '828',     'ENTAV-INRA',           'France',    '["Dijon 828"]'::jsonb,       'ENTAV-INRA authorised clone catalogue', true, true),
    ('pinot_noir:entav_943', 'pinot_noir', 'ENTAV-INRA 943', '943',     'ENTAV-INRA',           'France',    '["Dijon 943"]'::jsonb,       'ENTAV-INRA authorised clone catalogue', true, true),
    ('pinot_noir:pommard',   'pinot_noir', 'Pommard',        'Pommard', 'FPS (UC Davis)',       'USA',       '["UCD 4","Pommard 4"]'::jsonb, 'FPS UC Davis Foundation Plant Services', true, true),
    ('pinot_noir:abel',      'pinot_noir', 'Abel',           'Abel',    'New Zealand selection','New Zealand','["Gumboot","Ata Rangi"]'::jsonb, 'New Zealand industry selection', true, true),

    -- Cabernet Sauvignon — Yalumba Nursery; SARDI 2006; ENTAV; FPS
    ('cabernet_sauvignon:sa125',     'cabernet_sauvignon', 'SA125',          'SA125',  'Australian selection', 'Australia', '["SA 125"]'::jsonb, 'Yalumba Nursery varieties+clones register; SARDI 2006', true, true),
    ('cabernet_sauvignon:g9v3',      'cabernet_sauvignon', 'G9V3',           'G9V3',   'Australian selection', 'Australia', '[]'::jsonb,         'SARDI 2006', true, true),
    ('cabernet_sauvignon:cw44',      'cabernet_sauvignon', 'CW44',           'CW44',   'Australian selection', 'Australia', '[]'::jsonb,         'SARDI 2006', true, true),
    ('cabernet_sauvignon:lc10',      'cabernet_sauvignon', 'LC10',           'LC10',   'Australian selection', 'Australia', '["Reynella"]'::jsonb, 'SARDI 2006', true, true),
    ('cabernet_sauvignon:entav_169', 'cabernet_sauvignon', 'ENTAV-INRA 169', '169',    'ENTAV-INRA',           'France',    '[]'::jsonb,         'ENTAV-INRA authorised clone catalogue', true, true),
    ('cabernet_sauvignon:entav_191', 'cabernet_sauvignon', 'ENTAV-INRA 191', '191',    'ENTAV-INRA',           'France',    '[]'::jsonb,         'ENTAV-INRA authorised clone catalogue', true, true),
    ('cabernet_sauvignon:entav_337', 'cabernet_sauvignon', 'ENTAV-INRA 337', '337',    'ENTAV-INRA',           'France',    '[]'::jsonb,         'ENTAV-INRA authorised clone catalogue', true, true),
    ('cabernet_sauvignon:entav_412', 'cabernet_sauvignon', 'ENTAV-INRA 412', '412',    'ENTAV-INRA',           'France',    '[]'::jsonb,         'ENTAV-INRA authorised clone catalogue', true, true),
    ('cabernet_sauvignon:fps_07',    'cabernet_sauvignon', 'FPS 07',         'FPS 07', 'FPS (UC Davis)',       'USA',       '[]'::jsonb,         'FPS UC Davis Foundation Plant Services', true, true),
    ('cabernet_sauvignon:fps_08',    'cabernet_sauvignon', 'FPS 08',         'FPS 08', 'FPS (UC Davis)',       'USA',       '[]'::jsonb,         'FPS UC Davis Foundation Plant Services', true, true),

    -- Sauvignon Blanc
    ('sauvignon_blanc:f4v6',      'sauvignon_blanc', 'F4V6',           'F4V6',   'Australian selection', 'Australia', '[]'::jsonb, 'SARDI 2006', true, true),
    ('sauvignon_blanc:f7v7',      'sauvignon_blanc', 'F7V7',           'F7V7',   'Australian selection', 'Australia', '[]'::jsonb, 'SARDI 2006', true, true),
    ('sauvignon_blanc:entav_242', 'sauvignon_blanc', 'ENTAV-INRA 242', '242',    'ENTAV-INRA',           'France',    '[]'::jsonb, 'ENTAV-INRA authorised clone catalogue', true, true),
    ('sauvignon_blanc:entav_316', 'sauvignon_blanc', 'ENTAV-INRA 316', '316',    'ENTAV-INRA',           'France',    '[]'::jsonb, 'ENTAV-INRA authorised clone catalogue', true, true),
    ('sauvignon_blanc:entav_317', 'sauvignon_blanc', 'ENTAV-INRA 317', '317',    'ENTAV-INRA',           'France',    '[]'::jsonb, 'ENTAV-INRA authorised clone catalogue', true, true),
    ('sauvignon_blanc:entav_530', 'sauvignon_blanc', 'ENTAV-INRA 530', '530',    'ENTAV-INRA',           'France',    '[]'::jsonb, 'ENTAV-INRA authorised clone catalogue', true, true),
    ('sauvignon_blanc:fps_01',    'sauvignon_blanc', 'FPS 01',         'FPS 01', 'FPS (UC Davis)',       'USA',       '[]'::jsonb, 'FPS UC Davis Foundation Plant Services', true, true),

    -- Merlot
    ('merlot:d3v14',     'merlot', 'D3V14',          'D3V14', 'Australian selection', 'Australia', '[]'::jsonb, 'SARDI 2006', true, true),
    ('merlot:entav_181', 'merlot', 'ENTAV-INRA 181', '181',   'ENTAV-INRA',           'France',    '[]'::jsonb, 'ENTAV-INRA authorised clone catalogue', true, true),
    ('merlot:entav_343', 'merlot', 'ENTAV-INRA 343', '343',   'ENTAV-INRA',           'France',    '[]'::jsonb, 'ENTAV-INRA authorised clone catalogue', true, true),
    ('merlot:entav_348', 'merlot', 'ENTAV-INRA 348', '348',   'ENTAV-INRA',           'France',    '[]'::jsonb, 'ENTAV-INRA authorised clone catalogue', true, true),

    -- Riesling — Geisenheim
    ('riesling:gm110', 'riesling', 'GM110', 'GM110', 'Geisenheim', 'Germany', '["Geisenheim 110"]'::jsonb, 'Geisenheim Institute clone register', true, true),
    ('riesling:gm198', 'riesling', 'GM198', 'GM198', 'Geisenheim', 'Germany', '["Geisenheim 198"]'::jsonb, 'Geisenheim Institute clone register', true, true),
    ('riesling:gm239', 'riesling', 'GM239', 'GM239', 'Geisenheim', 'Germany', '["Geisenheim 239"]'::jsonb, 'Geisenheim Institute clone register', true, true),

    -- Pinot Gris
    ('pinot_gris:d1v7',      'pinot_gris', 'D1V7',           'D1V7', 'Australian selection', 'Australia', '[]'::jsonb, 'SARDI 2006', true, true),
    ('pinot_gris:entav_52',  'pinot_gris', 'ENTAV-INRA 52',  '52',   'ENTAV-INRA',           'France',    '[]'::jsonb, 'ENTAV-INRA authorised clone catalogue', true, true),
    ('pinot_gris:entav_53',  'pinot_gris', 'ENTAV-INRA 53',  '53',   'ENTAV-INRA',           'France',    '[]'::jsonb, 'ENTAV-INRA authorised clone catalogue', true, true),
    ('pinot_gris:entav_457', 'pinot_gris', 'ENTAV-INRA 457', '457',  'ENTAV-INRA',           'France',    '[]'::jsonb, 'ENTAV-INRA authorised clone catalogue', true, true),

    -- Grenache
    ('grenache:entav_136', 'grenache', 'ENTAV-INRA 136', '136', 'ENTAV-INRA', 'France', '[]'::jsonb, 'ENTAV-INRA authorised clone catalogue', true, true),
    ('grenache:entav_362', 'grenache', 'ENTAV-INRA 362', '362', 'ENTAV-INRA', 'France', '[]'::jsonb, 'ENTAV-INRA authorised clone catalogue', true, true),
    ('grenache:entav_513', 'grenache', 'ENTAV-INRA 513', '513', 'ENTAV-INRA', 'France', '[]'::jsonb, 'ENTAV-INRA authorised clone catalogue', true, true),
    ('grenache:entav_515', 'grenache', 'ENTAV-INRA 515', '515', 'ENTAV-INRA', 'France', '[]'::jsonb, 'ENTAV-INRA authorised clone catalogue', true, true),

    -- Semillon
    ('semillon:entav_173', 'semillon', 'ENTAV-INRA 173', '173', 'ENTAV-INRA', 'France', '[]'::jsonb, 'ENTAV-INRA authorised clone catalogue', true, true),
    ('semillon:entav_299', 'semillon', 'ENTAV-INRA 299', '299', 'ENTAV-INRA', 'France', '[]'::jsonb, 'ENTAV-INRA authorised clone catalogue', true, true)
on conflict (key) do update
    set variety_key      = excluded.variety_key,
        display_name     = excluded.display_name,
        clone_code       = excluded.clone_code,
        selection_system = excluded.selection_system,
        source_country   = excluded.source_country,
        aliases          = excluded.aliases,
        source_reference = excluded.source_reference,
        is_builtin       = excluded.is_builtin,
        is_active        = true,
        updated_at       = now();


-- =========================================================================
-- Seed: built-in rootstock catalogue
-- =========================================================================
insert into public.rootstock_catalog
    (key, canonical_name, display_name, aliases, parentage, source_reference, is_builtin, is_active)
values
    ('101_14',         '101-14 Mgt',          '101-14 Mgt',          '["101-14","101.14 Millardet et de Grasset"]'::jsonb, 'V. riparia × V. rupestris',            'Wine Australia / AWRI rootstock references', true, true),
    ('3309c',          '3309 Couderc',        '3309 Couderc',        '["3309C","3309"]'::jsonb,                            'V. riparia × V. rupestris',            'Wine Australia / AWRI rootstock references', true, true),
    ('schwarzmann',    'Schwarzmann',         'Schwarzmann',         '[]'::jsonb,                                          'V. riparia × V. rupestris',            'Wine Australia / AWRI rootstock references', true, true),
    ('110_richter',    '110 Richter',         '110 Richter',         '["110R"]'::jsonb,                                    'V. berlandieri × V. rupestris',        'Wine Australia / AWRI rootstock references', true, true),
    ('99_richter',     '99 Richter',          '99 Richter',          '["99R"]'::jsonb,                                     'V. berlandieri × V. rupestris',        'Wine Australia / AWRI rootstock references', true, true),
    ('1103_paulsen',   '1103 Paulsen',        '1103 Paulsen',        '["1103P","Paulsen"]'::jsonb,                         'V. berlandieri × V. rupestris',        'Wine Australia / AWRI rootstock references', true, true),
    ('140_ruggeri',    '140 Ruggeri',         '140 Ruggeri',         '["140Ru","140 Ru"]'::jsonb,                          'V. berlandieri × V. rupestris',        'Wine Australia / AWRI rootstock references', true, true),
    ('5bb_kober',      '5BB Kober',           '5BB Kober',           '["Kober 5BB","5BB"]'::jsonb,                         'V. berlandieri × V. riparia',          'Wine Australia / AWRI rootstock references', true, true),
    ('5c_teleki',      '5C Teleki',           '5C Teleki',           '["Teleki 5C","5C"]'::jsonb,                          'V. berlandieri × V. riparia',          'Wine Australia / AWRI rootstock references', true, true),
    ('so4',            'SO4',                 'SO4',                 '["Selection Oppenheim 4"]'::jsonb,                   'V. berlandieri × V. riparia',          'Wine Australia / AWRI rootstock references', true, true),
    ('420a',           '420A Mgt',            '420A Mgt',            '["420A"]'::jsonb,                                    'V. berlandieri × V. riparia',          'Wine Australia / AWRI rootstock references', true, true),
    ('161_49c',        '161-49 Couderc',      '161-49 Couderc',      '["161-49C"]'::jsonb,                                 'V. berlandieri × V. riparia',          'Wine Australia / AWRI rootstock references', true, true),
    ('ramsey',         'Ramsey',              'Ramsey',              '["Salt Creek"]'::jsonb,                              'V. champinii',                         'Wine Australia / AWRI rootstock references', true, true),
    ('dog_ridge',      'Dog Ridge',           'Dog Ridge',           '[]'::jsonb,                                          'V. champinii',                         'Wine Australia / AWRI rootstock references', true, true),
    ('freedom',        'Freedom',             'Freedom',             '[]'::jsonb,                                          'Complex hybrid (1613 Couderc × Dog Ridge parentage)', 'Wine Australia / AWRI rootstock references', true, true),
    ('harmony',        'Harmony',             'Harmony',             '[]'::jsonb,                                          'Complex hybrid (1613 Couderc × Dog Ridge parentage)', 'Wine Australia / AWRI rootstock references', true, true),
    ('1613c',          '1613 Couderc',        '1613 Couderc',        '["1613C"]'::jsonb,                                   'Complex hybrid (solonis × Othello)',   'Wine Australia / AWRI rootstock references', true, true),
    ('k51_40',         'K51-40',              'K51-40',              '["K51 40"]'::jsonb,                                  'V. champinii × V. riparia',            'Wine Australia / AWRI rootstock references', true, true),
    ('riparia_gloire', 'Riparia Gloire',      'Riparia Gloire',      '["Riparia Gloire de Montpellier"]'::jsonb,           'V. riparia',                           'Wine Australia / AWRI rootstock references', true, true),
    ('st_george',      'Rupestris St George', 'Rupestris St George', '["St George","Rupestris du Lot"]'::jsonb,            'V. rupestris',                         'Wine Australia / AWRI rootstock references', true, true),
    ('borner',         'Börner',              'Börner',              '["Borner"]'::jsonb,                                  'V. riparia × V. cinerea',              'Wine Australia / AWRI rootstock references', true, true),
    ('fercal',         'Fercal',              'Fercal',              '[]'::jsonb,                                          'Complex hybrid (berlandieri × vinifera parentage)', 'Wine Australia / AWRI rootstock references', true, true),
    ('gravesac',       'Gravesac',            'Gravesac',            '[]'::jsonb,                                          '161-49 Couderc × 3309 Couderc',        'Wine Australia / AWRI rootstock references', true, true),
    ('merbein_5489',   'Merbein 5489',        'Merbein 5489',        '[]'::jsonb,                                          'CSIRO hybrid',                         'CSIRO Merbein series (Australia)', true, true),
    ('merbein_5512',   'Merbein 5512',        'Merbein 5512',        '[]'::jsonb,                                          'CSIRO hybrid',                         'CSIRO Merbein series (Australia)', true, true),
    ('merbein_6262',   'Merbein 6262',        'Merbein 6262',        '[]'::jsonb,                                          'CSIRO hybrid',                         'CSIRO Merbein series (Australia)', true, true)
on conflict (key) do update
    set canonical_name   = excluded.canonical_name,
        display_name     = excluded.display_name,
        aliases          = excluded.aliases,
        parentage        = excluded.parentage,
        source_reference = excluded.source_reference,
        is_builtin       = excluded.is_builtin,
        is_active        = true,
        updated_at       = now();


-- =========================================================================
-- Helpers: custom keys
-- =========================================================================
-- custom clone key: custom:<vineyard_id>:<variety_slug>:<slug>
-- The owning variety is baked into the key so the same custom clone name
-- under two varieties never collides, and a custom Shiraz clone can never
-- surface under Chardonnay.
create or replace function public._grape_clone_custom_key(
    p_vineyard_id uuid,
    p_variety_key text,
    p_name        text
)
returns text
language plpgsql
immutable
as $$
declare
    v_variety_slug text;
    v_slug         text;
begin
    if p_vineyard_id is null then return null; end if;
    v_variety_slug := public._grape_variety_slugify(p_variety_key);
    v_slug         := public._grape_variety_slugify(p_name);
    if v_variety_slug is null or v_slug is null then return null; end if;
    return 'custom:' || p_vineyard_id::text || ':' || v_variety_slug || ':' || v_slug;
end$$;

grant execute on function public._grape_clone_custom_key(uuid, text, text) to authenticated;


-- =========================================================================
-- RLS
-- =========================================================================
alter table public.grape_clone_catalog   enable row level security;
alter table public.vineyard_grape_clones enable row level security;
alter table public.rootstock_catalog     enable row level security;
alter table public.vineyard_rootstocks   enable row level security;

-- Global catalogues: readable by any authenticated user; writes are
-- system-admin only (seeds in this migration handle built-ins).
drop policy if exists grape_clone_catalog_read on public.grape_clone_catalog;
create policy grape_clone_catalog_read
    on public.grape_clone_catalog for select to authenticated using (true);

drop policy if exists grape_clone_catalog_admin_write on public.grape_clone_catalog;
create policy grape_clone_catalog_admin_write
    on public.grape_clone_catalog for all to authenticated
    using (public.is_system_admin()) with check (public.is_system_admin());

drop policy if exists rootstock_catalog_read on public.rootstock_catalog;
create policy rootstock_catalog_read
    on public.rootstock_catalog for select to authenticated using (true);

drop policy if exists rootstock_catalog_admin_write on public.rootstock_catalog;
create policy rootstock_catalog_admin_write
    on public.rootstock_catalog for all to authenticated
    using (public.is_system_admin()) with check (public.is_system_admin());

-- Vineyard-scoped custom rows: members read; owner/manager write
-- (same isolation as vineyard_grape_varieties from sql/073).
drop policy if exists vineyard_grape_clones_read on public.vineyard_grape_clones;
create policy vineyard_grape_clones_read
    on public.vineyard_grape_clones for select to authenticated
    using (public.is_vineyard_member(vineyard_id));

drop policy if exists vineyard_grape_clones_insert on public.vineyard_grape_clones;
create policy vineyard_grape_clones_insert
    on public.vineyard_grape_clones for insert to authenticated
    with check (public.has_vineyard_role(vineyard_id, array['owner','manager']));

drop policy if exists vineyard_grape_clones_update on public.vineyard_grape_clones;
create policy vineyard_grape_clones_update
    on public.vineyard_grape_clones for update to authenticated
    using (public.has_vineyard_role(vineyard_id, array['owner','manager']))
    with check (public.has_vineyard_role(vineyard_id, array['owner','manager']));

drop policy if exists vineyard_grape_clones_delete on public.vineyard_grape_clones;
create policy vineyard_grape_clones_delete
    on public.vineyard_grape_clones for delete to authenticated
    using (public.has_vineyard_role(vineyard_id, array['owner','manager']));

drop policy if exists vineyard_rootstocks_read on public.vineyard_rootstocks;
create policy vineyard_rootstocks_read
    on public.vineyard_rootstocks for select to authenticated
    using (public.is_vineyard_member(vineyard_id));

drop policy if exists vineyard_rootstocks_insert on public.vineyard_rootstocks;
create policy vineyard_rootstocks_insert
    on public.vineyard_rootstocks for insert to authenticated
    with check (public.has_vineyard_role(vineyard_id, array['owner','manager']));

drop policy if exists vineyard_rootstocks_update on public.vineyard_rootstocks;
create policy vineyard_rootstocks_update
    on public.vineyard_rootstocks for update to authenticated
    using (public.has_vineyard_role(vineyard_id, array['owner','manager']))
    with check (public.has_vineyard_role(vineyard_id, array['owner','manager']));

drop policy if exists vineyard_rootstocks_delete on public.vineyard_rootstocks;
create policy vineyard_rootstocks_delete
    on public.vineyard_rootstocks for delete to authenticated
    using (public.has_vineyard_role(vineyard_id, array['owner','manager']));


-- =========================================================================
-- RPC: get_grape_clone_catalog()
-- =========================================================================
drop function if exists public.get_grape_clone_catalog();

create or replace function public.get_grape_clone_catalog()
returns table(
    key              text,
    variety_key      text,
    display_name     text,
    clone_code       text,
    selection_system text,
    source_country   text,
    aliases          jsonb,
    source_reference text,
    is_builtin       boolean,
    is_active        boolean,
    updated_at       timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
    select c.key, c.variety_key, c.display_name, c.clone_code,
           c.selection_system, c.source_country, c.aliases,
           c.source_reference, c.is_builtin, c.is_active, c.updated_at
      from public.grape_clone_catalog c
     where c.is_active = true
     order by c.variety_key, c.display_name;
$$;

grant execute on function public.get_grape_clone_catalog() to authenticated;


-- =========================================================================
-- RPC: get_rootstock_catalog()
-- =========================================================================
drop function if exists public.get_rootstock_catalog();

create or replace function public.get_rootstock_catalog()
returns table(
    key              text,
    canonical_name   text,
    display_name     text,
    aliases          jsonb,
    parentage        text,
    source_reference text,
    is_builtin       boolean,
    is_active        boolean,
    updated_at       timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
    select r.key, r.canonical_name, r.display_name, r.aliases,
           r.parentage, r.source_reference, r.is_builtin, r.is_active, r.updated_at
      from public.rootstock_catalog r
     where r.is_active = true
     order by r.display_name;
$$;

grant execute on function public.get_rootstock_catalog() to authenticated;


-- =========================================================================
-- RPC: list_vineyard_grape_clones(p_vineyard_id)
-- =========================================================================
drop function if exists public.list_vineyard_grape_clones(uuid);

create or replace function public.list_vineyard_grape_clones(p_vineyard_id uuid)
returns table(
    id           uuid,
    vineyard_id  uuid,
    clone_key    text,
    variety_key  text,
    display_name text,
    is_custom    boolean,
    is_active    boolean,
    created_at   timestamptz,
    updated_at   timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
    if p_vineyard_id is null then
        raise exception 'missing_vineyard_id' using errcode = '22023';
    end if;
    if not public.is_vineyard_member(p_vineyard_id) then
        raise exception 'not_authorized' using errcode = '42501';
    end if;

    return query
        select v.id, v.vineyard_id, v.clone_key, v.variety_key,
               v.display_name, v.is_custom, v.is_active,
               v.created_at, v.updated_at
          from public.vineyard_grape_clones v
         where v.vineyard_id = p_vineyard_id
         order by v.variety_key, v.display_name;
end$$;

grant execute on function public.list_vineyard_grape_clones(uuid) to authenticated;


-- =========================================================================
-- RPC: list_vineyard_rootstocks(p_vineyard_id)
-- =========================================================================
drop function if exists public.list_vineyard_rootstocks(uuid);

create or replace function public.list_vineyard_rootstocks(p_vineyard_id uuid)
returns table(
    id            uuid,
    vineyard_id   uuid,
    rootstock_key text,
    display_name  text,
    is_custom     boolean,
    is_active     boolean,
    created_at    timestamptz,
    updated_at    timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
    if p_vineyard_id is null then
        raise exception 'missing_vineyard_id' using errcode = '22023';
    end if;
    if not public.is_vineyard_member(p_vineyard_id) then
        raise exception 'not_authorized' using errcode = '42501';
    end if;

    return query
        select v.id, v.vineyard_id, v.rootstock_key, v.display_name,
               v.is_custom, v.is_active, v.created_at, v.updated_at
          from public.vineyard_rootstocks v
         where v.vineyard_id = p_vineyard_id
         order by v.display_name;
end$$;

grant execute on function public.list_vineyard_rootstocks(uuid) to authenticated;


-- =========================================================================
-- RPC: upsert_vineyard_grape_clone(...)
-- =========================================================================
-- Creates/updates a vineyard-scoped CUSTOM clone. The parent variety is
-- REQUIRED: pass either a built-in catalogue key (e.g. `shiraz`) or the
-- vineyard's custom variety key (`custom:<vineyard_id>:<slug>`). The server
-- derives a stable `custom:<vineyard_id>:<variety_slug>:<slug>` clone key.
-- Reserved sentinel names ('mass_selection', 'own_roots', 'unknown') are
-- rejected — they are allocation-level conventions, not records.

drop function if exists public.upsert_vineyard_grape_clone(uuid, text, text, boolean);

create or replace function public.upsert_vineyard_grape_clone(
    p_vineyard_id  uuid,
    p_variety_key  text,
    p_display_name text,
    p_is_active    boolean default true
)
returns public.vineyard_grape_clones
language plpgsql
security definer
set search_path = public
as $$
declare
    v_variety_key  text;
    v_display_name text;
    v_key          text;
    v_slug         text;
    v_row          public.vineyard_grape_clones;
begin
    if p_vineyard_id is null then
        raise exception 'missing_vineyard_id' using errcode = '22023';
    end if;
    if not public.has_vineyard_role(p_vineyard_id, array['owner','manager']) then
        raise exception 'not_authorized' using errcode = '42501';
    end if;

    v_variety_key  := nullif(trim(coalesce(p_variety_key, '')), '');
    v_display_name := nullif(trim(coalesce(p_display_name, '')), '');

    if v_variety_key is null then
        raise exception 'missing_variety_key' using errcode = '22023';
    end if;
    if v_display_name is null then
        raise exception 'missing_display_name' using errcode = '22023';
    end if;

    v_slug := public._grape_variety_slugify(v_display_name);
    if v_slug is null then
        raise exception 'invalid_display_name' using errcode = '22023';
    end if;
    if v_slug in ('mass_selection', 'own_roots', 'unknown', 'not_specified') then
        raise exception 'reserved_name' using errcode = '22023';
    end if;

    -- Parent variety must exist: either a built-in catalogue key or a
    -- variety selection (incl. custom) already present for this vineyard.
    if v_variety_key not like 'custom:%' then
        if not exists (
            select 1 from public.grape_variety_catalog c
             where c.key = v_variety_key and c.is_active = true
        ) then
            raise exception 'unknown_variety_key: %', v_variety_key using errcode = '22023';
        end if;
    else
        if not exists (
            select 1 from public.vineyard_grape_varieties v
             where v.vineyard_id = p_vineyard_id and v.variety_key = v_variety_key
        ) then
            raise exception 'unknown_variety_key: %', v_variety_key using errcode = '22023';
        end if;
    end if;

    v_key := public._grape_clone_custom_key(p_vineyard_id, v_variety_key, v_display_name);
    if v_key is null then
        raise exception 'invalid_display_name' using errcode = '22023';
    end if;

    insert into public.vineyard_grape_clones as t
        (vineyard_id, clone_key, variety_key, display_name, is_custom, is_active)
    values
        (p_vineyard_id, v_key, v_variety_key, v_display_name, true, coalesce(p_is_active, true))
    on conflict (vineyard_id, clone_key) do update
        set display_name = excluded.display_name,
            is_active    = excluded.is_active,
            updated_at   = now()
    returning * into v_row;

    return v_row;
end$$;

grant execute on function public.upsert_vineyard_grape_clone(uuid, text, text, boolean)
    to authenticated;


-- =========================================================================
-- RPC: upsert_vineyard_rootstock(...)
-- =========================================================================
drop function if exists public.upsert_vineyard_rootstock(uuid, text, boolean);

create or replace function public.upsert_vineyard_rootstock(
    p_vineyard_id  uuid,
    p_display_name text,
    p_is_active    boolean default true
)
returns public.vineyard_rootstocks
language plpgsql
security definer
set search_path = public
as $$
declare
    v_display_name text;
    v_key          text;
    v_slug         text;
    v_row          public.vineyard_rootstocks;
begin
    if p_vineyard_id is null then
        raise exception 'missing_vineyard_id' using errcode = '22023';
    end if;
    if not public.has_vineyard_role(p_vineyard_id, array['owner','manager']) then
        raise exception 'not_authorized' using errcode = '42501';
    end if;

    v_display_name := nullif(trim(coalesce(p_display_name, '')), '');
    if v_display_name is null then
        raise exception 'missing_display_name' using errcode = '22023';
    end if;

    v_slug := public._grape_variety_slugify(v_display_name);
    if v_slug is null then
        raise exception 'invalid_display_name' using errcode = '22023';
    end if;
    if v_slug in ('own_roots', 'ungrafted', 'unknown', 'not_specified', 'mass_selection') then
        raise exception 'reserved_name' using errcode = '22023';
    end if;

    -- A custom rootstock must not shadow a built-in (typos should be fixed
    -- by choosing the catalogue record, not by minting a near-duplicate).
    if exists (
        select 1 from public.rootstock_catalog c
         where c.is_active = true
           and public._grape_variety_slugify(c.canonical_name) = v_slug
    ) then
        raise exception 'duplicates_builtin' using errcode = '22023';
    end if;

    v_key := public._grape_variety_custom_key(p_vineyard_id, v_display_name);
    if v_key is null then
        raise exception 'invalid_display_name' using errcode = '22023';
    end if;

    insert into public.vineyard_rootstocks as t
        (vineyard_id, rootstock_key, display_name, is_custom, is_active)
    values
        (p_vineyard_id, v_key, v_display_name, true, coalesce(p_is_active, true))
    on conflict (vineyard_id, rootstock_key) do update
        set display_name = excluded.display_name,
            is_active    = excluded.is_active,
            updated_at   = now()
    returning * into v_row;

    return v_row;
end$$;

grant execute on function public.upsert_vineyard_rootstock(uuid, text, boolean)
    to authenticated;


-- =========================================================================
-- RPC: archive_vineyard_grape_clone(p_id) / archive_vineyard_rootstock(p_id)
-- =========================================================================
-- Soft-archive (is_active = false). Historical block allocations keep
-- resolving by key; the record just hides from pickers.

drop function if exists public.archive_vineyard_grape_clone(uuid);

create or replace function public.archive_vineyard_grape_clone(p_id uuid)
returns public.vineyard_grape_clones
language plpgsql
security definer
set search_path = public
as $$
declare
    v_row public.vineyard_grape_clones;
begin
    if p_id is null then
        raise exception 'missing_id' using errcode = '22023';
    end if;

    select * into v_row from public.vineyard_grape_clones where id = p_id limit 1;
    if v_row.id is null then
        raise exception 'not_found' using errcode = 'P0002';
    end if;
    if not public.has_vineyard_role(v_row.vineyard_id, array['owner','manager']) then
        raise exception 'not_authorized' using errcode = '42501';
    end if;

    update public.vineyard_grape_clones
       set is_active = false, updated_at = now()
     where id = p_id
    returning * into v_row;

    return v_row;
end$$;

grant execute on function public.archive_vineyard_grape_clone(uuid) to authenticated;


drop function if exists public.archive_vineyard_rootstock(uuid);

create or replace function public.archive_vineyard_rootstock(p_id uuid)
returns public.vineyard_rootstocks
language plpgsql
security definer
set search_path = public
as $$
declare
    v_row public.vineyard_rootstocks;
begin
    if p_id is null then
        raise exception 'missing_id' using errcode = '22023';
    end if;

    select * into v_row from public.vineyard_rootstocks where id = p_id limit 1;
    if v_row.id is null then
        raise exception 'not_found' using errcode = 'P0002';
    end if;
    if not public.has_vineyard_role(v_row.vineyard_id, array['owner','manager']) then
        raise exception 'not_authorized' using errcode = '42501';
    end if;

    update public.vineyard_rootstocks
       set is_active = false, updated_at = now()
     where id = p_id
    returning * into v_row;

    return v_row;
end$$;

grant execute on function public.archive_vineyard_rootstock(uuid) to authenticated;


-- =========================================================================
-- Notes for consumers (iOS + Android + Lovable)
-- =========================================================================
-- Clone selector (per allocation):
--   options = get_grape_clone_catalog() WHERE variety_key = allocation variety
--           + list_vineyard_grape_clones(vineyard) WHERE variety_key matches
--           + 'Mass selection' sentinel + 'Not specified' (null)
--   Search matches display_name, clone_code, and aliases.
--
-- Rootstock selector (per allocation):
--   options = get_rootstock_catalog()
--           + list_vineyard_rootstocks(vineyard)
--           + 'Own roots / ungrafted' sentinel + 'Not recorded' (null)
--
-- Writing an allocation: always stamp BOTH the stable key (cloneKey /
-- rootstockKey) AND the display snapshot (clone / rootstock). The sql/180
-- picking log and all existing display surfaces read the snapshot.
--
-- Legacy allocations with free text only: keep the text as-is. Clients may
-- offer an exact/canonical match as a suggestion but must never silently
-- rewrite ambiguous text onto a catalogue key.
