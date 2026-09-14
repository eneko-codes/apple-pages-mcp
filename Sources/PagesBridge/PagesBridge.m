#import "PagesBridge.h"

#import <AppKit/AppKit.h>
#import <ScriptingBridge/ScriptingBridge.h>

// Hand-declared bindings for Pages, covering only the members this server sends.
//
// `sdef "/Applications/Pages Creator Studio.app" | sdp -fh` generates the real header;
// declaring the handful of members actually used is smaller and auditable. Every selector
// here was checked against that generated header and against the running app — confirm
// before adding one:
//
//     sdef "/Applications/Pages Creator Studio.app" | sdp -fh --basename Check
//     grep 'bodyText\|passwordProtected' Check.h
//
// Scripting Bridge camel-cases dictionary names: `password protected` becomes
// `passwordProtected`, `document body` becomes `documentBody`. `id` stays `id` and is
// generated as a method rather than a property, because it collides with the Objective-C
// type name.
//
// `bodyText`, and its equivalents on `page` and `section`, are declared `id` rather than
// `NSString *`. Pages' own dictionary types `body text` as a "rich text" object, and the
// generated header agrees — `sdp` emits `RichText *`, not `NSString *`. Declaring the
// property as `NSString *` here does not change that: it still comes back as an opaque
// `SBObject` wrapping the rich text, verified against the running app. Getting the text
// out needs the same coercion AppleScript's own `as text` performs, sent explicitly with
// `sendEvent:id:parameters:` — see `plainText:` below. Setting has no such trouble: `set
// bodyText = someNSString` is accepted directly, because AppleScript's `set` coerces a
// plain string into rich text on the way in.
//
// The window's `selection` and the document's own `selection` are deliberately absent:
// reading whatever the owner has selected on screen is not this server's business.

@protocol PagesTemplate <NSObject>
- (NSString *)id;
@property (copy, readonly) NSString *name;
@end

@protocol PagesPage <NSObject>
@property (copy, readonly) id bodyText;
@end

/// One paragraph of rich text. Font, size and color are the entire scriptable surface —
/// verified against the running app, including the surprising part: setting them works
/// directly on the indexed specifier `richText.paragraphs[i]` with no `.get` resolution
/// first. That is the opposite of `documentWithIdentifier:ofApplication:`'s lesson, not a
/// contradiction of it — `.get` on a paragraph eagerly coerces to its own plain-text
/// `NSString` (also verified live), so calling it here would hand back a string with no
/// `font`/`size`/`color` properties at all, and setting one would crash the same way the
/// unresolved document specifier did before that fix, just further down the stack.
@protocol PagesRichTextParagraph <NSObject>
@property (copy) NSString *font;
@property double size;
@property (copy) NSColor *color;
@end

/// `document.bodyText`'s type once you need to reach into it — declared separately from
/// the `id` used elsewhere for `bodyText` because Swift-side coercion (`plainText:`) and
/// paragraph access are different operations needing different static types on the same
/// underlying Apple-event value.
@protocol PagesRichText <NSObject>
@property (readonly) SBElementArray<id<PagesRichTextParagraph>> *paragraphs;
@end

@protocol PagesSection <NSObject>
@property (copy, readonly) id bodyText;
@end

@protocol PagesDocument <NSObject>
- (NSString *)id;
@property (copy, readonly) NSString *name;
@property (copy, readonly) NSURL *file;
@property (readonly) BOOL modified;
@property (readonly) BOOL passwordProtected;
@property (readonly) BOOL documentBody;
@property (readonly) BOOL facingPages;
@property (copy, readonly) id<PagesTemplate> documentTemplate;
@property (copy) id bodyText;
@property (readonly) SBElementArray<id<PagesPage>> *pages;
@property (readonly) SBElementArray<id<PagesSection>> *sections;
@property (readonly) SBElementArray *tables;
@property (readonly) SBElementArray *images;
@property (readonly) SBElementArray *charts;
- (void)closeSaving:(OSType)saving savingIn:(nullable NSURL *)savingIn;
- (void)saveIn:(nullable NSURL *)path as:(OSType)format;
- (void)exportTo:(NSURL *)path as:(OSType)format withProperties:(nullable NSDictionary *)properties;
@end

@protocol PagesApplication <NSObject>
@property (readonly) SBElementArray<id<PagesDocument>> *documents;
@property (readonly) SBElementArray<id<PagesTemplate>> *templates;
- (id)open:(id)x;
@end

NSString *const PagesBridgeErrorDomain = @"codes.eneko.apple-pages-mcp";
static NSString *const PagesBundleIdentifier = @"com.apple.Pages";

// Four-character codes from Pages' own scripting dictionary. Declared here rather than
// imported from a generated header, matching every other enum this project hand-declares —
// see the file comment above for how to re-verify one.
static const OSType PagesSaveOptionsNo = 'no  ';
static const OSType PagesSaveableFormatPages = 'Pgff';
static const OSType PagesExportFormatEPUB = 'Pepu';
static const OSType PagesExportFormatPlainText = 'Ptxf';
static const OSType PagesExportFormatPDF = 'Ppdf';
static const OSType PagesExportFormatWord = 'Pwrd';
static const OSType PagesExportFormatPages09 = 'PPag';
static const OSType PagesExportFormatRTF = 'Prtf';

@implementation PagesBridge

#pragma mark - Plumbing

+ (BOOL)isPagesRunning {
    return [NSRunningApplication
               runningApplicationsWithBundleIdentifier:PagesBundleIdentifier].count > 0;
}

+ (NSError *)errorWithCode:(PagesBridgeError)code message:(NSString *)message {
    return [NSError errorWithDomain:PagesBridgeErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

/// The application object, or nil with `error` set. Casting to the protocol is a
/// compile-time annotation in Objective-C: no runtime check, no metadata symbol, and so
/// none of the trouble the same line causes in Swift.
+ (nullable SBApplication<PagesApplication> *)applicationWithError:(NSError **)error {
    if (!self.isPagesRunning) {
        if (error) {
            *error = [self errorWithCode:PagesBridgeErrorPagesNotRunning
                                 message:@"Pages is not running."];
        }
        return nil;
    }
    SBApplication *application =
        [SBApplication applicationWithBundleIdentifier:PagesBundleIdentifier];
    if (!application) {
        if (error) {
            *error = [self errorWithCode:PagesBridgeErrorNotReachable
                                 message:@"Pages could not be reached."];
        }
        return nil;
    }
    // No launch flag is set to keep Pages from starting, because none exists: the guard is
    // the isPagesRunning check above. Launching an app on the owner's behalf is a side
    // effect they did not ask for.

    // `timeout` is in ticks (1/60 second), inherited from the classic Apple Event Manager.
    // The default is `kAEDefaultTimeout`, documented as "about a minute" but measured here
    // at ~120s: a document's first save to a path it has never had — the never-saved,
    // saving:true case `close_document` already refuses for exactly this reason — can hang
    // the whole way to that timeout waiting on a dialog nothing here can answer. 30 seconds
    // is long enough for a real export or save and short enough that a stuck call fails
    // with a clear error instead of blocking a tool call for two minutes.
    application.timeout = 30 * 60;
    return (SBApplication<PagesApplication> *)application;
}

/// The coercion AppleScript's `as text` performs, sent explicitly. See the file comment
/// for why `bodyText` cannot simply be declared `NSString *` instead.
+ (NSString *)plainText:(id)richTextObject {
    if (!richTextObject || ![richTextObject respondsToSelector:@selector(sendEvent:id:parameters:)]) {
        return @"";
    }
    id coerced = [richTextObject sendEvent:kAECoreSuite
                                          id:kAEGetData
                                  parameters:keyAERequestedType, @(typeUnicodeText), 0];
    return [coerced isKindOfClass:[NSString class]] ? coerced : @"";
}

#pragma mark - Reads

+ (nullable id<PagesDocument>)documentWithIdentifier:(NSString *)identifier
                                        ofApplication:(SBApplication<PagesApplication> *)application {
    NSArray<id<PagesDocument>> *matching = [application.documents
        filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"id == %@", identifier]];
    SBObject<PagesDocument> *match = (SBObject<PagesDocument> *)matching.firstObject;
    if (!match) return nil;
    // `filteredArrayUsingPredicate:` returns a lazy "whose" specifier — its own
    // description prints `whose 'cmpd'{...}`, not a resolved element reference. Reading
    // *any* property directly off that, starting with `-id`, crashed inside `objc_retain`
    // with `EXC_BAD_ACCESS` — reproduced with a standalone, single-threaded repro with no
    // Swift and no concurrency involved, so it is a Scripting Bridge behaviour, not a
    // threading bug. `SBObject.get` — "forces the current object reference... to be
    // evaluated" — resolves it to a concrete element first, after which every property
    // access here is reliable.
    return (id<PagesDocument>)[match get];
}

+ (NSError *)documentNotFoundError {
    return [self errorWithCode:PagesBridgeErrorDocumentNotFound
                       message:@"No open document in Pages has that identifier any more."];
}

/// One document as a dictionary, without its body text — used for the open-documents list,
/// where fetching every body would be one extra Apple event per document for something the
/// caller almost never wants at that scale.
+ (NSDictionary<NSString *, id> *)summaryOfDocument:(id<PagesDocument>)document {
    NSURL *file = document.file;
    id<PagesTemplate> template = document.documentTemplate;
    NSMutableDictionary<NSString *, id> *summary = [@{
        @"id": [document id] ?: @"",
        @"name": document.name ?: @"",
        @"pageCount": @(document.pages.count),
        @"sectionCount": @(document.sections.count),
        @"tableCount": @(document.tables.count),
        @"imageCount": @(document.images.count),
        @"chartCount": @(document.charts.count),
        @"passwordProtected": @(document.passwordProtected),
        @"hasBodyText": @(document.documentBody),
        @"facingPages": @(document.facingPages),
        @"modified": @(document.modified),
    } mutableCopy];
    if (file) summary[@"path"] = file.path ?: @"";
    if (template) summary[@"templateName"] = template.name ?: @"";
    return summary;
}

+ (nullable NSArray<NSDictionary<NSString *, id> *> *)openDocumentsWithError:(NSError **)error {
    SBApplication<PagesApplication> *application = [self applicationWithError:error];
    if (!application) return nil;

    NSMutableArray<NSDictionary<NSString *, id> *> *results = [NSMutableArray array];
    for (id<PagesDocument> document in application.documents) {
        [results addObject:[self summaryOfDocument:document]];
    }
    return results;
}

+ (nullable NSDictionary<NSString *, id> *)
    documentWithIdentifier:(NSString *)identifier
           includePageTexts:(BOOL)includePageTexts
                       error:(NSError **)error {
    SBApplication<PagesApplication> *application = [self applicationWithError:error];
    if (!application) return nil;

    id<PagesDocument> document = [self documentWithIdentifier:identifier ofApplication:application];
    if (!document) {
        if (error) *error = [self documentNotFoundError];
        return nil;
    }

    NSMutableDictionary<NSString *, id> *detail = [[self summaryOfDocument:document] mutableCopy];
    detail[@"bodyText"] = [self plainText:document.bodyText];
    if (includePageTexts) {
        NSMutableArray<NSString *> *pageTexts = [NSMutableArray array];
        for (id<PagesPage> page in document.pages) {
            [pageTexts addObject:[self plainText:page.bodyText]];
        }
        detail[@"pageTexts"] = pageTexts;
    }
    return detail;
}

+ (nullable NSArray<NSString *> *)installedTemplateNamesWithError:(NSError **)error {
    SBApplication<PagesApplication> *application = [self applicationWithError:error];
    if (!application) return nil;

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (id<PagesTemplate> template in application.templates) {
        NSString *name = template.name;
        if (name.length > 0) [names addObject:name];
    }
    return names;
}

#pragma mark - Writes

/// The half of document creation shared by the plain-body and styled-paragraph forms:
/// resolve the template if one was named, ask for the document class, create it, and
/// insert it into `application.documents`. Returns the still-untitled document with an
/// empty body; the caller sets `bodyText` afterwards, once, in whichever shape it needs.
+ (nullable id<PagesDocument>)insertedDocumentWithTemplateName:(nullable NSString *)templateName
                                             ofApplication:(SBApplication<PagesApplication> *)application
                                                     error:(NSError **)error {
    NSDictionary *properties = @{};
    if (templateName.length > 0) {
        id<PagesTemplate> match;
        for (id<PagesTemplate> candidate in application.templates) {
            if ([candidate.name caseInsensitiveCompare:templateName] == NSOrderedSame) {
                match = candidate;
                break;
            }
        }
        if (!match) {
            if (error) {
                *error = [self errorWithCode:PagesBridgeErrorTemplateNotFound
                                     message:[NSString stringWithFormat:@"No template '%@'.",
                                                                        templateName]];
            }
            return nil;
        }
        properties = @{@"documentTemplate": match};
    }

    Class documentClass = [application classForScriptingClass:@"document"];
    if (!documentClass) {
        if (error) {
            *error = [self errorWithCode:PagesBridgeErrorCreateRefused
                                 message:@"Pages did not offer its document class."];
        }
        return nil;
    }

    // Properties are a dictionary of typed values, never text spliced into a script.
    id<PagesDocument> document = [[documentClass alloc] initWithProperties:properties];
    if (!document) {
        if (error) {
            *error = [self errorWithCode:PagesBridgeErrorCreateRefused
                                 message:@"Pages would not create the document."];
        }
        return nil;
    }

    // Insert before touching anything else. Scripting Bridge: an object "is not viable in
    // the application until it has been added to its container. Consequently, you cannot
    // set or access its properties until it's been added."
    [application.documents addObject:document];
    return document;
}

/// Splits `text` on `\n` into Pages paragraphs and applies `font`/`size` and, when all
/// three color keys are present, `color` to each, by index — the entire scriptable
/// surface of a rich-text paragraph, confirmed against the running app. `paragraphs`
/// carries one dictionary per paragraph, in order: `{"text", "font", "size", "colorRed",
/// "colorGreen", "colorBlue"}` (the color keys are all-or-nothing per paragraph — absent
/// means leave Pages' own default color alone). The count of paragraphs actually present
/// afterward is trusted over `paragraphs.count`: a caller whose own text contains an
/// embedded `\n` would otherwise walk off the end of what Pages actually made.
+ (void)applyStyledParagraphs:(NSArray<NSDictionary<NSString *, id> *> *)paragraphs
                    toDocument:(id<PagesDocument>)document {
    NSMutableArray<NSString *> *texts = [NSMutableArray arrayWithCapacity:paragraphs.count];
    for (NSDictionary<NSString *, id> *spec in paragraphs) {
        [texts addObject:spec[@"text"] ?: @""];
    }
    document.bodyText = [texts componentsJoinedByString:@"\n"];

    id<PagesRichText> richText = (id<PagesRichText>)document.bodyText;
    SBElementArray<id<PagesRichTextParagraph>> *richParagraphs = richText.paragraphs;
    NSUInteger count = MIN(paragraphs.count, richParagraphs.count);
    for (NSUInteger i = 0; i < count; i++) {
        NSDictionary<NSString *, id> *spec = paragraphs[i];
        // Never resolved with `.get` — see the note on `PagesRichTextParagraph` above.
        id<PagesRichTextParagraph> paragraph = [richParagraphs objectAtIndex:i];
        NSString *font = spec[@"font"];
        NSNumber *size = spec[@"size"];
        if (font.length > 0) paragraph.font = font;
        if (size) paragraph.size = size.doubleValue;
        NSNumber *red = spec[@"colorRed"], *green = spec[@"colorGreen"], *blue = spec[@"colorBlue"];
        if (red && green && blue) {
            paragraph.color = [NSColor colorWithCalibratedRed:red.doubleValue
                                                          green:green.doubleValue
                                                           blue:blue.doubleValue
                                                          alpha:1.0];
        }
    }
}

+ (nullable NSDictionary<NSString *, id> *)
    createDocumentWithTemplateName:(nullable NSString *)templateName
                    initialBodyText:(nullable NSString *)bodyText
                              error:(NSError **)error {
    SBApplication<PagesApplication> *application = [self applicationWithError:error];
    if (!application) return nil;

    id<PagesDocument> document = [self insertedDocumentWithTemplateName:templateName
                                                      ofApplication:application
                                                              error:error];
    if (!document) return nil;

    if (bodyText.length > 0) {
        document.bodyText = bodyText;
    }

    NSString *identifier = [document id];
    if (identifier.length == 0) {
        if (error) {
            *error = [self errorWithCode:PagesBridgeErrorCreateRefused
                                 message:@"Pages created the document but did not return an "
                                          "identifier for it. Check documents_list before "
                                          "trying again, so a second copy is not made."];
        }
        return nil;
    }

    NSMutableDictionary<NSString *, id> *detail = [[self summaryOfDocument:document] mutableCopy];
    detail[@"bodyText"] = bodyText ?: @"";
    return detail;
}

+ (nullable NSDictionary<NSString *, id> *)
    createDocumentWithTemplateName:(nullable NSString *)templateName
                   styledParagraphs:(NSArray<NSDictionary<NSString *, id> *> *)paragraphs
                              error:(NSError **)error {
    SBApplication<PagesApplication> *application = [self applicationWithError:error];
    if (!application) return nil;

    id<PagesDocument> document = [self insertedDocumentWithTemplateName:templateName
                                                      ofApplication:application
                                                              error:error];
    if (!document) return nil;

    NSString *identifier = [document id];
    if (identifier.length == 0) {
        if (error) {
            *error = [self errorWithCode:PagesBridgeErrorCreateRefused
                                 message:@"Pages created the document but did not return an "
                                          "identifier for it. Check documents_list before "
                                          "trying again, so a second copy is not made."];
        }
        return nil;
    }

    [self applyStyledParagraphs:paragraphs toDocument:document];

    NSMutableDictionary<NSString *, id> *detail = [[self summaryOfDocument:document] mutableCopy];
    detail[@"bodyText"] = [self plainText:document.bodyText];
    return detail;
}

+ (nullable NSDictionary<NSString *, id> *)openDocumentAtPath:(NSString *)path
                                                          error:(NSError **)error {
    SBApplication<PagesApplication> *application = [self applicationWithError:error];
    if (!application) return nil;

    NSURL *url = [NSURL fileURLWithPath:path];
    // Pages shows its own password prompt here, blocking, when the file is protected —
    // there is no way to see that coming from the dictionary, and no parameter on `open`
    // to supply a password even if there were. Documented in the header; not worked around
    // here.
    id<PagesDocument> opened = (id<PagesDocument>)[application open:url];
    if (!opened) {
        if (error) {
            *error = [self errorWithCode:PagesBridgeErrorOpenRefused
                                 message:[NSString stringWithFormat:
                                                       @"Pages did not open '%@'. Check the "
                                                        "path exists and is a Pages document.",
                                                       path]];
        }
        return nil;
    }

    id<PagesDocument> document = [self documentWithIdentifier:[opened id] ?: @""
                                                  ofApplication:application];
    if (!document) document = opened;

    NSMutableDictionary<NSString *, id> *detail = [[self summaryOfDocument:document] mutableCopy];
    detail[@"bodyText"] = [self plainText:document.bodyText];
    return detail;
}

+ (nullable NSDictionary<NSString *, id> *)
    setBodyText:(NSString *)text
    ofDocumentWithIdentifier:(NSString *)identifier
                        error:(NSError **)error {
    SBApplication<PagesApplication> *application = [self applicationWithError:error];
    if (!application) return nil;

    id<PagesDocument> document = [self documentWithIdentifier:identifier ofApplication:application];
    if (!document) {
        if (error) *error = [self documentNotFoundError];
        return nil;
    }
    document.bodyText = text;

    NSMutableDictionary<NSString *, id> *detail = [[self summaryOfDocument:document] mutableCopy];
    detail[@"bodyText"] = [self plainText:document.bodyText];
    return detail;
}

+ (nullable NSDictionary<NSString *, id> *)
    setStyledParagraphs:(NSArray<NSDictionary<NSString *, id> *> *)paragraphs
    ofDocumentWithIdentifier:(NSString *)identifier
                        error:(NSError **)error {
    SBApplication<PagesApplication> *application = [self applicationWithError:error];
    if (!application) return nil;

    id<PagesDocument> document = [self documentWithIdentifier:identifier ofApplication:application];
    if (!document) {
        if (error) *error = [self documentNotFoundError];
        return nil;
    }

    [self applyStyledParagraphs:paragraphs toDocument:document];

    NSMutableDictionary<NSString *, id> *detail = [[self summaryOfDocument:document] mutableCopy];
    detail[@"bodyText"] = [self plainText:document.bodyText];
    return detail;
}

+ (nullable NSDictionary<NSString *, id> *)
    saveDocumentWithIdentifier:(NSString *)identifier
                            toPath:(nullable NSString *)path
                             error:(NSError **)error {
    SBApplication<PagesApplication> *application = [self applicationWithError:error];
    if (!application) return nil;

    id<PagesDocument> document = [self documentWithIdentifier:identifier ofApplication:application];
    if (!document) {
        if (error) *error = [self documentNotFoundError];
        return nil;
    }

    NSURL *destination = path.length > 0 ? [NSURL fileURLWithPath:path] : document.file;
    if (!destination) {
        if (error) {
            *error = [self errorWithCode:PagesBridgeErrorNeverSaved
                                 message:@"This document has never been saved and no path "
                                          "was given, so there is nowhere to save it to."];
        }
        return nil;
    }
    [document saveIn:destination as:PagesSaveableFormatPages];

    // `saveIn:as:` does not reliably report its own failure. Verified directly against
    // the running app, twice, before writing this check: redirecting an already-saved
    // document to a new path returned with no exception and no `lastError` while leaving
    // the file untouched and `document.file` unchanged — a silent no-op masquerading as
    // success. A destination that still does not exist on disk after the call is treated
    // as a failure explicitly, rather than trusting the command's own silence.
    if (destination.isFileURL && ![[NSFileManager defaultManager]
                                       fileExistsAtPath:destination.path]) {
        if (error) {
            *error = [self errorWithCode:PagesBridgeErrorWriteRefused
                                 message:[NSString stringWithFormat:
                                                       @"Pages reported no error, but no file "
                                                        "exists at '%@' afterwards. Pages' "
                                                        "own \"save\" command is not reliable "
                                                        "for redirecting an already-saved "
                                                        "document to a new location — export_"
                                                        "document is the verified route to "
                                                        "get this document's content onto "
                                                        "disk at a chosen path.",
                                                       destination.path]];
        }
        return nil;
    }

    NSMutableDictionary<NSString *, id> *detail = [[self summaryOfDocument:document] mutableCopy];
    detail[@"bodyText"] = [self plainText:document.bodyText];
    return detail;
}

+ (nullable NSDictionary<NSString *, id> *)
    closeDocumentWithIdentifier:(NSString *)identifier
                          saving:(BOOL)saving
                           error:(NSError **)error {
    SBApplication<PagesApplication> *application = [self applicationWithError:error];
    if (!application) return nil;

    id<PagesDocument> document = [self documentWithIdentifier:identifier ofApplication:application];
    if (!document) {
        if (error) *error = [self documentNotFoundError];
        return nil;
    }

    if (saving && !document.file) {
        if (error) {
            *error = [self errorWithCode:PagesBridgeErrorNeverSaved
                                 message:@"This document has never been saved. Closing with "
                                          "saving:true would make Pages show its own save "
                                          "panel and block waiting for it. Call "
                                          "save_document with a path first, then close."];
        }
        return nil;
    }

    // Read the record before it disappears: once the document is closed there is nothing
    // left to describe, and the receipt for something that cannot be undone from here is
    // the only record the caller gets.
    NSMutableDictionary<NSString *, id> *record = [[self summaryOfDocument:document] mutableCopy];
    record[@"bodyText"] = [self plainText:document.bodyText];

    [document closeSaving:(saving ? 'yes ' : PagesSaveOptionsNo) savingIn:nil];
    return record;
}

/// The file extension Pages itself expects for each export format, taken from the
/// dictionary's own documentation for the `export` command. `exportTo:as:` does not
/// validate this — see the caller for why that matters.
+ (BOOL)exportFormatCode:(NSString *)format
                     into:(OSType *)outCode
                extension:(NSString *_Nonnull *_Nonnull)outExtension {
    if ([format isEqualToString:@"pdf"]) {
        *outCode = PagesExportFormatPDF;
        *outExtension = @"pdf";
    } else if ([format isEqualToString:@"word"]) {
        *outCode = PagesExportFormatWord;
        *outExtension = @"docx";
    } else if ([format isEqualToString:@"epub"]) {
        *outCode = PagesExportFormatEPUB;
        *outExtension = @"epub";
    } else if ([format isEqualToString:@"rtf"]) {
        *outCode = PagesExportFormatRTF;
        *outExtension = @"rtf";
    } else if ([format isEqualToString:@"plain_text"]) {
        *outCode = PagesExportFormatPlainText;
        *outExtension = @"txt";
    } else if ([format isEqualToString:@"pages09"]) {
        *outCode = PagesExportFormatPages09;
        *outExtension = @"pages";
    } else {
        return NO;
    }
    return YES;
}

+ (nullable NSDictionary<NSString *, id> *)
    exportDocumentWithIdentifier:(NSString *)identifier
                            toPath:(NSString *)path
                            format:(NSString *)format
                             error:(NSError **)error {
    SBApplication<PagesApplication> *application = [self applicationWithError:error];
    if (!application) return nil;

    id<PagesDocument> document = [self documentWithIdentifier:identifier ofApplication:application];
    if (!document) {
        if (error) *error = [self documentNotFoundError];
        return nil;
    }

    OSType formatCode;
    NSString *expectedExtension;
    if (![self exportFormatCode:format into:&formatCode extension:&expectedExtension]) {
        if (error) {
            *error = [self errorWithCode:PagesBridgeErrorWriteRefused
                                 message:[NSString stringWithFormat:@"Unknown export format "
                                                                     "'%@'.",
                                                                    format]];
        }
        return nil;
    }

    // Verified directly against the running app: `exportTo:as:` silently no-ops — no
    // exception, no `lastError`, no file — when the destination's extension does not
    // match the format (asked for "word" with a ".word" path; the real export needs
    // ".docx"). Refusing before sending the event, rather than discovering it from a
    // missing file afterwards, gives a caller something actionable.
    if (![path.pathExtension.lowercaseString isEqualToString:expectedExtension]) {
        if (error) {
            *error = [self errorWithCode:PagesBridgeErrorWriteRefused
                                 message:[NSString stringWithFormat:
                                                       @"'%@' export needs a '.%@' "
                                                        "destination, not '%@'. Pages "
                                                        "reports no error for a mismatched "
                                                        "extension — it just writes nothing.",
                                                       format, expectedExtension, path]];
        }
        return nil;
    }

    // Verified live to reach ordinary locations well beyond Desktop/Documents/Downloads
    // — a plain /tmp path and a brand-new folder under the home directory both worked.
    // Whatever narrower boundary Pages' own sandbox does draw, a refusal is surfaced
    // through `error` rather than routed around.
    [document exportTo:[NSURL fileURLWithPath:path] as:formatCode withProperties:nil];

    // Belt and suspenders: the extension check above is the known cause, but
    // `exportTo:as:` has already shown once that it can report success with nothing on
    // disk, so the result is verified rather than assumed for any other reason it might
    // do that again.
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        if (error) {
            *error = [self errorWithCode:PagesBridgeErrorWriteRefused
                                 message:[NSString stringWithFormat:
                                                       @"Pages reported no error, but no "
                                                        "file exists at '%@' afterwards.",
                                                       path]];
        }
        return nil;
    }

    return @{@"path": path, @"format": format};
}

@end
