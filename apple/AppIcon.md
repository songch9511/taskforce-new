# macOS app icon

Updated 2026-10-07 for the requested native macOS appearance and larger mark.

- Near-black rounded tile with restrained lighting along the upper edge and a soft external shadow.
- Larger white Taskforce mark; transparent pixels outside the tile. At 1024px, the bright mark spans 677px rather than the previous 578px (about 17% wider).
- Master: `Taskforce/Assets.xcassets/AppIcon.appiconset/icon-mac-1024.png`.
- Exports: 16, 32, 64, 128, 256, 512 and 1024 pixels, covering every existing macOS slot in `Contents.json`.
- The iOS icon and shared SVG/menu-bar mark are unchanged.

The built-in `image_gen` tool created the tile using the previous macOS icon as its reference. The final generated image was normalized to 1024 pixels and downsampled with macOS `sips`. No new runtime dependencies are needed. Changes take effect in a newly built app; this asset update does not replace an installed or distributed app.

Validation: all seven PNGs have the expected square dimensions and transparent pixels; 32px and 128px exports were visually inspected. Xcode `actool` compiled the macOS catalog into `AppIcon.icns` and `Assets.car` without warnings or errors. Full application build and installed-app verification were not part of this asset-only change.

## Final refinement prompt

> Make ONE precise edit to this production macOS app icon: increase the WHITE SYMBOL size by 12% around the same visual center. Keep its exact shape, aspect ratio, curves, two strokes, gaps, squared ends and solid white color. Desired white symbol width about 67% of the entire square canvas, currently about 60%. Keep the black rounded-square tile, its shape, position, size, understated gradient, subtle edge lighting, and transparent background unchanged. No rotation, no perspective, no added details, no text. Deliver a standalone square PNG app icon with genuine alpha transparency outside the tile, ideally 1024 x 1024. This is an edit of the supplied image, not a new concept.

## Regenerate smaller sizes

From the repository root, after updating the 1024px master:

```sh
for size in 16 32 64 128 256 512; do
  sips -z "$size" "$size" \
    apple/Taskforce/Assets.xcassets/AppIcon.appiconset/icon-mac-1024.png \
    --out "apple/Taskforce/Assets.xcassets/AppIcon.appiconset/icon-mac-$size.png"
done
```
