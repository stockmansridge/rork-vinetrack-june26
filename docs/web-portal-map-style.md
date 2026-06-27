# Web Portal Map Style Guide

Canonical map styling reference for the Lovable web portal. The goal is to make the
read-only (and future read/write) web portal map visually match the iOS VineTrack app
as closely as possible.

This document covers **styling and presentation only**. All geometry write rules
(polygon_points, rows, variety_allocations, derived calculations, validation) remain
governed by `docs/paddock-geometry-writer-spec.md`. No database or schema changes are
implied by this document.

---

## 1. Map provider

- iOS uses **Apple MapKit** throughout the app for vineyard, paddock, trip and pin
  rendering.
- The web portal **should use Apple MapKit JS** when a MapKit JS token is configured.
- **Leaflet + OpenStreetMap remains a fallback only** — used when no MapKit JS token
  is available, or when MapKit JS fails to initialise.
- Default map type: **Hybrid** (satellite imagery + roads/labels), matching the iOS
  default for paddock and trip views.
- Users may toggle between Hybrid and Standard, but the portal must boot in Hybrid.
- Do not default to plain OSM tiles when MapKit JS is available.

### Token / configuration

- Token is loaded from a build-time env var on the web portal (e.g.
  `VITE_MAPKIT_JS_TOKEN`).
- If missing or invalid, the portal must fall back to Leaflet/OSM and show the
  source label “Map: OpenStreetMap fallback”.
- The portal must never block paddock display because of a missing MapKit token.

---

## 2. Paddock polygons

Paddock polygons represent block boundaries. They are drawn on top of the satellite
imagery in Hybrid mode.

| Property                | Value                                            |
| ----------------------- | ------------------------------------------------ |
| Fill colour             | Per-paddock colour (see below), else systemBlue  |
| Fill opacity            | **0.25**                                         |
| Stroke colour           | Same hue as fill, fully opaque                   |
| Stroke opacity          | **1.0** (selected) / **0.9** (unselected)        |
| Stroke width            | **2.5**                                          |
| Line join / cap         | Round                                            |

### Per-paddock colour generation

If the paddock has a stored colour (future field), use it. Otherwise derive a stable
colour from the paddock id:

```
hue   = (hashStable(paddock.id) % 360)
sat   = 70%
light = 50%
```

The same paddock must always render the same colour across reloads and across
devices. Do not randomise per session.

### Selected paddock

When a paddock is selected (clicked / focused):

- Stroke width: **3.5**
- Stroke opacity: **1.0**
- Fill opacity: **0.35**
- Optional subtle outer glow / shadow allowed but not required.

Unselected paddocks remain visible at their normal styling — do not dim them
heavily. A faint dim (multiply fill opacity by ~0.8) is acceptable but optional.

---

## 3. Row lines

Each row is rendered as a **straight line** from `startPoint` to `endPoint`.

| Property        | Value                                  |
| --------------- | -------------------------------------- |
| Stroke colour   | systemGreen equivalent (`#34C759`)     |
| Opacity         | **0.85**                               |
| Width           | **1.5**                                |
| Line cap        | Round                                  |
| Line join       | n/a (single segment)                   |

- Rows are **not** rendered as polylines through multiple vertices. Always
  `start → end`, even when row geometry data has more points.
- Rows belonging to non-selected paddocks may be hidden at low zoom levels for
  performance, but should appear once the paddock is selected or zoomed in.

---

## 4. Row number labels

Only the **first** and **last** row of each paddock are labelled. This matches the
iOS map.

| Property              | Value                                    |
| --------------------- | ---------------------------------------- |
| Which rows            | First and last only                      |
| Label position        | Anchored at the row’s `startPoint`       |
| Anchor offset         | Slight outward offset (~6pt) along bearing reverse |
| Text                  | Row number (e.g. `1`, `42`)              |
| Font                  | System bold, **13pt**                    |
| Text colour           | White                                    |
| Background colour     | systemBlue (`#007AFF`)                   |
| Background opacity    | **0.85**                                 |
| Padding               | ~6pt vertical, ~12pt horizontal          |
| Corner radius         | ~6pt (rounded chip)                      |
| Shadow                | Optional subtle drop shadow              |

Labels must remain legible against satellite imagery. Do not switch them to dark
mode automatically.

---

## 5. Paddock name labels

| Property              | Value                                    |
| --------------------- | ---------------------------------------- |
| Position              | Centroid of the polygon                  |
| Text                  | Paddock name                             |
| Font                  | System semibold, ~14pt                   |
| Text colour           | White                                    |
| Background colour     | Black / dark grey                        |
| Background opacity    | ~0.55                                    |
| Padding               | ~4pt vertical, ~8pt horizontal           |
| Corner radius         | ~6pt                                     |

- Hide name label when the paddock is too small on screen to fit the chip without
  overflowing the polygon.
- One label per paddock. Do not stack overlapping labels — collapse or hide.

---

## 6. Camera / bounds

### Single paddock view

- Fit the polygon bounds.
- Apply **1.5× span padding** (i.e. expand the bounding box by 50% on each axis
  before fitting).
- Do not zoom past a sensible max (roughly street level).

### Multiple paddocks (vineyard overview)

- Fit the union of all paddock bounding boxes.
- Apply the same 1.5× span padding.
- If only one paddock has geometry, fit that paddock.

### No polygon exists

- Fall back to vineyard centre coordinate if available.
- Otherwise fall back to a sensible default region (e.g. country/region of the
  user) and show a banner: “No paddock geometry yet.”
- Never crash or leave the map blank without explanation.

### Animations

- Camera transitions should animate smoothly (~400ms) on selection change.
- Initial load may be instant.

---

## 7. Variety allocations

Variety allocations are sub-regions inside a paddock representing different
varieties / clones / rootstocks.

### MVP (read-only portal)

- **Do not render variety allocations in the MVP.**
- They remain a future enhancement once the canonical JSON shape is fully stable
  on the web side.

### Suggested future style (when added)

- Sub-polygon, drawn on top of the parent paddock fill.
- Stroke: dashed (`5,4` dash pattern).
- Stroke colour: derived from variety name hash, distinct from paddock hue.
- Fill opacity: 0.18.
- Stroke width: 1.5.
- Label: variety name in a small chip at sub-polygon centroid.

---

## 8. Pins / trips future parity

Not required in the MVP map view, but documented now for parity when the portal
expands.

### Trip path

- Polyline of GPS samples.
- Stroke colour: systemOrange (`#FF9500`) for active / recent trips.
- Stroke opacity: 0.9.
- Stroke width: 3.
- Line cap/join: round.

### Pin annotations

- Use MapKit JS `MarkerAnnotation` (or equivalent).
- Glyph colour: white.
- Marker tint: by pin category.
- Show callout on click with title + subtitle.

### Suggested category colours

| Category   | Colour          | Hex       |
| ---------- | --------------- | --------- |
| Repair     | systemRed       | `#FF3B30` |
| Growth     | systemGreen     | `#34C759` |
| Note       | systemBlue      | `#007AFF` |
| Hazard     | systemYellow    | `#FFCC00` |
| Spray      | systemPurple    | `#AF52DE` |

These map back to the iOS pin colours.

---

## 9. MapKit JS implementation notes

### Initialisation

```js
mapkit.init({
  authorizationCallback: (done) => done(MAPKIT_JS_TOKEN),
  language: "en",
});

const map = new mapkit.Map(container, {
  mapType: mapkit.Map.MapTypes.Hybrid,
  showsCompass: mapkit.FeatureVisibility.Adaptive,
  showsScale: mapkit.FeatureVisibility.Adaptive,
  showsUserLocationControl: false,
});
```

### Polygons

- Use `mapkit.PolygonOverlay` with `style: new mapkit.Style({...})`.
- `fillOpacity: 0.25`, `strokeOpacity: 0.9 | 1.0`, `lineWidth: 2.5 | 3.5`.

### Row lines

- Use `mapkit.PolylineOverlay` with start/end coordinates only.
- `strokeColor: "#34C759"`, `strokeOpacity: 0.85`, `lineWidth: 1.5`.

### Labels

- MapKit JS does not provide native chip labels. Implement labels as
  `mapkit.Annotation` with a custom DOM element factory:

```js
new mapkit.Annotation(coordinate, () => {
  const el = document.createElement("div");
  el.className = "vt-row-chip";
  el.textContent = "1";
  return el;
}, { anchorOffset: new DOMPoint(0, -6) });
```

- Style chips with the values from sections 4 and 5.

### Fallback behaviour (no token)

- Detect missing/invalid token before `mapkit.init`.
- Mount Leaflet with an OSM tile layer.
- Reuse the same polygon / polyline / label styling values.
- Show source label “Map: OpenStreetMap fallback”.

### Source label

A small attribution chip in the bottom-left of the map:

- “Map: Apple Maps” when MapKit JS is active.
- “Map: OpenStreetMap fallback” when Leaflet is active.

Style: 11pt, white text, black background at 0.5 opacity, 4pt corner radius,
4×8pt padding. Always visible. This is in addition to MapKit / OSM’s own
attribution which must remain compliant.

---

## 10. Reminders

- This document is **styling only**.
- The geometry write contract is **`docs/paddock-geometry-writer-spec.md`** and is
  the single source of truth for any web → Supabase paddock writes.
- No DB or schema changes are implied or required by this document.
- iOS rendering remains the visual reference. If iOS changes a default (e.g. new
  selected-paddock styling), update this doc and notify the portal team.
