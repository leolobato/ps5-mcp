# PS5 MCP icon

`ps5-mcp.svg` is the editable, reusable source. It contains only vector paths,
shapes, and gradients, with a 1024 × 1024 viewBox and transparent outer corners.
Use it directly on the web (`<img src="ps5-mcp.svg" alt="PS5 MCP">`), in documents,
or in a vector editor.

This SVG is the shared source for app icons on all platforms. The macOS app
uses the PNG exports in `../../app/Assets.xcassets/AppIcon.appiconset`. After
editing the SVG, regenerate them from the repository root:

```sh
brew install cairo
DYLD_FALLBACK_LIBRARY_PATH="$(brew --prefix)/lib" uv run scripts/export-app-icon.py
make app
```

CairoSVG is an isolated export dependency; it is not required to build or run the app.
