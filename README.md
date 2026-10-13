# Flick

English | [中文](README-zh.md)

A minimal, read-only image viewer for macOS — a lightweight Pixea-style alternative for people who just want to *look* at pictures. No editing, no annotations, no filters, no deleting.

<!-- TODO: screenshot

<img width="700" alt="Flick" src="..." />
-->

- Immersive browsing: the window hugs the image, chrome (toolbar capsule, bottom controls, status strip) only appears while the pointer is over the edges
- Floating filmstrip (T): a panel pinned to the bottom of the screen — it never shifts when the window resizes, so consecutive thumbnails stay under the cursor
- Animated images: GIF / APNG / animated WebP play on a GPU layer (P to pause), rotate while playing
- Info panel (⌘I): floating translucent inspector with file + image + EXIF/TIFF/GPS fields, missing data simply hidden
- Context menu: Open With, Show in Finder, Copy, Print… (⌘P), Set as Desktop Picture
- Large images: >4096 px sources decode downsampled first, full resolution swapped in when you zoom past the tier
- Trackpad: two-finger swipe to flip pages (rubber-bands at the bounds), pinch to zoom anchored at the cursor
- Window follows the image's size and aspect ratio (clamped to the screen), centers on change
- English and Chinese UI (follows system language)
- Zero third-party dependencies; pure SwiftPM — no Xcode project, no storyboards, no asset catalogs
- Universal binary (Apple Silicon + Intel); macOS 15+

## Download & First Launch

1. Download `Flick.zip` from the latest **Release** (CI builds and publishes it when a `v*` tag is pushed);
   for development builds, grab the artifact from the latest successful **Actions** run.
2. Unzip to get `Flick.app`, drag it to `Applications` or anywhere you like.
3. **The app is ad-hoc signed (no Apple Developer certificate), so Gatekeeper will block the first launch.** Either:
   - Right-click `Flick.app` → **Open** → click "Open" in the dialog; or
   - Remove the quarantine attribute in Terminal (then double-click works):
     ```bash
     xattr -dr com.apple.quarantine /path/to/Flick.app
     ```

## Usage

Open images by:

- `Flick /path/to/image_or_folder` from a terminal
- ⌘O open panel (multi-select files, or pick a folder)
- Drag files / a folder onto the window or the Dock icon
- Finder "Open With" / double-click (declared Viewer role for common image UTIs)

Opening a single image browses every image in its folder and lands on that file; opening a folder shows the first image; dropping several files browses just those. Subfolders are not recursed, hidden files are skipped. On an empty window, double-clicking the canvas also opens the picker.

| Key | Action |
|---|---|
| ← / →, Space / ⇧Space | Previous / next image |
| Home / End | First / last image |
| Two-finger horizontal swipe | Flip pages (animated; rubber-band at ends) |
| Pinch, drag, double-click | Zoom at cursor, pan when zoomed, fit ↔ 100% |
| ⌘= / ⌘- | Zoom in / out |
| ⌘0 / ⌘1 / ⌘2 | Fit window / actual size / fill window |
| ⌘R / ⇧⌘R | Rotate 90° right / left (view only) |
| P | Pause / resume animation |
| ⌘I | Info panel |
| T | Filmstrip (floating panel at the bottom of the screen) |
| ⌘P | Print |
| F or ⌃⌘F, Esc | Enter / exit full screen |
| ⌥⌘R, ⌘C / ⌥⌘C | Reveal in Finder, copy image / copy file path |

Sorting (View → Sort By): name / date modified / date created / size, ascending or descending.
Background (View → Background): dark gray / black / system. Wrap-around browsing and
"keep rotation across images" are optional toggles in the View menu.

## Development / Building (no Xcode required)

```bash
swift build                # debug build
./Scripts/test.sh          # unit tests (wraps `swift test` for CLT-only machines)
./Scripts/build_app.sh     # produces Flick.app + Flick.zip (universal, ad-hoc signed)
```

`Scripts/test.sh` exists because Command Line Tools without Xcode can't find
`Testing.framework` by default — the script adds the needed `-F` / rpath flags.

CI: the workflow runs on `v*` tags (or manual dispatch) — build, test, package
`Flick.zip`, upload the artifact, and create a GitHub Release.

## Implementation Notes

- **Layers**: `FlickCore` (pure logic — folder scanning & sorting, navigation state, decode/downsampling, thumbnail store, swipe state machine, metadata reader) is unit-tested with swift-testing; `Flick` is the AppKit shell.
- **Decode**: `CGImageSource` tiered decoding — display tier ≤4096 px, full-resolution fetch on demand when zoom exceeds the tier; `realSize` always reflects the source so 100% means true pixels.
- **Animation**: frames decode once into a `CAKeyframeAnimation` on the image layer — rotation/zoom never re-decodes.
- **Filmstrip**: a child `NSPanel` docked to the screen's bottom edge — independent of the image window, so window resizes never move the thumbnails. Inside it, a horizontal `NSCollectionView` is panned manually (no `NSScrollView`, hence no scrollbars); the highlight ring is data-driven so cell reuse can't leave stale rings.
- **Localization**: strings live in code via `L10n.s(en, zh)` — no `.lproj` bundles since there's no Xcode resource step.

## Known Limitations

- Dropping a folder *and* files together prefers the folder.
- Rare RAW extensions depend on system ImageIO UTI recognition and may be skipped.
