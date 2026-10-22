# Knot mark

The mark uses two rounded loops with alternating over/under crossings. Ivory and muted teal bands on a deep ink rounded tile express separate computers tied into one working environment. The existing Quiet Sidebar layout and semantic interface colors remain unchanged.

## Source and reproduction

- Geometry: `scripts/render_brand_mark.swift`.
- Generated scalable asset: `Assets/Brand/knot.svg`, including an accessible title and description.
- Generated 1024px master: `Assets/Brand/knot.png`; pixels outside the rounded tile are transparent.
- Native containers: `Assets/Brand/AppIcon.icns` and `Assets/Brand/AppIcon.ico`.

On a Mac with the Swift compiler and macOS icon tools:

```sh
python3 scripts/build_brand_icons.py
```

The renderer constructs new vector geometry using CoreGraphics and emits the SVG and PNG. It opens no application, desktop, user image, preferences or network connection. The converter uses sips/iconutil to create app icon sizes. No image-generation service or runtime asset download is needed.

Mac packages include the mark and ICNS, Windows uses the ICO, and the Linux desktop package installs the PNG. Static source-asset inspection does not validate Dock, Start menu, GTK or native display behavior on a user's device.

These project assets are distributed under the repository's GPL-3.0-only license. The simple interwoven-loop motif is not represented as trademark clearance or an exclusive symbol.
