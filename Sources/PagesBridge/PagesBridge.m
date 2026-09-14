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
    NSArray *matching = [application.documents
        filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"id == %@", identifier]];
    return matching.firstObject;
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

+ (nullable NSDictionary<NSString *, id> *)
    createDocumentWithTemplateName:(nullable NSString *)templateName
                    initialBodyText:(nullable NSString *)bodyText
                              error:(NSError **)error {
    SBApplication<PagesApplication> *application = [self applicationWithError:error];
    if (!application) return nil;

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

+ (BOOL)exportFormatCode:(NSString *)format into:(OSType *)outCode {
    if ([format isEqualToString:@"pdf"]) *outCode = PagesExportFormatPDF;
    else if ([format isEqualToString:@"word"]) *outCode = PagesExportFormatWord;
    else if ([format isEqualToString:@"epub"]) *outCode = PagesExportFormatEPUB;
    else if ([format isEqualToString:@"rtf"]) *outCode = PagesExportFormatRTF;
    else if ([format isEqualToString:@"plain_text"]) *outCode = PagesExportFormatPlainText;
    else if ([format isEqualToString:@"pages09"]) *outCode = PagesExportFormatPages09;
    else return NO;
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
    if (![self exportFormatCode:format into:&formatCode]) {
        if (error) {
            *error = [self errorWithCode:PagesBridgeErrorWriteRefused
                                 message:[NSString stringWithFormat:@"Unknown export format "
                                                                     "'%@'.",
                                                                    format]];
        }
        return nil;
    }

    // Pages' own sandbox decides which destinations are reachable — Desktop, Documents,
    // Downloads, or a folder the person separately granted — and refuses anything else
    // itself. That refusal is surfaced through `error` rather than routed around.
    [document exportTo:[NSURL fileURLWithPath:path] as:formatCode withProperties:nil];

    return @{@"path": path, @"format": format};
}

@end
