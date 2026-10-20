# Cluvia Brand

A clear view of your Kubernetes world.

## Logo

| File | Use |
|------|-----|
| `cluvia-logo.svg` | Mark + wordmark on light surfaces |
| `cluvia-logo-dark.svg` | Mark + wordmark on dark surfaces (white wordmark, white hub node) |
| `cluvia-mark.svg` / `cluvia-mark-dark.svg` | Mark alone, light / dark surfaces |
| `cluvia-app-icon.svg` / `cluvia-app-icon-dark.svg` | App icon on the macOS icon grid (824 pt tile on a 1024 canvas) |

The mark is a cloud of three lobes (Cobalt Blue to Cyan Teal) with a node graph cut out of it: the links
are gaps, so they always show the surface behind. Keep clear space around the logo of at least the hub
node's diameter, and do not recolor, rotate or add effects to it.

The wordmark is outlined from Outfit Bold (SIL Open Font License 1.1); the dot of the i is a Cobalt Blue
circle. The SVGs need no installed font.

## Colors

| Name | Hex | Role |
|------|-----|------|
| Midnight Navy | `#0F172A` | Text, dark surfaces — trust, depth, focus |
| Cobalt Blue | `#2563EB` | Accent, primary actions — progress, clarity |
| Cyan Teal | `#14B8A6` | Infrastructure, health, flow |
| Mist Gray | `#E2E8F0` | Borders, structure |
| Cloud White | `#F8FAFC` | Light surfaces |

The app accent color is Cobalt Blue, lifted to `#3B82F6` in dark mode for contrast
(`Cluvia/Assets.xcassets/AccentColor.colorset`).

## App icon

`scripts/render-app-icon.sh` renders `cluvia-app-icon.svg` into
`Cluvia/Assets.xcassets/AppIcon.appiconset` (needs `rsvg-convert`). Re-run it after editing the icon.
