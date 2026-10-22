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
1. Before starting a milestone, read this spec, write a short plan for the milestone, and **ask about anything that is unclear or not decided here** before writing code. Check "Open questions" for questions that belong to this milestone.
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
- Minimum iPadOS: see "Open questions" (squeeze needs iPadOS 17.5 or later)
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
│           │   └── <objectID>.png     ← inserted images
│           └── thumbnails/            ← cache, may be deleted any time
├── .Trash/                       ← deleted notebooks and folders
└── .library.json                 ← favorites, recents, sort choice
```

`meta.json`:
- `formatVersion` (starts at 1; any change to the format increases it and comes with a migration)
- `id`, `title`, `createdAt`, `updatedAt`, cover color
- `pages`: an ordered list, one entry per PDF page, **in the same order as the pages in `document.pdf`**: `id` (random UUID), `template` (`pdf` for imported pages, otherwise `blank`, `lined`, `grid`, `dotted`), page size, rotation
- `objects`: images and text boxes per page id, with position and size in **page coordinates** (points, origin as in PDFKit)

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
- Nested folders: create, rename, move, delete (to trash).
- Notebooks: rename, move, duplicate, delete (to trash), change cover.
- Grid view with covers or first-page thumbnails; sort by name, date modified or date created.
- Favorites and "Recently opened".
- Search by notebook and folder title.

### 6. Export and backup
- Export a notebook (all pages or the selected pages) as a **flattened PDF**: original pages stay vector, ink is merged on top (method decided in milestone 6, see "Open questions").
- Share via the share sheet, or **save to a remembered export folder** (for example a folder in the Obsidian vault), stored as a bookmark so it needs no picker every time.
- **Library backup**: the whole Documents folder (without thumbnails) as one ZIP file through the share sheet, created with `NSFileCoordinator` (`.forUploading`), so no ZIP library is needed. Restore: unzip in the Files app and import the folder (an "Import folder" action in the library).
- A gentle reminder in the library when the last backup is older than 14 days.

### 7. Daily use
- **Multiple windows / Split View**: for example lecture slides on the left, own notebook on the right.
- Dark mode for the interface; pages stay white.
- Empty states, loading states, and error messages that say what happened and what to do; nothing is sent anywhere.

## Later, one at a time
- **Zoom window** for writing small text (like Goodnotes' zoom box).
- **Audio recording** synced to the ink: tap a stroke to play from that moment. Feasible because `PKStrokePath` stores a creation date; recordings store their start time.
- **Links** between pages and notebooks.
- Horizontal page-by-page scrolling as an option.
- More templates (Cornell notes, music staves) and custom templates from a PDF.
- A custom favorites toolbar instead of the system tool picker.
- Presentation mode with a laser pointer.

## Out of scope
- Sync between devices, iCloud
- Handwriting recognition and handwriting search
- iPhone and Mac versions
- Sharing or collaborating with other people
- App Store release

## Open questions
1. **M1, app language**: English (like the finance app) or German? Default: English.
2. **M1, minimum iPadOS**: which iPadOS version runs on the developer's iPad? Default: the current major version minus one, but at least 17.5 (squeeze).
3. **M2, tool picker**: start with the system `PKToolPicker` (all tools for free, less control over the look). Default: yes; a custom toolbar is under "Later".
4. **M6, export method**: (a) a `PDFAnnotation` subclass that draws each page's ink, written with `PDFDocument.write`, or (b) re-render every page with `UIGraphicsPDFRenderer`: the PDF page as vector, the ink as an image at 3× scale or more. Decide after testing both with a real lecture PDF (quality, file size, how it looks in Obsidian).

Decided:
- (nothing yet; results of decisions and spikes go here)

## Milestones
Each milestone ends with: the app running on the developer's iPad, tests passing, and a git commit.

### Milestone 0: Setup (done by the developer, not the AI)
- Install Xcode, sign in with the Apple ID (Xcode → Settings → Accounts) to get a free personal team.
- On the iPad: enable Developer Mode after the first install attempt (Settings → Privacy & Security).
- Create a GitHub repository. Put this file in it as `SPEC.md`, and create `CLAUDE.md` with one line: "Read SPEC.md and follow its rules for the AI assistant."

### Milestone 1: Skeleton
Build: SwiftUI app (iPad only), app icon, a placeholder library screen, a test target with one sample test, documents visible in the Files app, the `.inkbook` package type and PDF document types declared, **multiple windows enabled** (architecture decision 5), README with the 7-day reinstall steps and the "never delete the app" warning.
You should be able to explain: the SwiftUI app lifecycle, `@State` vs. React state, what a scene (window) is, how signing with a personal team works and why the app expires.
Check yourself: the app runs on the iPad; two windows of it can be open side by side; its folder appears in the Files app; `Cmd+U` passes the tests.

### Milestone 2: A notebook you can write in (foundation)
This milestone is larger on purpose: it settles all "Architecture decisions". Build in this order:
1. **Spike: cancelling a stroke** (small, on the device, can be thrown away): a `PKCanvasView` with a simultaneous gesture recognizer that detects a 0.5 s hold and cancels the stroke in progress. Report whether the half stroke disappears cleanly (no flicker, no leftover ink). Write the result into "Decided" in this spec; it decides the live variant or the fallback for shape recognition in M7.
2. The file format (create, open, `meta.json` round trip) and template PDF generation.
3. The `Notebook` model and the per-window `UndoManager` working on data (decisions 1, 2, 5).
4. The editor: `PDFView` with a layered overlay container per page (decision 3), the tool picker, Pencil-only drawing; canvases created and dropped through the overlay provider's display callbacks from the start.
5. The page renderer (decision 4) and the coordinate conversion (decision 6), with tests.
6. Autosave and atomic writes.
Tests: `meta.json` encode/decode; generated templates have the right size and page count; an atomic write that fails leaves the old file intact; ink saved and loaded for a page id; undo and redo of strokes on the model; a stroke can be undone after its canvas was dropped; coordinate conversion at several zoom levels.
You should be able to explain: what `UIViewRepresentable` does, how `PDFPageOverlayViewProvider` works, page vs. view coordinates, why undo works on the model and not on the canvas.
Check yourself: write on three pages, zoom in and out (ink stays in place), scroll far away and back, undo strokes on a page that was off screen, force-quit the app, reopen: everything is there.

### Milestone 3: PDF import
Build: import from Files, "Open in" from the share sheet, drag and drop; text search in the open PDF; tuning of the lazy loading from milestone 2 for large PDFs.
Check yourself: import a 300-page lecture PDF; it opens fast; writing on page 250 has no lag; memory stays reasonable while scrolling through all pages.

### Milestone 4: Page management
Build: page sidebar, page grid with multi-select and drag-and-drop reorder, insert/duplicate/delete/rotate, pages from another PDF, image as page, move/copy pages to another notebook, ink thumbnails (through the page renderer), undo for all page operations (through the model's undo).
Tests: every page operation keeps `pages` and the PDF in the same order and keeps ink attached to the right page; undo restores the exact previous state.
You should be able to explain: how `UndoManager` and the responder chain work, why page ids beat page numbers.
Check yourself: reorder pages with ink on them, undo, redo, force-quit, reopen: ink is on the right pages.

### Milestone 5: Library
Build: nested folders, rename, move, duplicate, trash, covers and thumbnails, sorting, favorites, recents, title search, rescan on return to the foreground, the consistency check on open.
Check yourself: build your real folder structure (subjects, semesters); move a notebook in the Files app while the app is in the background; the library shows it at its new place.

### Milestone 6: Export and backup
Build: flattened PDF export (all or selected pages, through the page renderer), share sheet, remembered export folder, library ZIP backup, "Import folder", backup reminder.
Tests: an exported PDF has the same page count and sizes; pages without ink are unchanged.
Check yourself: export a notebook into your Obsidian vault and open it in Obsidian; make a library backup, unzip it in the Files app, import it into a fresh install (on a second test bundle id).

### Milestone 7: Tools and Pencil Pro
Build, in this order:
1. Read the spike result from milestone 2 under "Decided" (live variant or fallback). If it is missing, do the spike first and decide together with the developer before building the rest.
2. Shape classification (line, rectangle, ellipse, triangle) as pure, tested logic.
3. The live preview in the overlay's preview layer that follows the Pencil until lift, and the final `PKStroke` with undo through the model (or the fallback variant).
4. Squeeze and double-tap handling, gesture settings (two/three-finger tap), finger-drawing setting, shape-recognition setting.
Tests: classification with recorded stroke points (line, rectangle, ellipse, triangle; a shaky line still counts; a normal word or letter is never classified as a shape); hold detection (a slow stroke is not a hold; a hold under 0.5 s does nothing); the built `PKStroke` has the source stroke's ink type, color and width.
You should be able to explain: how gesture recognizers run at the same time, how the shape's points are converted between view and page coordinates.
Check yourself: draw straight lines, a table and a diagram for a lecture by holding; lengthen and rotate a line before lifting; zoomed in and out; undo each shape; erase part of a shape.

### Milestone 8: Images and text boxes
Build: insert images (Photos, Files, clipboard), text boxes, move/resize/delete, all in the overlay's objects layer; drawing objects in the page renderer (so exports and thumbnails show them without further changes); undo through the model.
Check yourself: paste a screenshot of a slide into a notebook, annotate it with ink, export it.

### Milestone 9: Daily-use polish
Build: polish for multiple windows and Split View (enabled since milestone 1): opening a notebook that is already open brings its window forward, drag and drop between windows; dark mode, empty and error states, layout checks in both orientations.
Check yourself: use the app for one week of lectures instead of Goodnotes and note what bothers you; that list drives the "Later" features.
