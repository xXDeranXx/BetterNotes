# Notes App: Spec

Working title: **Inkbook** (rename any time).

## Goal
A personal handwriting notes app for the iPad with the Apple Pencil Pro, replacing Goodnotes. It holds notebooks (blank, lined, grid or dotted pages) and imported PDFs (lecture slides, exercise sheets) in one format, lets the developer write and draw on every page, manage pages freely, organize everything in folders, and export finished notebooks as normal PDFs (for example into the Obsidian vault).

## Constraints
- **Native iPad app** in Swift. No web technologies: handwriting latency is the main quality goal, and only Apple's PencilKit reaches it.
- **iPad only**, landscape and portrait. No iPhone or Mac version.
- **No sync between devices, no handwriting search.** Both are out of scope (see "Out of scope").
- **Free Apple developer account** (personal team). Consequences that the design must respect:
  - The app is installed from Xcode and stops launching after 7 days until it is installed again. Reinstalling over the existing app **keeps all data**.
  - **Deleting the app from the iPad deletes all notebooks.** The app must make backups easy (milestone 6), and the README must warn about this.
  - No iCloud, no push notifications, no app groups. If a feature needs a paid account, flag it before building.
- **Apple frameworks only**: SwiftUI, UIKit (where SwiftUI has no equivalent), PencilKit, PDFKit, UniformTypeIdentifiers, PhotosUI, AVFoundation (later). No third-party dependencies unless discussed first.
- All data lives in the app's Documents folder and is **visible in the Files app**, so the developer can always copy it out by hand.
- The developer is a CS student who knows JavaScript and basic React but is **new to Swift, SwiftUI, UIKit, PencilKit and PDFKit**. Prefer readable, idiomatic code over clever code (the developer reviews everything the AI writes), and explain non-obvious concepts when introducing them.

## Rules for the AI assistant (Claude Code)
1. Before starting a milestone, read this spec, write a short plan for the milestone, and **ask about anything that is unclear or not decided here** before writing code. Check "Open questions" for questions that belong to this milestone, and "Rules learned" before touching an area; the full history of every decision is in `docs/DECISIONS.md` (read only the part for the area you change).
2. When introducing a new concept (a SwiftUI property wrapper, `UIViewRepresentable`, a delegate, the responder chain, `UndoManager`, file coordination), explain it in 2–5 sentences in the chat, with a comparison to React or JavaScript where one helps.
3. Keep changes small and focused. One milestone = one or more git commits with clear messages.
4. **Never risk notebook data.** All writes are atomic; no code path deletes user files except the trash (see "Data safety"). Any migration of the file format keeps a copy of the old version until it succeeded.
5. Write tests for the logic layer (file format, page operations, template generation, shape recognition, export). UI tests are not required.
6. Things that only show on a real iPad with a Pencil (latency, palm rejection, coordinates while zooming, squeeze) cannot be verified in the simulator. Say so, and give the developer a short checklist to try on the device.
7. If something in this spec looks wrong, risky, or much harder than it reads, say so instead of silently working around it.

## Stack
- **Swift 6, SwiftUI** app lifecycle; UIKit views wrapped with `UIViewRepresentable` where needed (`PDFView`, `PKCanvasView`)
- **PDFKit**: `PDFView` shows every notebook; `PDFPageOverlayViewProvider` puts one `PKCanvasView` over each visible page
- **PencilKit**: ink, eraser, lasso, `PKToolPicker`
- **Swift Testing** (or XCTest) for unit tests
- Minimum iPadOS 27.0; Swift 6 with main-actor isolation by default; English only
- Xcode on the developer's Mac, git, GitHub

## Core idea: every notebook is a PDF
There is only one kind of document. A blank notebook is a PDF the app generates from page templates; an imported PDF is used as it is. Adding a page means inserting a page into the PDF. Ink is **never** written into the PDF while working; it is stored next to it and only merged on export. This keeps the original file untouched and all ink editable.

## File format
A notebook is a folder with the extension `.inkbook`, declared as an exported type that conforms to `com.apple.package`, so it looks like one file in the Files app.

```
Documents/
├── Uni/                          ← library folders are real folders
│   └── Analysis/
│       └── Lecture 3.inkbook/
│           ├── document.pdf      ← the pages (imported or generated)
│           ├── meta.json         ← see below
│           ├── drawings/
│           │   └── <pageID>.drawing   ← PKDrawing.dataRepresentation()
│           ├── objects/
│           │   └── <uuid>.jpg / .png  ← inserted images (JPEG or PNG, see "Rules learned")
│           └── thumbnails/            ← cache, may be deleted any time
├── .Trash/                       ← deleted notebooks and folders
└── .library.json                 ← favorites, recents, sort choice
```

`meta.json`:
- `formatVersion` (starts at 1; any change to the format increases it and comes with a migration)
- `id`, `title`, `createdAt`, `updatedAt`, cover color
- `pages`: an ordered list, one entry per PDF page, **in the same order as the pages in `document.pdf`**: `id` (random UUID), `template` (`pdf` for imported pages, otherwise `blank`, `lined`, `grid`, `dotted`), page size, rotation
- `objects` (format version 2): images and text boxes, stored in each page's entry, with position and size in **page coordinates** (points, top-left origin, y down, the same as ink; see `PageGeometry`)

Rules:
- Ink and objects belong to a **page id, never a page number**. Reordering, inserting and deleting pages only changes the order of `pages` and of the pages in the PDF.
- On every open, the app checks that `pages` and `document.pdf` have the same count. If not, it repairs what it safely can, and otherwise opens the notebook read-only with a message. It never deletes drawings it cannot assign; it keeps them.
- Drawings are stored in page coordinates, so they stay in place at any zoom level and survive rotation.

## Data safety
- **Autosave**, never a Save button: a changed page's drawing is written about 2 seconds after the last stroke, when its overlay leaves the screen, when the notebook closes, and when the app goes to the background.
- Only changed files are written. `document.pdf` is rewritten only after page operations.
- Every write is **atomic** (write to a temporary file, then replace). A crash leaves either the old or the new file, never half of one.
- Deleting a notebook or folder moves it to `.Trash`. The trash can be emptied by hand and removes items older than 30 days.
- When the app returns to the foreground it rescans the library, because files can change in the Files app while it is in the background.
- A notebook is open in at most one window at a time. Opening it a second time brings the existing window to the front.

## Architecture decisions
These are fixed in milestones 1 and 2 so that later milestones add to the code instead of rewriting it. Changing one of them later needs a discussion first.

1. **Undo works on data, not on canvas objects.** Canvases are created and dropped while scrolling (lazy loading), so no undo step may point at a `PKCanvasView`. Each notebook window has one `UndoManager`; every undo step changes the notebook model (a page's `PKDrawing` by page id, the page list, an object), and visible canvases update from the model. PencilKit's own undo registration is turned off or replaced so that it never holds a canvas. Strokes (M2), page operations (M4), shapes (M7) and objects (M8) all use this one mechanism.
2. **One model, many views.** A `Notebook` model (pages, drawings by page id, objects) is the single source of truth while a notebook is open. Canvases, thumbnails, the page grid and export read from it; autosave writes it to disk.
3. **The page overlay is a layered container**, not a bare canvas: from bottom to top an objects layer (empty until M8), the `PKCanvasView`, and a preview layer (for live shapes in M7). Later features add content to a layer, not new view structure.
4. **One page renderer.** A single function renders a page (PDF page, objects, ink) at a given size. Thumbnails (M4) and export (M6) both use it, so anything new on a page (objects in M8) appears in both automatically.
5. **State per window.** The app supports multiple windows from milestone 1. The open notebook, its model, its `UndoManager` and the editor state belong to a window (scene), never to a global singleton. A notebook is open in at most one window (see "Data safety").
6. **Coordinates**: ink, objects and shapes are stored in page coordinates. Conversion between view and page coordinates lives in one place and is tested.

## Version 1 features

### 1. Writing
- **Goodnotes-style tools and customization** (Milestone 7a): a custom toolbar with several editable pens (fountain, ballpoint, brush-like, pencil), highlighter/marker, eraser, lasso, ruler, and shape tool; each pen has its own saved color and width, a row of favorite colors, a stroke preview, and the toolbar can be moved and collapsed. Built on PencilKit's `PKInkingTool` types; what PencilKit cannot do (for example custom brush textures) is listed in the milestone instead of faked.
- PencilKit ink with the system tool picker: pen, marker, pencil, eraser (stroke and pixel), lasso (move, resize, copy, paste, delete), ruler, colors and widths.
- **The Pencil writes, fingers scroll and zoom** (`drawingPolicy = .pencilOnly`). A setting allows finger drawing.
- **Undo and redo** for strokes, objects **and** page operations in one history per notebook window. Two-finger tap = undo, three-finger tap = redo (configurable).
- **Pencil Pro**: squeeze shows the tool palette near the Pencil; double tap follows the system setting (for example switch to the eraser).
- **Shape recognition while holding** (important to the developer): draw a line, rectangle, ellipse or triangle and hold the Pencil still for about 0.5 s **without lifting**. The stroke turns into a clean shape **immediately**, while the Pencil is still down, and keeps following the Pencil until it is lifted (a straight line can be lengthened and rotated, a shape resized). On lift the shape becomes a normal `PKStroke` in the same color and width, so eraser, lasso and undo work as usual. A setting turns it off.
  - PencilKit has no public API to change a stroke in progress. Planned approach:
    1. A custom gesture recognizer runs **simultaneously** with `PKCanvasView.drawingGestureRecognizer` and reads the Pencil's points live (page coordinates).
    2. A hold is detected when the Pencil stays within a few points for about 0.5 s; the points so far are classified as line, rectangle, ellipse or triangle (or nothing).
    3. The PencilKit stroke in progress is cancelled (for example by toggling `drawingGestureRecognizer.isEnabled`); **whether this discards the half stroke cleanly is verified by a spike in milestone 2**.
    4. A preview layer above the canvas draws the shape and follows the Pencil.
    5. On lift, a `PKStroke` built from the shape is added to the drawing and registered with the undo history.
  - **Fallback** if step 3 is not reliable: detection after the stroke ends, using the stroke's point time offsets to detect the hold at the end, and replacing the stroke. The classification code is the same in both variants.
- Vertical continuous scrolling through all pages.

### 2. Notebooks and PDFs
- New notebook: title, template (blank, lined, grid, dotted), size (A4 portrait default, A4 landscape), cover color.
- Templates are drawn as vector lines into the generated PDF pages, so exports show them.
- Import PDFs from the Files app, from the share sheet ("Open in Inkbook") and by drag and drop from another app in Split View.
- Imported PDFs: write on every page; PDF text search inside the open notebook (`PDFDocument.findString`), with results highlighted.
- Large PDFs (300+ pages) open in under 2 seconds; only visible pages have a canvas in memory.

### 3. Page management
- Page sidebar in the editor (thumbnails, tap to jump).
- Page grid view: select one or several pages; drag and drop to reorder.
- Insert a page before or after with a chosen template; add a page at the end with one tap.
- Duplicate, delete, rotate pages.
- Insert pages from another PDF; insert a photo or image file as a new page.
- Move or copy selected pages to another notebook.
- Page thumbnails show the page with its ink (rendered in the background and cached).
- All page operations can be undone.

### 4. Objects on pages
- **Images**: insert from Photos, Files or the clipboard; move, resize, delete.
- **Text boxes**: tap to place, type with the keyboard, move, resize, font size, delete.
- Objects lie **below** the ink, so ink can be written on top of them.
- PencilKit's lasso only selects ink. Objects are selected with a separate tap (or an "objects" mode); this limitation is accepted.

### 5. Library
- Nested folders: create, rename, move, delete (to trash). **Folder icons**: each folder can get a symbol (book, school, atom, ...) and a color, shown on a drawn folder icon.
- Notebooks: rename, move, duplicate, delete (to trash), change cover.
- Grid view with covers or first-page thumbnails; sort by name, date modified or date created.
- Favorites and "Recently opened".
- Search by notebook and folder title.

### 6. Export and backup
- Export a notebook (all pages or the selected pages) as a **flattened PDF**: original pages stay vector, ink is merged on top (method (b): `UIGraphicsPDFRenderer` through `PageRenderer`, see `docs/DECISIONS.md`, "M6, export").
- Share via the share sheet, or **save to a remembered export folder** (for example a folder in the Obsidian vault), stored as a bookmark so it needs no picker every time.
- **Library backup**: the whole Documents folder (without thumbnails) as one ZIP file through the share sheet, created with `NSFileCoordinator` (`.forUploading`), so no ZIP library is needed. Restore: unzip in the Files app and import the folder (an "Import folder" action in the library).
- A gentle reminder in the library when the last backup is older than 14 days.

### 7. Daily use
- **Multiple windows / Split View**: for example lecture slides on the left, own notebook on the right.
- Dark mode for the interface; pages stay white.
- Empty states, loading states, and error messages that say what happened and what to do; nothing is sent anywhere.

## Later, one at a time
- **Tabs like Goodnotes** (designed 2026-10-23, full design in `docs/DECISIONS.md`, "Tabs, design"): several notebooks as tabs in one window. Only the active tab has a `PDFView`, canvases and render work; never keep several `PDFView`s alive. No tab limit; the 3 most recent tabs keep their `Notebook` model and undo, older ones are released to URL, title, scroll and zoom (number measured with the debug overlay). A Home button shows the library and the tabs stay; opening from the library makes a new tab. The strip shows whenever a tab is open (× to close, drag to reorder, Close Other Tabs), and tabs are restored on launch (`@SceneStorage`). Library actions on a background tab are allowed (the tab is released and follows the new place). `WindowSession` holds tabs; `OpenNotebookRegistry` records window and tab, and a tab counts as open while it exists. Built after the debug overlay, before M9.
- **Whiteboard / infinite canvas** (designed 2026-10-23, see `docs/DECISIONS.md`, "Whiteboard, design"): one `PKCanvasView` as its own scroll view (about 10000 x 10000 pt, one `PKDrawing`), objects in a layer below it, a `.inkbook` with `kind: whiteboard` (format version 4). Starts with a spike on the iPad (memory, heat, frame rate with a lot of ink) using the debug overlay.
- **Scan documents** (wish, 2026-10-23): a "Scan Document" action in the library's "+" menu and in the page insert menu. Uses VisionKit's `VNDocumentCameraViewController` (Apple, free, needs a camera usage text `NSCameraUsageDescription` in `BetterNotes/Info.plist`; VisionKit is not on the framework list under "Constraints", so this entry is the discussion). Each scanned page is an image, so it reuses "image as a page" from M4 (a new notebook from the scan, or pages inserted after the current page). **Compression** (decided 2026-10-23): a camera scan is a photo of about 12 megapixels, and every page operation rewrites the whole `document.pdf` (see M4, save time on image-heavy PDFs, not yet measured), so scans are made small on purpose: shrink to about 200 dpi (1654 px wide for A4; the existing `makeImagePage` allows about 290 dpi), compress as JPEG at quality about 0.7, and make sure the PDF really embeds the JPEG (UIKit's PDF renderer does not guarantee it; a test checks the size of a scanned page). A first probe with a synthetic image gave 848 KB per page but was too compressible to be representative; measure a real scan on the iPad and then decide whether a quality setting (high, normal, small) is needed. Text recognition is out of scope (see "Out of scope"). The simulator has no camera, so it can only be checked on the iPad. Small; fits right after M6.
- **Debug overlay** (built 2026-10-23, to be deleted later; see `docs/DECISIONS.md`, "Debug overlay"): a panel on every screen with CPU, memory, FPS, thermal state, canvases, `k` and loaded drawings, plus CSV recording. It is switched on with "Show debug overlay" in the toolbar settings. To remove it, delete `Debug/`, `DebugOverlayTests`, `.debugOverlay()` in `RootView` and the "Debug" section in `ToolbarSettingsView`. GPU use cannot be shown (no public API).
- **Known small bugs, not urgent** (developer, 2026-10-23: "I can live with it"):
  - **Undo flickers a little** on pages with translucent ink (filled shapes, highlighter). Undo and redo still swap in a fresh canvas (see "Undo bug" and "Undo flicker fixed"), and PencilKit reports "rendered" a moment before the ink is really on screen. Ideas: a longer grace period while the new canvas waits at opacity 0.01 (cheap now, because a stroke that starts finishes the swap at once), or find a way to reset PencilKit's own copy of the strokes so undo needs no swap at all (the swap-free path already works for adding shapes).
  - **Triangles on rotated pages** point sideways on screen (see `docs/DECISIONS.md`, "M7a, shape tool").
  - **Objects on rotated pages** (M8, expected, not yet seen on the iPad): objects are stored on the unrotated page and turn with it, so an image or text box inserted onto a page that is already turned (for example an imported slide with /Rotate 90) shows sideways. Fix: give objects their own rotation, set to undo the page's rotation when inserted.
- **Zoom window** for writing small text (like Goodnotes' zoom box).
- **Audio recording** synced to the ink: tap a stroke to play from that moment. Feasible because `PKStrokePath` stores a creation date; recordings store their start time.
- **Links** between pages and notebooks.
- Horizontal page-by-page scrolling as an option.
- More templates (Cornell notes, music staves) and custom templates from a PDF.
- (A custom pen toolbar is now Milestone 7a.)
- Presentation mode with a laser pointer.

## Out of scope
- Sync between devices, iCloud
- Handwriting recognition and handwriting search
- iPhone and Mac versions
- Sharing or collaborating with other people
- App Store release


## Open questions
Still open (everything decided so far is in `docs/DECISIONS.md`):
- **M6, export method:** compare (a) `PDFAnnotation` ink and (b) re-rendering (in use) on a real lecture PDF with ink: size, sharpness, look in Obsidian. Needs a file from the developer.
- **Not yet measured on the iPad:** heat in normal use (also brush and crayon), eviction on a long notebook, save time after page operations on image-heavy PDFs, opening time of a 300-page PDF.

## Rules learned
The short version of `docs/DECISIONS.md`: rules that code must keep following. When a milestone adds such a rule, add one line here and the full story there.

**Building and testing**
- Prefix commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Run `xcodebuild build` before UI tests (`-only-testing` may run an old app). Always `-parallel-testing-enabled NO`.
- Test rhythm: the touched suite while building; all unit tests before each commit; UI tests only when their area changed (canvas/undo, shapes, objects, editor top bar); the iPad checklist for heat, latency and feel.
- Swift 6, main-actor isolation by default; file and model code that runs off the main thread is `nonisolated`. `Info.plist` lives next to the `.xcodeproj`, outside the synchronized source folder.
- Unit tests with a canvas that is not on screen cannot show PencilKit's behaviour. Changes to canvas setup or syncing need the end-to-end UI tests (`UndoThenWriteUITests`, `ShapeToolUITests`, `ObjectsUITests`) and a "draw, force-quit, reopen" check.
- UI tests: tapping an already selected tool opens its options (tool settings survive launches); `typeText` cannot reach a text view inside PDFView's page (tap `app.keys`); the simulator shares its clipboard with the test.

**Pages, coordinates, rendering**
- One conversion place, `PageGeometry`. Page coordinates (ink, objects, shapes): points, top-left origin, y down, the **unrotated** page. PDFKit gives each overlay the page's size in points at every zoom and enlarges it from outside; for a page with `/Rotate` it gives the unrotated size and turns the overlay. `PDFPage.bounds(for:)` is before `/Rotate`; `PageMeta.size` is the displayed size.
- A page is identified by its `PDFPage` object (`Notebook.pageID(for:)`), **never by its index** (PDFKit asks for overlays in the middle of `insert`). Tests that show pages in a `PDFView` give it `notebook.document`.
- `PageRenderer` is the one renderer (thumbnails, covers, export): white page, PDF vector content, rotation applied once, objects, then ink, always in the light appearance. Export is method (b), ink at 4 px per point. JPEGs (scans, images) go in through `CGImage(jpegDataProviderSource:)` and are embedded unchanged.

**PencilKit canvas**
- `overrideUserInterfaceStyle = .light` on canvases (else black ink shows white in dark mode).
- A canvas gets its final size and zoom **before** its drawing. Sharpness: the canvas is `k` times bigger with `zoomScale = k` and a `1/k` transform, `k = ceil(zoom)` capped at 6; heat caps it at 2 (serious) and 1 (critical).
- **Never assign `canvas.drawing` to change ink the user drew on** (undo, redo): PencilKit keeps its old strokes and brings undone ones back. `PageOverlayView.replaceCanvas()` swaps in a fresh canvas; the old one stays on top until the new one has rendered plus 0.1 s (max 0.6 s), the new one waits at opacity 0.01. Only adding ink (a shape) may assign to the existing canvas. Starting a stroke finishes a pending swap.
- `EditorCoordinator.apply(settings:)` changes nothing when the tool settings did not change (SwiftUI calls it after every stroke and undo).
- Pen ink: a stroke point of size `s` draws `2 x (s - 2)` wide; pen, ballpoint and fountain pen draw nothing at size 2 or less (`InkTemplate.minimumPenSize` 2.5). Built shapes repeat each corner three times (straight edges); fills are rings following the outline. Snapped shapes copy the look of the last stroke with the same pen (`InkTemplate`).
- With the select and text tools the canvas takes **no touches** (`isUserInteractionEnabled = false`); the page's own gestures are hand-written (`ObjectDragGesture`, `PageTapGesture`, `ShapeDragGesture`, `HoldToSnapGesture`). A hold is judged in window points (0.5 s within 4 pt), checked by a timer.

**Saving and data safety**
- Autosave about 2 s after a change, when a canvas leaves the screen, on going to the background and on close; per-page revision counters so a change during a save stays unsaved; a failed save shows Retry and blocks closing. An unreadable drawing is kept as `<id>.drawing.unreadable`.
- `document.pdf` and `meta.json` change together through `pending/` + a `COMMIT` marker (`NotebookPackage.commitStructure`, finished or discarded on open). While a page change is unsaved, `meta.json` is never written alone. Object changes rewrite only `meta.json`.
- A format change bumps `formatVersion` (now 3) and keeps the old file once as `meta.v<N>.json`; an app refuses newer versions. New fields are optional with defaults. Image files in `objects/` are written before the `meta.json` that names them and are never deleted.
- One window per notebook (`OpenNotebookRegistry`); nothing open in a window can be moved, renamed or trashed.
- Tabs: `WindowSession.notebook` is the active tab's model; a tab is released only after a successful save; `EditorView` is keyed by tab id and writes to its own `NotebookTab` (never `session.activeTab`); finish typing (`finishTextEditing`) before every tab switch or close. Drawings of off-screen, saved pages are evicted from memory.
- Library: `.library.json` keys favorites and recents by notebook **id**; a folder's look lives in `.folder.json` inside it; trash items keep `origin.json` for Put Back and are purged after 30 days; name clashes get "Name (2)".

**Objects (images, text boxes)**
- Every object change is one undo step through `Notebook.setObjects`; the selection keeps only ids. Text typed in a box is one step when typing ends, and is put into the model before closing, leaving the app, undo and redo (`finishTextEditing`).
- `TextBoxLayout` is the one place for fonts, padding and line layout (screen, typing, renderer). Text stays a plain string; bold and italic are `styles` ranges in **UTF-16 units**. Rounded and Noteworthy have no italic. Underline is off. Text pasted into a box arrives plain.
- Clipboard: read it only from system paste UI (`PasteButton`, the system Paste `UICommand` from `UIEditMenuInteraction`'s suggested actions, Cmd+V); a custom button that reads it makes iPadOS ask "Allow Paste?". Checking `hasImages` / `hasStrings` does not ask.
- Known limit: objects added to an already rotated page show sideways (see "Later").

**SwiftUI and UIKit**
- A SwiftUI `List` swallows drops: lists and grids that accept drops are `ScrollView` + `LazyVStack`/grid. `onDrop` + `loadFileRepresentation`, and copy the file at once (it is deleted after the callback).
- Confirmation dialogs are attached to the button or tile they belong to (on the iPad they are popovers pointing at it). One `fileImporter` per view.
- No text fields in popovers the Pencil reaches (Scribble types into them): put them behind a dialog.
- Main-thread rendering (thumbnails, covers) pauses while a window animates (`TransitionGate`) and at thermal state serious.
- The developer is left-handed: the Pencil's tool palette opens to the right (a setting).

## Milestones
Each milestone ends with: the app running on the developer's iPad, tests passing, and a git commit. The plans of finished milestones and everything found while building them are in `docs/DECISIONS.md`.

**Done and confirmed on the iPad (2026-10-22/23):**
- **M0** setup, **M1** skeleton (iPad only, Files app, `.inkbook` type, multiple windows).
- **M2** writing in a notebook: file format, model with undo, PDFView with canvases, renderer, autosave.
- **M3** PDF import (Files, "Open in", drag and drop), search, lazy loading.
- **M4** page management: sidebar, grid, reorder, insert, duplicate, delete, rotate, change template, move or copy to another notebook.
- **M5** library: folders with icons, rename, move, trash, covers, favorites, recents, search, grid/list, multi-select.
- **M6** export (flattened PDF, export folder) and backup (ZIP, sizes, Import Folder, reminder).
- **Scan documents** (VisionKit, into a new notebook or as pages).
- **M7a** own pen toolbar (pens, colors, presets, eraser, lasso, ruler, shapes with dash and fill, tap gestures, squeeze palette).
- **M7** hold to snap shapes; **M7b** hold to smooth curves.
- **M8** images and text boxes (Photos, Files, Paste, hold-to-paste, select, move, resize, arrange, fonts, bold and italic).

### Order of work (updated 2026-10-23)
Design talk for tabs and the whiteboard done (2026-10-23). Debug overlay built (iPad check pending). Next: **tabs** -> M9 (polish; "bring the window forward" uses the tab registry) -> the **whiteboard spike**.

### Milestone 9: Daily-use polish
Build: polish for multiple windows and Split View (enabled since milestone 1): opening a notebook that is already open brings its window forward, drag and drop between windows; dark mode, empty and error states, layout checks in both orientations.
Check yourself: use the app for one week of lectures instead of Goodnotes and note what bothers you; that list drives the "Later" features.
