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

## 3 — Creating and editing a disposable document

| Step | Call | Expected |
|---|---|---|
| Create one | `create_document` with `body: "ZZTest verification fixture."` | New window opens in Pages; response includes the autosave warning. |
| **Immediately** check `~/Library/Mobile Documents/com~apple~Pages/Documents/` (and `~/Documents` if iCloud Desktop & Documents is off) | Finder or `ls` | An `Untitled*.pages` may already exist there within a few seconds — this is Pages autosaving on its own, not this server. Note its name; you'll delete it in §6 regardless of what happens next. |
| Read it back | `document_get` | Body is exactly what was set. |
| Append | `update_document` with `mode: "append"`, `body: "\nSecond line."` | Both lines present, in order. |
| Replace | `update_document` with `mode: "replace"`, `body: "ZZTest only this now."` | Only the new text remains. |
| Omit `mode` | `update_document` without `mode` | Refused; message says `mode` is required. |

## 4 — Saving and the never-saved guard

| Step | Call | Expected |
|---|---|---|
| Save to a path under `~/Desktop` | `save_document` with `path: "~/Desktop/ZZTest-verification.pages"` (expand `~` yourself) | Succeeds; `documents_list` now shows that path. |
| Save again with no path | `save_document`, no `path` | Succeeds silently — saves in place, no confirm needed for a path already yours. |
| Save over a **different**, pre-existing file, no `confirm` | `save_document` with an existing unrelated file's path | Refused: "requires confirm=true". Nothing is overwritten — check the file is untouched. |
| Same, with `confirm: true` | — | **Do not actually run this against a file you care about.** Use a second disposable file instead, to prove the mechanism without real risk. |
| Close the still-unsaved second create from §3, `saving: true`, no path ever given | `close_document` with `saving: true` | Refused before any event is sent: message explains Pages would show its own save panel. |

## 5 — Exporting

| Step | Call | Expected |
|---|---|---|
| Export the ZZTest document to PDF, under Desktop | `export_document` with `to: "~/Desktop/ZZTest-verification.pdf"`, `format: "pdf"` | File appears; opens as a real PDF. |
| Export to a path outside Desktop/Documents/Downloads (e.g. `/tmp`) | same, different `to` | Pages' own sandbox refuses it; the failure is reported, not silently rerouted. |
| Export over the same PDF again, no `confirm` | same call | Refused: "requires confirm=true". |
| Try every format | `format`: each of `pdf`, `word`, `epub`, `rtf`, `plain_text`, `pages09` | Each produces a file of the right kind. |

## 6 — Password-protected documents

| Step | Call | Expected |
|---|---|---|
| Open (by hand, in Pages) a document you've set a password on, entering the password in Pages itself | — | — |
| List and get it through this server | `documents_list`, `document_get` | Listed with a 🔒 marker; `document_get` reports it is locked, no body text. |
| Try to update it | `update_document` | Refused: "password-protected document... refused", explains this server never accepts a password. |
| Try to export it | `export_document` | Same refusal. |

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
