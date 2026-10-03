# /// script
# requires-python = ">=3.12"
# dependencies = ["cairosvg==2.8.2"]
# ///
"""Export the editable SVG to the macOS AppIcon asset catalog."""

import json
from pathlib import Path

import cairosvg


def main():
    root = Path(__file__).resolve().parents[1]
    source = root / "assets/icon/ps5-mcp.svg"
    catalog = root / "app/Assets.xcassets/AppIcon.appiconset"
    catalog.mkdir(parents=True, exist_ok=True)
    images = []
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            filename = f"icon_{size}x{size}@{scale}x.png"
            cairosvg.svg2png(
                url=str(source),
                write_to=str(catalog / filename),
                output_width=size * scale,
                output_height=size * scale,
            )
            images.append({
                "idiom": "mac",
                "size": f"{size}x{size}",
                "scale": f"{scale}x",
                "filename": filename,
            })
    (catalog / "Contents.json").write_text(
        json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n"
    )
    print(f"Exported {len(images)} app icon sizes from {source.name}")


if __name__ == "__main__":
    main()
