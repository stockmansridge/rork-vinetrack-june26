# VineTrack — Brand & Login Spec

Canonical reference for the Lovable web portal to match the iOS VineTrack login screen.

> Source of truth (Swift):
> - `ios/VineTrackV2/App/NewBackendLoginView.swift` (login screen + background shapes)
> - `ios/VineTrackV2/LegacyImported/Views/Components/VineyardTheme.swift` (theme tokens)
> - `ios/VineTrackV2/Assets.xcassets/AppIcon.appiconset/icon.png` (app icon, 1024×1024)
> - `ios/VineTrackV2/Assets.xcassets/vinetrack_logo.imageset/vinetrack_logo.png` (logo used on login/splash, 1024×1024)

---

## 1. App name & wording

- App name: **VineTrack** (no "V2", no version suffix anywhere user-facing).
- Login title: `VineTrack`
- Tagline (two lines, centered, white):
  ```
  Built by viticulturists to manage
  vineyard work, row by row.
  ```
- Feature chips (capsule, white text, white outline @ 22% opacity):
  - GPS Pins — `mappin.circle.fill`
  - Row Tracking — `line.3.horizontal.decrease`
  - Spray Records — `leaf.fill`
- Mode picker: `Sign In` / `Sign Up`
- Primary buttons: `Sign In`, `Create Account`
- "or" divider, then Apple Sign-In (black system style)
- Footer: `Forgot password?` (sign-in mode only)

---

## 2. Logo / icon assets

Exported into this folder for direct portal use:

| File | Size | Use |
| --- | --- | --- |
| `docs/brand/vinetrack-app-icon-1024.png` | 1024×1024 | App store, hero |
| `docs/brand/vinetrack-app-icon-512.png` | 512×512 | Web favicon source, header |
| `docs/brand/vinetrack-logo-1024.png` | 1024×1024 | Login screen logo (rounded in UI) |

Notes:
- Both files are 8-bit RGB PNGs. They are **not** transparent — the icon is a full-bleed square. The iOS login screen rounds it visually with a `RoundedRectangle` mask (~26pt radius on a 102pt tile). Apply the same rounded-rect clip in the web portal:
  - Tile size: `~96–112px` square.
  - Corner radius: `~22–26%` of side length (≈ iOS continuous corner).
  - White stroke: `1.2px @ 24% opacity`.
  - Drop shadow: `rgba(0,0,0,0.35)` blur `14`, offset `0 8`.
- A transparent variant is **not currently available** in the iOS asset catalog. If one is needed, request a redrawn export.

---

## 3. Brand & login colours

Hex values are converted from the SwiftUI `Color(red:green:blue:)` literals.

### 3.1 Login background gradient (top-left → bottom-right)

| Stop | sRGB | Hex |
| --- | --- | --- |
| Top-left | (0.06, 0.43, 0.20) | `#0F6E33` |
| Mid | (0.02, 0.28, 0.13) | `#054721` |
| Bottom-right | (0.01, 0.17, 0.09) | `#022C17` |

Plus a soft top-left **radial highlight**: `rgba(255,255,255,0.15)` → transparent, radius ≈ 420px.

Two decorative SVG shapes are layered on top at low opacity (`white @ 8–10%`) — see `VineyardSweepShape` and `VineyardRowsShape` in `NewBackendLoginView.swift` if you want to recreate them. Skipping them is acceptable; the gradient alone reads correctly.

### 3.2 Action / accent colours

| Token | Use | Value |
| --- | --- | --- |
| Primary action | `Sign In` / `Create Account` button | iOS `systemBlue` ≈ `#007AFF` (light) / `#0A84FF` (dark) |
| Mode picker (selected) | active segment background | `(0.01, 0.30, 0.13)` → `#024C21` |
| Mode picker (selected text) | white | `#FFFFFF` |
| Mode picker (unselected text) | dark green | `(0.02, 0.22, 0.10)` → `#03381A` |
| Field icon tint | input leading icon | `(0.02, 0.32, 0.14)` → `#055124` |
| Field icon background | small rounded tile behind icon | `(0.93, 0.97, 0.91)` → `#EDF7E8` |
| Field text | typed value | `(0.02, 0.20, 0.10)` → `#03331A` |
| Field placeholder | prompt | `(0.30, 0.36, 0.32)` → `#4D5C52` |
| Forgot-password link | accent on dark bg | `(0.94, 0.92, 0.72)` → `#F0EBB8` |

### 3.3 In-app theme palette (`VineyardTheme`)

| Token | Hex | Notes |
| --- | --- | --- |
| `leafGreen` | `#5C8C4D` | Brand accent, success, empty-state circles |
| `darkGreen` | `#33662E` | Secondary brand accent |
| `earthBrown` | `#735238` | Earth accent |
| `vineRed` | `#8C2E38` | Vine accent / harvest |
| `cream` | `#F7F2E0` | Soft surface |
| `stone` | `#C7BCA8` | Muted surface |
| `primary` | `#007AFF` | iOS systemBlue — primary action everywhere in-app |
| `success` | `#5C8C4D` | == leafGreen |
| `warning` | iOS systemOrange | |
| `destructive` | iOS systemRed | |
| `info` | iOS systemBlue | |
| `appBackground` | iOS `systemGroupedBackground` | `#F2F2F7` light / `#000` dark |
| `cardBackground` | iOS `secondarySystemGroupedBackground` | `#FFFFFF` light |
| `cardBorder` | iOS `separator` @ 50% | hairline |

> Rule of thumb: **deep green is the login/brand atmosphere; systemBlue is the primary in-app action colour.** Do not switch the in-app primary to green — match iOS.

---

## 4. Typography & shape

- All text uses the **system font** (SF Pro on Apple, system stack on web is fine). No custom font files.
- Login title `VineTrack`: weight `heavy` (≈800), size `48pt` (compact heights `38pt`), white, 28% black drop shadow `(0, 2, 2)`.
- Tagline: body, weight `medium`, white @ 94%.
- Buttons: `headline` weight `bold`, white text, height `48pt`.
- Feature chips: `caption` weight `bold`, height `34pt`, capsule.

### Radii

| Surface | Radius |
| --- | --- |
| Logo tile (login) | `26pt` (compact `22pt`) |
| Form card | `22pt` |
| Mode picker outer | `20pt` |
| Mode picker selected segment | `15pt` |
| Action button (Sign In / Apple) | `15pt` |
| Input field | `16pt` |
| Field icon tile | `10pt` |
| In-app cards (`VineyardCard`) | `14pt` |
| In-app primary buttons | `12pt`, height `50pt` |
| Status / filter chips | capsule |

### Shadows

- Form card: `rgba(0,0,0,0.20)` blur `18` y `10`.
- Mode picker: `rgba(0,0,0,0.18)` blur `16` y `8`.
- Logo: `rgba(0,0,0,0.35)` blur `14` y `8`.
- Action buttons: `rgba(0,0,0,0.22)` blur `14` y `8`.

### Field styling

- White background `#FFFFFF`, 1px border `separator @ 32%`.
- Min height `48pt`, padding `12 / 7`.
- Leading SF Symbol icon in a `#EDF7E8` rounded tile (`32×32`, radius `10`).

---

## 5. Login screen layout (top → bottom)

1. Full-bleed dark green gradient background (see 3.1).
2. Centered logo tile (rounded square, white stroke, shadow).
3. `VineTrack` title + tagline.
4. 3 feature chips in a row.
5. White rounded mode picker (`Sign In` / `Sign Up`).
6. White rounded form card with email + password (and name on sign up).
7. Primary blue action button.
8. `or` divider.
9. Apple Sign-In button (black, rounded 15pt).
10. `Forgot password?` link (sign-in mode).
11. Inline error toast in red @ 82% if auth fails.

Horizontal padding: `18pt`. Top/bottom padding adapts (`10–22pt`) for compact heights.

---

## 6. Web implementation hints (Lovable)

- Use the gradient + radial-highlight stack as the page background.
- Tailwind-ish quick map:
  - `bg-[#054721]` with gradient overlay `from-[#0F6E33] to-[#022C17]`.
  - Card: `bg-white/95 rounded-[22px] shadow-[0_10px_18px_rgba(0,0,0,0.20)]`.
  - Primary CTA: `bg-[#007AFF] text-white rounded-[15px] h-12 font-bold`.
  - Logo: `rounded-[26px] ring-1 ring-white/25 shadow-[0_8px_14px_rgba(0,0,0,0.35)]`.
- Favicon: derive from `vinetrack-app-icon-512.png`.
- Page `<title>`: `VineTrack`.

---

## 7. Don'ts

- Don't display "V2", "VineTrackV2", or any internal target name.
- Don't change the in-app primary action colour from systemBlue to green.
- Don't apply the dark green gradient to in-app screens — it's a **login/marketing** atmosphere only. In-app uses `systemGroupedBackground`.
- Don't recolour the app icon. Use the PNG as-is, with a rounded-rect mask if needed.

---

_This file is documentation only. No Swift, schema, or DB changes._
