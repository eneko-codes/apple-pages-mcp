# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule

Do not open, read, modify, save over, or close-with-saving a document the owner wrote.

**Tests run against fakes** — in-memory doubles, fixtures, data invented for the test. Never the owner's real Pages documents, and never out of convenience: the suite exists to catch breaking changes and does not need real data to do that.

**Debugging against live data is legitimate, but it is the owner's call, not yours.** Never decide it alone. Ask in chat as an explicit choice they can pick — not a remark inside a longer message — saying exactly what you will run, exactly which live data it would touch, and what it would create, change or delete and whether that is undoable. A yes covers that run only; a wider or different check needs a fresh question.

**Then take the gentlest route that answers it:** read without writing; failing that, create your own disposable document and work on that; failing that, ask the owner to make a throwaway one. A disposable document must be created fresh through `create_document`, never opened from an existing file, and must be discarded in the same session.

**Pages autosaves. "Close without saving" is not enough on its own.** Verified live while building this server: a brand-new document is written into `~/Library/Mobile Documents/com~apple~Pages/Documents/` by Pages itself, on its own schedule, within a couple of seconds of `make new document` — before any explicit save, and closing it afterward with `saving:no` does **not** remove that file. Three stray `Untitled*.pages` files were found in the owner's real iCloud Pages folder during this project's own research, left behind by exactly this. After any disposable document, check that folder (and `~/Documents` if iCloud Desktop & Documents is off) for a file matching what you made, and move it to Trash — never assume closing without saving cleaned up after itself.

## What this is

A local MCP server (Swift 6, stdio transport) exposing the macOS Pages app through Apple events. No network, no credential, no cloud API — iCloud is only the sync engine, gated by TCC consent for Automation. Pages must already be running; this server never launches it.

The App Store lists the app as **"Pages Creator Studio"** — verified to be the same app: `CFBundleIdentifier` is `com.apple.Pages`, Apple-signed, and its scripting dictionary is titled "Pages Terminology" with the standard iWork suites. Treat the two names as one app throughout this repo; the display name is what shows in permission dialogs and System Settings, not the bundle identifier this code keys on.

## Apple technology

Pages ships no framework an external process can use, so everything is an Apple event. [ScriptingBridge](https://developer.apple.com/documentation/scriptingbridge) — `SBApplication`, `SBElementArray`, `SBObject.sendEvent:id:parameters:` — for every read and write; `AEDeterminePermissionToAutomateTarget` ([Apple Events](https://developer.apple.com/documentation/coreservices/apple_events)) to check consent without sending an event; [AppKit](https://developer.apple.com/documentation/appkit) `NSWorkspace`/`NSRunningApplication` to see whether the app is there and running. Consent key: [`NSAppleEventsUsageDescription`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription).

**One thing Pages needed that Notes did not.** Pages' `body text` is declared in its own dictionary as a "rich text" object, not as plain text — confirmed by generating the real `sdp`-produced header (`sdef "/Applications/Pages Creator Studio.app" | sdp -fh`) and by a standalone Objective-C probe against the running app: declaring the property `NSString *` in a hand-written protocol does **not** coerce it, it still comes back as an opaque `SBObject`. Reading it as text needs the same coercion AppleScript's `as text` performs — a `core`/`getd` Apple event carrying a `keyAERequestedType` parameter of `typeUnicodeText`, sent explicitly with `SBObject`'s public `sendEvent:id:parameters:`. See the comment above `plainText:` in `PagesBridge.m`.

## Native surface not used

`sdef "/Applications/Pages Creator Studio.app"` is the authority on what is possible here — or generate the real Objective-C header with `sdp -fh` before hand-declaring a new protocol member, and check it against the running app the way the comment at the top of `PagesBridge.m` describes.

- Table, cell, shape, image and chart manipulation — the dictionary exposes plenty (sort, merge, cell values and formulas, rotation, opacity...) and none of it is wired up. `document_get` reports counts only.
- `set password` / `remove password` — exist in the dictionary. Not exposed: this server refuses password-protected documents outright rather than handle a password as an argument, matching `apple-pdf-mcp`'s stance on encrypted PDFs.
- The `TPDocumentBackgroundExportIntent` Shortcuts action (export a closed document to PDF/Word without opening it) — a real capability gap the sdef `export` command can't fill, decoded from `Metadata.appintents/extract.actionsdata` in the app bundle. Not built: it needs a `.shortcut` a person installs by hand (`shortcuts` has no import command), and there is no existing Shortcuts-invocation pattern anywhere in this project's sibling repos to mirror. Worth adding later, deliberately, not as an afterthought.
- Application-level `selection` and any window property — reading what the owner has on screen, or moving their windows, is not this server's business.

## Commands

```bash
swift build
swift build -c release
swift test
```

```bash
otool -P .build/release/apple-pages-mcp | grep NSAppleEventsUsageDescription
```
