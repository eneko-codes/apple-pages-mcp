import Foundation

/// The catalogue is the authorisation surface: a tool that is not listed here cannot be
/// called, and the name it is listed under is the label on the permission switch in
/// Claude Desktop. Reads carry no verb prefix; writes always start with a verb, so the
/// destructive ones are visible at a glance in the switch list.
public enum ToolCatalog {

    /// Names are constants rather than being read back off a `Tool`, so that the dispatch
    /// and the tests name a tool without building its schema.
    public static let statusName = "pages_status"
    public static let documentsListName = "documents_list"
    public static let getName = "document_get"
    public static let createName = "create_document"
    public static let openName = "open_document"
    public static let updateName = "update_document"
    public static let saveName = "save_document"
    public static let closeName = "close_document"
    public static let exportName = "export_document"

    /// The verbs a write tool may begin with.
    static let writeVerbs = ["create_", "open_", "update_", "save_", "close_", "export_"]

    // Sizes. The schemas, the descriptions and the server instructions quote these by
    // interpolation, so a bound the model reads is always the one the code enforces.

    public static let offsetRange = 0...10_000_000

    /// A page of open documents. A row is a name, three short facts and an id, about 100
    /// characters, so the maximum fits `ToolStandard.longestResult` even when every name is
    /// as long as a file name may be, and the default is well inside
    /// `ToolStandard.usualPage`. `BoundsTests` renders both to hold them to that.
    public static let documentLimitRange = 1...100
    public static let defaultDocumentLimit = 25

    /// The window on a document's text. The maximum is half the longest result, so a
    /// window of ordinary text leaves room for what Pages reports about the document;
    /// `ToolStandard.fitting` shrinks one whose characters take more UTF-16 units than that.
    public static let maxCharactersRange = 1...(ToolStandard.longestResult / 2)
    public static let defaultMaxCharacters = ToolStandard.usualPage

    /// Pages are numbered from one. The last one is the document's own page count, which
    /// only the document can say, so the code moves a page number into 1 to that count.
    public static let firstPageNumber = 1

    public static func all() -> [Tool] {
        [status, documentsList, get, create, open, update, save, close, export]
    }

    // MARK: Schema helpers

    private static func object(properties: [String: Value], required: [String] = []) -> Value {
        var schema: [String: Value] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        schema["additionalProperties"] = .bool(false)
        return .object(schema)
    }

    /// `type` is always a single string, never `["string", "null"]`. Claude Desktop's
    /// schema sanitiser drops a property outright when its `type` is a union and hands
    /// the model a bare `{}` in its place; a test walks the whole catalogue to keep it
    /// out.
    private static func string(_ description: String) -> Value {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func boolean(_ description: String, default def: Bool) -> Value {
        .object([
            "type": .string("boolean"), "description": .string(description),
            "default": .bool(def),
        ])
    }

    private static func integer(_ description: String, range: ClosedRange<Int>, default def: Int)
        -> Value
    {
        .object([
            "type": .string("integer"), "description": .string(description),
            "minimum": .int(range.lowerBound), "maximum": .int(range.upperBound),
            "default": .int(def),
        ])
    }

    /// A page number. It states no maximum and no default: the last page is the document's
    /// own count, and leaving both page arguments out means the body, not page one.
    private static func pageNumber(_ description: String) -> Value {
        .object([
            "type": .string("integer"), "description": .string(description),
            "minimum": .int(firstPageNumber),
        ])
    }

    private static let idHelp = "Identifier returned by documents_list or by whichever tool opened it."

    private static let bodyHelp = """
        The document's whole body, as plain text, with no per-paragraph styling. Pass \
        'paragraphs' instead for headings, quotes or other styled paragraphs. Exactly one \
        of 'body' or 'paragraphs' — never both.
        """

    /// One entry per Pages paragraph. Unlike `bodyHelp`'s plain string, this is where
    /// styling actually lives — font, size and color per paragraph, the whole scriptable
    /// surface Pages' own dictionary exposes for rich text, confirmed against the running
    /// app. `quote` is Pages' closest approximation to a block quote (italic, grey); Pages
    /// has no indent or rule to draw a real one with.
    private static let paragraphsHelp = """
        An alternative to 'body': one entry per paragraph, each with its own style. \
        Exactly one of 'body' or 'paragraphs' — never both. A paragraph's 'text' may not \
        contain a newline — split multi-line content into separate entries instead, one \
        per Pages paragraph.

        Styles are fixed presets built from font, size and color — the only three \
        properties Pages' scripting dictionary exposes on a paragraph. They are NOT the \
        named paragraph styles Pages' own Format sidebar offers (Title, Heading, Body, \
        with a dropdown and a "*" for local overrides) — confirmed live that no such \
        thing is scriptable at all: neither a "style" property, a "paragraph style" \
        property, nor any other name tried actually selects one. What this produces \
        looks like a heading but IS NOT ONE to Pages itself: it will not appear in a \
        Table of Contents (built from named heading styles) and will not change if the \
        document's theme changes, exactly as if you had selected text and bumped its \
        font size by hand rather than picked "Heading" from the sidebar.
          title      28pt bold
          heading1   22pt bold
          heading2   17pt bold
          heading3   14pt bold
          quote      12pt italic, grey — an approximation; Pages has no real block quote
          body       12pt regular (default if 'style' is omitted)
        """

    private static func paragraphsSchema(_ description: String) -> Value {
        .object([
            "type": .string("array"),
            "description": .string(description),
            "items": .object([
                "type": .string("object"),
                "properties": .object([
                    "text": string("This paragraph's text. No newlines."),
                    "style": .object([
                        "type": .string("string"),
                        "enum": .array(ParagraphStyle.allCases.map { .string($0.rawValue) }),
                        "description": .string("Defaults to \"body\" if omitted."),
                    ]),
                ]),
                "required": .array([.string("text")]),
                "additionalProperties": .bool(false),
            ]),
        ])
    }

    private static let confirmHelp = "Must be true. Without it the call is refused."

    // MARK: Reads

    static let status = Tool(
        name: statusName,
        title: "Pages availability and settings",
        description: """
            Reports whether Pages is running, whether this server may automate it, and \
            the sizes in force: the window document_get reads, the page documents_list \
            returns, the longest result and the deadline of a call. Touches no document.

            Use it when another Pages tool fails, or when setting the server up.
            """,
        inputSchema: object(properties: [:]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let documentsList = Tool(
        name: documentsListName,
        title: "List open documents",
        description: """
            Lists the documents open in Pages, \(defaultDocumentLimit) to a page in name \
            order, each with its page count, whether it was never saved or has unsaved \
            changes, and the id the other tools take. When more are open than the page \
            holds, the first lines of the result say how many there are and the offset of \
            the next page: pass limit (up to \(documentLimitRange.upperBound)) and offset.

            Pages has no library the way Notes has folders: this is the whole of what \
            can be asked about without opening something first. A file that is not \
            open yet does not appear here — call open_document for that.
            """,
        inputSchema: object(properties: [
            "limit": integer(
                "Maximum number of documents in one page.", range: documentLimitRange,
                default: defaultDocumentLimit),
            "offset": integer(
                """
                Number of documents to skip. A result that does not hold every document \
                says, in its first lines, the offset to pass for the next page.
                """, range: offsetRange, default: 0),
        ]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let get = Tool(
        name: getName,
        title: "Read one open document",
        description: """
            Returns one open document: its path, its page, section, table, image and chart \
            counts, and the first \(defaultMaxCharacters) characters of its body as plain \
            text. When the body is longer, the first lines of the result say how long it \
            is and the character_offset that returns the rest; max_characters (up to \
            \(maxCharactersRange.upperBound)) sets the size of one window.

            Pass first_page and last_page (numbered from \(firstPageNumber), both included; \
            one alone runs to the end of the document) to get the text of those pages \
            instead of the body, each under a [page N] heading, through the same window. \
            Every page read is one more Apple event on every call, so ask for a few pages \
            at a time. A page number past the last page is moved to it, and the first \
            lines say so; a last_page before first_page is refused.

            The text is plain: Pages has no scriptable form of its formatting. A \
            password-protected document reports that it is locked instead of returning \
            empty text.
            """,
        inputSchema: object(
            properties: [
                "id": string(idHelp),
                "character_offset": integer(
                    """
                    Number of characters of the text to skip. A result that does not hold \
                    all of it says, in its first lines, the value to pass for the rest.
                    """, range: offsetRange, default: 0),
                "max_characters": integer(
                    "The most characters of the text to return.", range: maxCharactersRange,
                    default: defaultMaxCharacters),
                "first_page": pageNumber(
                    """
                    Return the text of the pages from this one on, instead of the body. \
                    Without last_page it runs to the last page.
                    """),
                "last_page": pageNumber(
                    """
                    Return the text of the pages up to and including this one, instead of \
                    the body. Without first_page it starts at page \(firstPageNumber).
                    """),
            ],
            required: ["id"]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true,
            openWorldHint: false)
    )

    // MARK: Writes

    static let create = Tool(
        name: createName,
        title: "Create a new document",
        description: """
            Creates a new, unsaved document in Pages — optionally from a named \
            template, with an initial body given as either 'body' (plain text) or \
            'paragraphs' (styled — headings, quotes; see 'paragraphs' below).

            Pages autosaves a new document into iCloud Drive within seconds of \
            creation, on its own schedule, whether or not save_document is ever called. \
            If this document is disposable, delete the file when done — this server has \
            no delete tool; use the filesystem server's trash tool.
            """,
        inputSchema: object(
            properties: [
                "template": string(
                    "Optional template name, exactly as Pages' own template chooser "
                        + "shows it. Omit for a blank document."),
                "body": string(bodyHelp),
                "paragraphs": paragraphsSchema(paragraphsHelp),
            ]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false
        )
    )

    static let open = Tool(
        name: openName,
        title: "Open an existing document",
        description: """
            Opens the Pages document at 'path' and returns its name, path, page count \
            and the id the other tools take. It does not return the text: read that with \
            document_get.

            If the file is password protected, Pages shows its own password prompt and \
            this call will block until someone answers it in the Pages window itself — \
            there is no way to detect that in advance, and no way to supply a password \
            through this server.
            """,
        inputSchema: object(
            properties: [
                "path": string("Absolute POSIX path to a .pages file.")
            ],
            required: ["path"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let update = Tool(
        name: updateName,
        title: "Append to or replace a document's body",
        description: """
            Changes an open document's body. 'mode' is REQUIRED and decides which of two \
            very different things happens:

              append   — adds your text to the end, keeping everything already there.
              replace  — DISCARDS THE WHOLE BODY and writes your text instead.

            replace cannot be undone by this server. If you are editing something that \
            already exists, read it with document_get first and use append unless the \
            person actually asked you to start over.

            Exactly one of 'body' (plain text) or 'paragraphs' (styled — see \
            'paragraphs' below) is required. 'paragraphs' only works with mode=replace: \
            splicing newly-styled paragraphs into an existing rich-text body at the \
            right position is not implemented, so append is refused with 'paragraphs'. \
            In append mode your plain 'body' text is concatenated onto the existing body \
            exactly as given — begin it with a newline yourself if you want one.

            Refuses a password-protected document: its current content cannot be read, \
            so neither mode could be carried out honestly.
            """,
        inputSchema: object(
            properties: [
                "id": string(idHelp),
                "mode": .object([
                    "type": .string("string"),
                    "enum": .array([.string("append"), .string("replace")]),
                    "description": .string(
                        "\"append\" keeps the existing body; \"replace\" discards it. "
                            + "Required — there is deliberately no default."),
                ]),
                "body": string(bodyHelp),
                "paragraphs": paragraphsSchema(
                    "\(paragraphsHelp)\n\nOnly valid with mode=replace."),
            ],
            required: ["id", "mode"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false
        )
    )

    static let save = Tool(
        name: saveName,
        title: "Save a document",
        description: """
            Saves an open document. Without 'path', saves to wherever it already lives \
            on disk — refused if it has never been saved at all. With 'path', saves \
            there instead, in Pages' own format.

            Requires confirm=true whenever a file already exists at the destination: \
            this overwrites it, and this server cannot undo that.

            Redirecting an already-saved document to a NEW path is where Pages' own \
            "save" command is least reliable — verified live: it can report success \
            while writing nothing at all. This server checks the destination file \
            actually exists afterwards and reports a failure honestly when it does not, \
            but if this call keeps failing for a document that already has a location, \
            export_document (format pages09) is the more reliable way to get a copy onto \
            disk at a new path.
            """,
        inputSchema: object(
            properties: [
                "id": string(idHelp),
                "path": string(
                    "Optional destination POSIX path. Required if the document has "
                        + "never been saved before."),
                "confirm": boolean(confirmHelp, default: false),
            ],
            required: ["id"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let close = Tool(
        name: closeName,
        title: "Close a document",
        description: """
            Closes an open document. Defaults to discarding any unsaved changes — \
            'saving'=true requires confirm=true and saves first.

            Refuses 'saving'=true on a document that has never been saved: Pages would \
            show its own save panel and block waiting for it. Call save_document with a \
            path first, then close.
            """,
        inputSchema: object(
            properties: [
                "id": string(idHelp),
                "saving": boolean("Save changes before closing.", default: false),
                "confirm": boolean(confirmHelp, default: false),
            ],
            required: ["id"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false)
    )

    static let export = Tool(
        name: exportName,
        title: "Export a document",
        description: """
            Exports an open document to 'to' in 'format'. 'to' MUST end in the extension \
            Pages itself expects for that format — anything else fails silently, with no \
            error and no file:

              pdf         .pdf
              word        .docx
              epub        .epub
              rtf         .rtf
              plain_text  .txt
              pages09     .pages

            An unusual or inaccessible destination is refused and reported rather than \
            silently rerouted — this server checks the file actually exists afterwards, \
            not just that Pages returned no error.

            Requires confirm=true whenever a file already exists at the destination.
            """,
        inputSchema: object(
            properties: [
                "id": string(idHelp),
                "to": string(
                    "Destination POSIX path, ending in the extension the chosen format "
                        + "requires (see above) — a mismatched extension is refused."),
                "format": .object([
                    "type": .string("string"),
                    "enum": .array(
                        ExportFormat.allCases.map { .string($0.rawValue) }),
                    "description": .string("Destination file format."),
                ]),
                "confirm": boolean(confirmHelp, default: false),
            ],
            required: ["id", "to", "format"]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false
        )
    )
}
