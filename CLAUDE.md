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

## Scripting Bridge quirks found by live verification, not by reasoning about it

Two real bugs surfaced only once this server was actually run against real Pages —
neither is reachable through `FakePageStore`, and both are worth knowing before touching
`PagesBridge.m` again.

**A `filteredArrayUsingPredicate:` result crashes if you read a property off it before
`-get`.** `documentWithIdentifier:ofApplication:` finds a document with `[application.documents
filteredArrayUsingPredicate:...]`. The result's `firstObject` is a lazy "whose" specifier —
its own `-description` prints `whose 'cmpd'{...}`, not a resolved element — and calling
`-id` (or any property) on it directly crashed inside `objc_retain` with `EXC_BAD_ACCESS`.
Reproduced in a standalone single-threaded `main()` with no Swift and no concurrency
involved, ruling out a threading cause before that theory got anywhere. `SBObject.get` —
"forces the current object reference... to be evaluated" — resolves it to a concrete
element first; every property read is reliable after that. The fix is the two lines at the
end of `documentWithIdentifier:ofApplication:`; do not remove them to "simplify" the method.

**`saveIn:as:` and `exportTo:as:` can report success while writing nothing at all.**
Verified twice, independently: redirecting an already-saved document to a new path via the
Objective-C bridge returned with no exception and no `lastError`, left the destination file
absent, and left `document.file` unchanged — and the identical operation via plain
AppleScript (`save d in (POSIX file "...") as Pages format`) threw "AppleEvent handler
failed" for the same document, so this is Pages' own command being unreliable, not a bridge
bug. `saveDocumentWithIdentifier:...` and `exportDocumentWithIdentifier:...` both verify the
destination file actually exists afterwards and raise `PagesBridgeErrorWriteRefused`
explicitly when it does not, rather than trusting the command's own silence. Do not remove
that check to "trust the framework" — it is the only thing standing between a caller and a
false "saved" receipt.

A related, narrower case: a **never-saved** document's first save to a path can instead
*hang* rather than no-op — one real run took the underlying AppleEvent all the way to its
timeout (Pages' own default, measured at ~120s) before failing. `applicationWithError:` sets
`application.timeout = 30 * 60` (ticks, not seconds) for exactly this reason: a stuck call
should fail with a clear message well before it blocks a whole tool call for two minutes.
`close_document` refuses `saving=true` on a never-saved document outright for the same
underlying risk; `save_document`'s first-save case is only bounded by the timeout, not
closed off, because refusing it outright would remove the tool's main reason to exist.

**A document's own `id` is not stable for the life of its window.** Observed live: the same
open document (same window, same content) returned a different `id` from `documents_list`
after being saved. `ToolError.notFound`'s message says so; do not "fix" a test or a bug
report that assumes an id is a permanent handle the way it would be for a database row.

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
