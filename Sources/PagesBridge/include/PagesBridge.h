#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const PagesBridgeErrorDomain;

/// Typed because Swift imports an `NSError **` method as `throws`, which would otherwise
/// flatten "that document is gone" — an ordinary outcome, since a document can be closed by
/// the owner between two calls — into the same channel as a real failure.
typedef NS_ERROR_ENUM(PagesBridgeErrorDomain, PagesBridgeError){
    PagesBridgeErrorPagesNotRunning = 1,
    PagesBridgeErrorNotReachable,
    PagesBridgeErrorDocumentNotFound,
    PagesBridgeErrorTemplateNotFound,
    PagesBridgeErrorCreateRefused,
    PagesBridgeErrorOpenRefused,
    PagesBridgeErrorWriteRefused,
    PagesBridgeErrorNeverSaved,
};

/// Everything this project sends to Pages, in Objective-C.
///
/// Objective-C rather than Swift, for the same reason as every sibling server: Apple
/// documents exactly one way to create a scriptable object — `classForScriptingClass:`,
/// `alloc`/`initWithProperties:`, then insert it in the container's element array — and
/// that pattern cannot be expressed from Swift. The class that comes back is an
/// `SBPseudoClass`, which does not inherit from `SBObject` and turns every class-level
/// message into an `__NSMessageBuilder`, so a Swift metatype cast against it aborts the
/// process. Underneath is a Swift limitation of long standing: the metadata symbols for
/// Scripting Bridge classes do not exist at link time because the classes are made at
/// runtime (swiftlang/swift#43407, open since 2016).
///
/// In Objective-C none of that arises. A cast to a protocol is a compile-time annotation,
/// the documented creation pattern compiles as written, and no `unsafeBitCast` is needed
/// anywhere. The alternative — driving Pages through `NSAppleScript` — is the one thing
/// Apple's own guide tells you not to do: "You should not use NSAppleScript to execute a
/// script merely to result in sending an Apple event."
///
/// One thing Pages needed that Notes did not: `body text` is declared in Pages' own
/// dictionary as a "rich text" object, not as plain text, so the property's Objective-C
/// type is an opaque `SBObject`, not `NSString`. Reading it as a string needs the same
/// coercion AppleScript's own `as text` performs — a `core`/`getd` Apple event carrying a
/// `keyAERequestedType` parameter of `typeUnicodeText` — sent explicitly via `SBObject`'s
/// public, documented `sendEvent:id:parameters:`. This was verified against the running
/// app before being written here: declaring the property as `NSString *` and just reading
/// it back does **not** coerce it — it returns the rich text object's `SBObject` wrapper.
///
/// Everything crosses back to Swift as Foundation types, so no Scripting Bridge object
/// ever escapes this file. Policy — which documents are in scope, how a template name
/// resolves, what counts as "would overwrite" — stays in Swift, where the tests can reach
/// it.
///
/// Caller strings are passed as typed parameters throughout. There is no script source to
/// splice them into, which is this project's injection guarantee.
@interface PagesBridge : NSObject

/// Whether Pages is running. This server never launches it.
@property (class, readonly) BOOL isPagesRunning;

/// Every currently open document, as `{id, name, path, pageCount, sectionCount,
/// tableCount, imageCount, chartCount, passwordProtected, hasBodyText, facingPages,
/// modified, templateName}`.
///
/// Pages has no library the way Notes has folders: it only knows about documents open in
/// the running app right now. `path` is omitted (not merely empty) for a document that has
/// never been saved.
+ (nullable NSArray<NSDictionary<NSString *, id> *> *)openDocumentsWithError:(NSError **)error;

/// One open document by its Pages-assigned identifier, with the same shape as one entry
/// above plus `bodyText` and, when `includePageTexts` is `YES`, `pageTexts` — one plain
/// text string per page, in document order.
+ (nullable NSDictionary<NSString *, id> *)
    documentWithIdentifier:(NSString *)identifier
           includePageTexts:(BOOL)includePageTexts
                       error:(NSError **)error;

/// Every installed template's display name, for resolving `templateName` below and for
/// naming what exists when a caller asks for one that doesn't.
+ (nullable NSArray<NSString *> *)installedTemplateNamesWithError:(NSError **)error;

/// Creates a new, unsaved document — optionally from a named template, optionally with an
/// initial plain-text body — and returns it in the same shape as `documentWithIdentifier:`.
///
/// Pages autosaves a new document into iCloud Drive within seconds of creation, on its own
/// schedule, whether or not this server ever calls `saveDocument`. A document made only to
/// be discarded is not necessarily discarded by closing it without saving — see the
/// server's `CLAUDE.md` and `README.md` for what that means for cleanup.
+ (nullable NSDictionary<NSString *, id> *)
    createDocumentWithTemplateName:(nullable NSString *)templateName
                    initialBodyText:(nullable NSString *)bodyText
                              error:(NSError **)error;

/// Opens the file at `path` and returns it in the same shape as `documentWithIdentifier:`.
///
/// If the file is password-protected, Pages shows its own password prompt and this call
/// blocks until a person at the keyboard answers it or cancels — there is no way to detect
/// that in advance from the scripting dictionary, and no way to supply a password through
/// this server (see the product's password policy in `README.md`).
+ (nullable NSDictionary<NSString *, id> *)openDocumentAtPath:(NSString *)path
                                                          error:(NSError **)error;

/// Replaces the whole body text of the open document identified by `identifier`.
/// Appending is composed by the caller, one seam above this file, where it can be tested.
+ (nullable NSDictionary<NSString *, id> *)
    setBodyText:(NSString *)text
    ofDocumentWithIdentifier:(NSString *)identifier
                        error:(NSError **)error;

/// Saves the open document to `path` (the Pages native format). When `path` is nil the
/// document is saved to whatever path it already has; a document that has never been
/// saved and is given no path fails with `PagesBridgeErrorNeverSaved`.
+ (nullable NSDictionary<NSString *, id> *)
    saveDocumentWithIdentifier:(NSString *)identifier
                            toPath:(nullable NSString *)path
                             error:(NSError **)error;

/// Closes the open document, discarding unsaved changes when `saving` is `NO`. Returns the
/// document's own record as it was immediately before closing, so the caller can describe
/// what disappeared. Closing `saving:YES` on a document with no path is refused before any
/// event is sent — Pages would otherwise show its own save panel and block, exactly like
/// the password prompt above.
+ (nullable NSDictionary<NSString *, id> *)
    closeDocumentWithIdentifier:(NSString *)identifier
                          saving:(BOOL)saving
                           error:(NSError **)error;

/// Exports the open document to `path` in `format`, one of "pdf", "word", "epub", "rtf",
/// "plain_text" or "pages09". Pages' own sandbox only accepts destinations under Desktop,
/// Documents or Downloads (or another folder the person has separately granted); a path
/// outside that is refused by Pages itself, and the failure is surfaced rather than
/// papered over.
+ (nullable NSDictionary<NSString *, id> *)
    exportDocumentWithIdentifier:(NSString *)identifier
                            toPath:(NSString *)path
                            format:(NSString *)format
                             error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
