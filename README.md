# BetterNotes (working title: Inkbook)

A personal handwriting notes app for iPad with Apple Pencil. See `SPEC.md` for the full design.

## Read this first

> **Never delete the app from the iPad.** Deleting an app also deletes its
> Documents folder, which holds **all your notebooks**. There is no cloud copy.
> To update or reinstall, always install **over** the existing app from Xcode
> (see below). Make a backup before experimenting (library backup arrives in milestone 6;
> until then copy the BetterNotes folder out of the Files app by hand).

## Requirements
- A Mac with Xcode 27 and an iPad running iPadOS 27 (Developer Mode on).
- Signed in to Xcode with an Apple ID (a free "personal team" is enough).

## Install on the iPad
1. Connect the iPad (cable, or wireless once paired) and unlock it.
2. Open `BetterNotes/BetterNotes.xcodeproj` in Xcode.
3. Pick your iPad as the run destination and press **Cmd+R**.
4. First time only: on the iPad, Settings → General → VPN & Device Management →
   trust your developer certificate.

## The 7-day expiry (free Apple account)
Apps signed with a free personal team expire after **7 days**. After that the app
refuses to launch until it is installed again. Your data is **not** affected:

1. Connect the iPad, open the project in Xcode.
2. Press **Cmd+R** again. Do **not** delete the app first.
3. The app launches again with all notebooks intact.

Do this at the start of every week, or before an important lecture.

## Where your data lives
Everything is in the app's Documents folder, visible in the **Files app** under
*On My iPad → BetterNotes*. You can always copy notebooks out by hand.

## Run the tests
Cmd+U in Xcode, or:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project BetterNotes/BetterNotes.xcodeproj -scheme BetterNotes \
  -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' \
  -only-testing:BetterNotesTests
```
