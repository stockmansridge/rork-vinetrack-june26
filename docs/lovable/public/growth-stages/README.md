# Growth stage reference images — portal copy

Drop this folder (all `el*.webp` files + `mapping.json`) into the Lovable
portal at `public/growth-stages/`. Serve as
`/growth-stages/<file>` and look files up by E-L code via `mapping.json`.

## Provenance

- Same images as both mobile apps. iOS ships them as 1024×1024 lossless PNGs
  in `ios/VineTrack/Assets.xcassets/EL<code>.imageset/`; Android ships the
  identical images as 1024×1024 WebP in
  `android-vinetrack/app/src/main/res/drawable-nodpi/` (pixel diff between
  platforms is compression noise only, mean ~1/255).
- The WebP copies here are the Android set — already web-optimised
  (2.6 MB total vs ~20 MB for the PNG masters). If the portal ever needs the
  lossless masters, use the iOS PNGs.
- XMP metadata on every file: `CreatorTool: Canva (Renderer)` under the
  project owner's Canva account — project-owned artwork, no third-party
  licensing restriction on copying into the portal.

## Display contract (match mobile exactly)

- Only 21 of the 34 E-L stages have a reference image (`mapping.json` →
  `images`). The 13 codes in `stagesWithoutImage` must show a neutral
  placeholder — never reuse another stage's photo.
- Resolution order: a vineyard's **custom uploaded** stage image (Supabase
  `growth_stage_images` + storage) always wins; these bundled files are the
  fallback. This mirrors iOS `resolvedELStageImage(for:)` and Android
  `GrowthStageBundledImages`.
- `EL4` is the app's Budburst stage (`isBudburst` in the mapping).
