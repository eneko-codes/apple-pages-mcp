# Manual verification against real Pages

Everything below runs against **your real Pages**, which is why no agent may run it (see
the hard rule in `CLAUDE.md`). Work through it yourself, in order.

```bash
npx @modelcontextprotocol/inspector ./.build/release/apple-pages-mcp
```

## 0 — Before you start

Note what is currently open in Pages (`documents_list`, once permission is granted below)
so you know what was there before this script touched anything. Every disposable document
this script creates starts its body with `ZZTest` and, if saved, is saved under a name
starting `ZZTest-` — never reuse that prefix for anything you want to keep.

## 1 — Permission plumbing

| Step | Call | Expected |
|---|---|---|
| Quit Pages entirely | — | — |
| Call `pages_status` | `pages_status` | Reports "NOT RUNNING". Pages does **not** launch. |
| Launch Pages by hand, leave no document open if you can | — | — |
| Call `pages_status` again | `pages_status` | Either "not requested yet" or the Automation dialog appears now: *"apple-pages-mcp" wants to control "Pages Creator Studio"*. Approve it. |
| Call `pages_status` once more | `pages_status` | Reports "RUNNING, automation permitted." |
| Deny path: revoke in System Settings → Privacy & Security → Automation, call any tool | `documents_list` | Refused, names the exact System Settings path to fix it. Re-grant before continuing. |

## 2 — Reading what's open

| Step | Call | Expected |
|---|---|---|
| Open one ordinary document you don't mind reading (not editing) | — | — |
| List open documents | `documents_list` | Shows it: name, page count, `id`. |
| Read it | `document_get` with that `id` | Plain text body, counts, no markup. |
| Read it with page breakdown | `document_get` with `by_page: true` | One string per page, `[page N]` markers. |
| Read a nonexistent id | `document_get` with `id: "nope"` | Names "nope" in the refusal, suggests `documents_list`. |

A document's `id` can change on its own while the same window stays open — observed live,
right after a save. If a call you expect to work says "no open document has the id", call
`documents_list` again before assuming the document actually closed.

## 3 — Creating and editing a disposable document

| Step | Call | Expected |
|---|---|---|
| Create one | `create_document` with `body: "ZZTest verification fixture."` | New window opens in Pages; response includes the autosave warning. |
| **Immediately** check `~/Library/Mobile Documents/com~apple~Pages/Documents/` (and `~/Documents` if iCloud Desktop & Documents is off) | Finder or `ls` | An `Untitled*.pages` may already exist there within a few seconds — this is Pages autosaving on its own, not this server. Note its name; you'll delete it in §9 regardless of what happens next. |
| Read it back | `document_get` | Body is exactly what was set. |
| Append | `update_document` with `mode: "append"`, `body: "\nSecond line."` | Both lines present, in order. |
| Replace | `update_document` with `mode: "replace"`, `body: "ZZTest only this now."` | Only the new text remains. |
| Omit `mode` | `update_document` without `mode` | Refused; message says `mode` is required. |

## 4 — Saving and the never-saved guard

**Read this before trusting a "Saved" response.** Verified live, twice: Pages' own `save`
command can report success while writing nothing at all when redirecting an already-saved
document to a new path — no exception, no `lastError`, file untouched. This server checks
the destination actually exists afterwards and raises a clear error when it doesn't, so a
`save_document` call to a **new path on a document that already has one** should now fail
*honestly* rather than silently — expect the "Pages reported no error, but no file exists"
message on the first row below, not a false "Saved". If it ever reports success there
without the file actually appearing, that is a regression in the check, not a pass.

| Step | Call | Expected |
|---|---|---|
| Save an already-saved ZZTest document to a **new** path under `~/Desktop` | `save_document` with `path: "~/Desktop/ZZTest-verification-2.pages"` | Likely refused honestly (see above) rather than a true save — check whether the file actually appears. If it does, `documents_list` should show the new path. |
| Save with no path, on a document that already has one | `save_document`, no `path` | Requires `confirm=true` (this overwrites the existing file); with `confirm: true`, should succeed and the file's modification date should change. |
| Save over a **different**, pre-existing file, no `confirm` | `save_document` with an existing unrelated file's path | Refused: "requires confirm=true". Nothing is overwritten — check the file is untouched. |
| Same, with `confirm: true` | — | **Do not actually run this against a file you care about.** Use a second disposable file instead, to prove the mechanism without real risk. |
| `save_document` with a path, immediately after `create_document`, before any autosave has happened | same | May hang rather than fail — bounded to ~30s by this server's own Apple Event timeout rather than Pages' own ~120s default. If it hangs the full 30s, that is expected per `CLAUDE.md`, not a bug to chase. |
| Close the still-unsaved second create from §3, `saving: true`, no path ever given | `close_document` with `saving: true` | Refused before any event is sent: message explains Pages would show its own save panel. |

## 5 — Exporting

Use the right extension for each format — `export_document` refuses a mismatch upfront —
`pdf`→`.pdf`, `word`→`.docx`, `epub`→`.epub`, `rtf`→`.rtf`, `plain_text`→`.txt`,
`pages09`→`.pages`. Verified live: the extension mattered even before this server started
checking it — Pages' own `exportTo:as:` reported success while writing nothing at all for
a mismatched one.

| Step | Call | Expected |
|---|---|---|
| Export the ZZTest document to PDF, under Desktop | `export_document` with `to: "~/Desktop/ZZTest-verification.pdf"`, `format: "pdf"` | File appears; opens as a real PDF. |
| Export with the wrong extension for the format (e.g. `format: "word"`, `to: ".../x.txt"`) | same, mismatched | Refused upfront: "needs a '.docx' destination". |
| Export over the same PDF again, no `confirm` | same call | Refused: "requires confirm=true". |
| Try every format with its correct extension | `format`: each of `pdf`, `word`, `epub`, `rtf`, `plain_text`, `pages09` | Each produces a file of the right kind. Verified live to also reach a plain `/tmp` path and a brand-new folder under the home directory — wider than Desktop/Documents/Downloads, so do not assume export is confined to those three. |

## 6 — Password-protected documents

Setting a password does not need Pages' own UI — it is a plain scriptable command, which
avoids typing a real password into a dialog for a disposable test fixture:

```applescript
tell application "Pages"
    set d to document id "<the ZZTest document's id>"
    set password "ZZTestPassword123" to d hint "verification test" saving in keychain false
end tell
```

(Note the syntax: `set password "..." to d ...` — not `set <var> to (set password ...)`,
which AppleScript parses as the assignment form and refuses with "parameter specified more
than once".)

| Step | Call | Expected |
|---|---|---|
| Set a password on the ZZTest document (script above, or by hand in Pages) | — | — |
| List and get it through this server | `documents_list`, `document_get` | Listed with a 🔒 marker; `document_get` reports it is locked, no body text. |
| Try to update it | `update_document` | Refused: "password-protected document... refused", explains this server never accepts a password. |
| Try to export it | `export_document` | Same refusal. |
| Remove the password before continuing | `remove password "ZZTestPassword123" from d` | So later steps (closing, cleanup) aren't complicated by it. |

## 7 — Closing

| Step | Call | Expected |
|---|---|---|
| Close the ZZTest document, default `saving` | `close_document` with just `id` | Closes, discarding whatever wasn't saved. No `confirm` needed. |
| Close a **saved** document with `saving: true`, no `confirm` | `close_document` with `saving: true` | Refused: "requires confirm=true". |
| Same, with `confirm: true` | — | Saves and closes. `documents_list` no longer shows it. |

## 8 — Packaging

| Step | Command | Expected |
|---|---|---|
| Build and pack | `bash scripts/pack.sh` | Ends with a `dist/apple-pages-mcp.mcpb` path and size. |
| Check the signature | `codesign -dv dist/../extension/server/apple-pages-mcp` (or re-run and read the printed flags) | `flags=0x2(adhoc)` at minimum — never `linker-signed`. |
| Install the `.mcpb` in Claude Desktop | — | Ten... nine per-tool switches appear, no settings screen. |

## 9 — Clean up

- Delete every file named `ZZTest-*` this script created, on Desktop and anywhere else you
  saved one.
- Check `~/Library/Mobile Documents/com~apple~Pages/Documents/` (and `~/Documents`) one
  more time for any stray `Untitled*.pages` Pages autosaved during this run — §3's warning
  is not theoretical; it is exactly how this project's own research left three such files
  in a real iCloud account before this was noticed. Move each to Trash.
- Quit and relaunch Pages if you want a clean window state again.
