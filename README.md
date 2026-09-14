<p align="center"><img src="extension/icon.png" width="128" height="128" alt=""></p>

# apple-pages-mcp

A local MCP server, written in Swift, that gives [Claude](https://claude.ai) access to the [Pages](https://www.apple.com/pages/) app on this Mac — reading, creating, editing and exporting documents through Apple events.

Pages has no framework a separate process can use, so this server drives Pages.app itself — the same route [apple-notes-mcp](https://github.com/eneko-codes/apple-notes-mcp) takes for Notes. The App Store now lists the app as **"Pages Creator Studio"**; that is a display-name change Apple made, not a different app — its bundle identifier, scripting dictionary and everything this server talks to are unchanged.

Not affiliated with or endorsed by Apple Inc.

## Requirements

- macOS 15 or later, with Pages installed
- Swift 6.0+ / Xcode 26 to build
- A stable code-signing identity if you want an Automation grant to survive a rebuild — ad-hoc signing works, but every rebuild becomes a "new" program to TCC and you re-approve it each time (see [Signing](#signing-and-why-it-is-not-optional))

## Tools

| Tool | Kind | What it does |
|---|---|---|
| `pages_status` | read | Availability, Automation permission, configured limits |
| `documents_list` | read | Every document currently open in Pages |
| `document_get` | read | One open document's body text and structure |
| `create_document` | write | New document, optional template, initial body as plain text or styled paragraphs |
| `open_document` | write | Opens an existing `.pages` file by path |
| `update_document` | write | Append (plain text) or replace (plain text or styled paragraphs) a document's body |
| `save_document` | write | Save, in place or to a new path |
| `close_document` | **destructive** | Close, discarding changes by default |
| `export_document` | write | Export to PDF, Word, EPUB, RTF, plain text or Pages '09 |

## The rules worth knowing before you use it

- **Pages has no library.** Unlike Notes' folders, Pages only knows about documents open right now — there is nothing to search. `documents_list` shows what's open; `open_document` opens a file that isn't.
- **`document_get` returns plain text, with no markup option.** Pages' own dictionary types `body text` as rich text with no scriptable string form of the formatting — there is no `html=true` equivalent the way Notes has one. Styling is write-only: you can set a paragraph's look with `paragraphs`, but reading a document back never tells you what style a paragraph has.
- **`paragraphs` gives `create_document`/`update_document` visual styling — headings, quotes — built from font/size/color, not from Pages' own named paragraph styles.** One entry per paragraph, each with a `style` (`title`, `heading1`–`heading3`, `quote`, `body`) mapped to a fixed preset — the entire scriptable surface of a Pages paragraph, confirmed live. It is **not** the same thing as picking "Heading" from Pages' own Format sidebar: confirmed live that no named-style property is scriptable at all (tried `style`, `paragraph style`, and more — see `CLAUDE.md`). A paragraph styled this way **will not appear in a Table of Contents** (built from real named heading styles) and **will not respond to a theme change** — it is indistinguishable, to Pages itself, from selecting text and bumping its font size by hand. `quote` is likewise an approximation (italic, grey); Pages has no real block quote to draw. Tables, shapes, images and charts cannot be created through Pages' scripting interface **at all** — confirmed live, not merely unimplemented (see "Known limits").
- **`update_document` requires an explicit `mode`.** `append` keeps everything already there; `replace` discards the whole body and cannot be undone from here.
- **Password-protected documents are refused outright.** No tool here reads, writes or exports a document Pages reports as locked, and none accepts a password as an argument — the same policy [apple-pdf-mcp](https://github.com/eneko-codes) uses for encrypted PDFs.
- **`save_document` and `export_document` require `confirm=true` to overwrite an existing file.** `close_document` requires it for `saving=true`.
- **Pages autosaves.** A brand-new document is written into iCloud Drive by Pages itself within seconds of creation — before any explicit save, and independently of whether you ever call `save_document`. Closing it with `saving=false` does not undo that. If you made something disposable, delete the file yourself (through the filesystem server, or Finder) — this server has no delete tool of any kind.
- **No delete tool, anywhere.** Removing a `.pages` file from disk is the filesystem server's job, not this one's.
- **A document's `id` can change while it stays open.** Observed live: the same window's id changed after a save. Re-run `documents_list` rather than assuming an id from an earlier call still resolves.
- **`export_document`'s destination must end in the right extension for the format** (`.pdf`, `.docx`, `.epub`, `.rtf`, `.txt`, `.pages` for `pages09`). Pages' own export command reports success and writes nothing at all when the extension doesn't match — this server checks the file actually landed and refuses upfront when the extension is wrong, but the requirement itself comes from Pages, not from here.
- **`save_document` to a new path is the least reliable call in this server.** Verified live: redirecting an already-saved document to a different path can report success while writing nothing. This server verifies the destination file actually exists afterwards and fails honestly when it doesn't; `export_document` with `format: "pages09"` is the more dependable way to get a copy onto disk at a new path.

## Install

### 1. Build the bundle

```bash
git clone https://github.com/eneko-codes/apple-pages-mcp.git
cd apple-pages-mcp
bash scripts/pack.sh
```

This produces `dist/apple-pages-mcp.mcpb`.

### 2. Install it

Open the `.mcpb` file with Claude Desktop, then enable the tools you want in Settings → Extensions.

### 3. Grant the permission

The first time a tool actually calls Pages, macOS shows an Automation dialog: *"apple-pages-mcp" wants to control "Pages Creator Studio"*. Approve it. If you miss it or deny it, grant it by hand in:

```
System Settings → Privacy & Security → Automation → apple-pages-mcp → enable Pages
```

### Signing, and why it is not optional

`swift build` leaves an **ad-hoc, linker-signed** binary. macOS treats `linker-signed` as "signed by nobody": TCC will not register it as a subject at all, so the Automation dialog above never appears and the request just sits as `notDetermined` — a silent failure with no error message to search for. `scripts/pack.sh` always re-signs with `codesign`, which turns that into a plain ad-hoc signature TCC can see.

Plain ad-hoc signing still has no *designated requirement*, so TCC falls back to the binary's hash — and every rebuild produces a new hash, so every rebuild loses the grant. To make a grant durable across rebuilds, sign with a real identity:

```bash
MCPB_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" bash scripts/pack.sh
```

### Preparing something to distribute

Hardened runtime is off by default — it's required for notarisation, not for TCC, and it blocks Apple events unless the entitlement is granted. Opt in with:

```bash
MCPB_HARDENED=1 MCPB_SIGN_IDENTITY="..." bash scripts/pack.sh
```

## Tool switches

Every tool has its own on/off switch in Claude Desktop, populated from `extension/manifest.json`'s `tools` array before the server has ever run. There is no other configuration: numeric limits (like how much body text `document_get` returns by default) are fixed sensible constants in `Configuration.swift`, not settings — the only thing to decide is which tools are on.

## Manual registration instead

If you'd rather run this outside the extension system:

```json
{
  "mcpServers": {
    "apple-pages-mcp": {
      "command": "/path/to/apple-pages-mcp"
    }
  }
}
```

Don't run both registrations at once — Pages would get two Automation subjects to approve instead of one.

## Implementation note: why the Apple events are in Objective-C

Apple documents exactly one way to create a scriptable object: `classForScriptingClass:`, `alloc`/`initWithProperties:`, then insert it into the container's element array. The class that comes back is an `SBPseudoClass`, and a Swift metatype cast against it aborts the process ([swiftlang/swift#43407](https://github.com/swiftlang/swift/issues/43407), open since 2016). In Objective-C the documented pattern just compiles. See `Sources/PagesBridge/PagesBridge.m` — and its sibling in [apple-notes-mcp](https://github.com/eneko-codes/apple-notes-mcp), which this project mirrors exactly.

One wrinkle specific to Pages: `body text` is typed as rich text, not plain text, in Pages' own dictionary — confirmed by generating Apple's real `sdp`-produced header and by a live probe against the running app. Reading it as a string needs the explicit `as text` coercion AppleScript performs automatically, sent by hand through `SBObject`'s public `sendEvent:id:parameters:`. The bridge does this once, in one place; nothing above that seam ever sees the rich text object.

## Known limits

- No library or search — only documents already open, or opened by path.
- No markup access — `document_get` is plain text only, with no formatted alternative.
- No table, shape, image or chart creation — confirmed impossible, not merely unimplemented. Live-tested: `make new table`, `make new shape` and `make new placeholder text` all fail identically with "AppleEvent handler failed", via both the Objective-C bridge and plain AppleScript, across several location/property variants. Pages declares these as elements for *reading* — `document_get` reports their counts — but ships no working "make" handler for any of them. No editing of ones that already exist, either.
- No password handling of any kind — a locked document is refused, not decrypted.
- Opening a password-protected file, or saving/closing a never-saved document, can make Pages show its own blocking dialog. `close_document` refuses `saving=true` on a never-saved document outright; the same risk exists for `save_document`'s first save of a brand-new document and is not fully closed off, only bounded — every Apple event this server sends has a 30-second timeout (Pages' own default is closer to two minutes), so a stuck call fails with a clear error instead of hanging the whole way there.
- `save_document` to a new path is unreliable for a document that already has one — see "The rules worth knowing" above. `export_document` (format `pages09`) is the dependable alternative.
- The exact boundary of Pages' own export sandbox was not fully mapped — plain `/tmp` and a fresh home-directory folder both worked in testing, wider than Desktop/Documents/Downloads. `export_document` verifies the file actually landed rather than trusting Pages' own report, so a real restriction still surfaces as an honest error.
- A document's `id` is not guaranteed stable for the life of the window — see above.

## Development

```bash
swift build
swift test
```

28 tests, all against an in-memory fake — no test here sends an Apple event or touches a real document. That fake cannot reach the bugs `verification.md` is really for: this project's first live run against real Pages surfaced a genuine crash (`objc_retain` on a lazy "whose" specifier — see `PagesBridge.m`'s `documentWithIdentifier:ofApplication:`) and a silent no-op in Pages' own `save`/`export` commands, neither of which any amount of fixture-based testing could have caught. `verification.md` is the script for it.

## Licence

MIT
