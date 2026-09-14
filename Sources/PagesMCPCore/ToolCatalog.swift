import Foundation
import MCP

/// The catalogue is the authorisation surface: a tool that is not listed here cannot be
/// called, and the name it is listed under is the label on the permission switch in
/// Claude Desktop. Reads carry no verb prefix; writes always start with a verb, so the
/// destructive ones are visible at a glance in the switch list.
public enum ToolCatalog {

    /// Names are constants rather than being read back off a `Tool`, because a tool whose
    /// schema depends on the configuration has to be built as a function and its name
    /// would then have nowhere stable to live.
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

    /// Built from the live configuration so a description never states a limit the
    /// running server does not actually enforce.
    public static func all(_ configuration: Configuration = Configuration()) -> [Tool] {
        [
            status, documentsList, get(configuration), create, open, update, save, close,
            export,
        ]
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

    private static func integer(_ description: String, minimum: Int, maximum: Int, default def: Int)
        -> Value
    {
        .object([
            "type": .string("integer"), "description": .string(description),
            "minimum": .int(minimum), "maximum": .int(maximum), "default": .int(def),
        ])
    }

    private static let idHelp = "Identifier returned by documents_list or by whichever tool opened it."

    private static let bodyHelp = """
        The document's whole body, as plain text. Pages' own dictionary types this as \
        rich text with no scriptable string form of the formatting, so this server can \
        only read and write the plain text — no markup, no styling.
        """

    private static let confirmHelp = "Must be true. Without it the call is refused."

    // MARK: Reads

    static let status = Tool(
        name: statusName,
        title: "Pages availability and settings",
        description: """
            Reports whether Pages is running, whether this server may automate it, and \
            what limits are in force. Touches no document.

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
            Lists every document currently open in Pages, with its page count and \
            whether it has unsaved changes.

            Pages has no library the way Notes has folders: this is the whole of what \
            can be asked about without opening something first. A file that is not \
            open yet does not appear here — call open_document for that.
            """,
        inputSchema: object(properties: [:]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static func get(_ configuration: Configuration) -> Tool {
        Tool(
            name: getName,
            title: "Read one open document",
            description: """
                Returns one open document's body text, page/section/table/image/chart \
                counts, and whether it is password protected.

                Text is cut at \(configuration.bodyTextLimit) characters unless \
                'text_limit' says otherwise, and the response says when it was cut. Pass \
                'by_page'=true to also get one plain-text string per page — one extra \
                Apple event per page, so only ask when the per-page breakdown actually \
                matters. A password-protected document reports that it is locked \
                instead of returning empty text.
                """,
            inputSchema: object(
                properties: [
                    "id": string(idHelp),
                    "by_page": boolean(
                        "Also return the body broken down one plain-text string per page.",
                        default: false),
                    "text_limit": integer(
                        "Maximum characters of body text to return.",
                        minimum: Configuration.bodyTextLimitRange.lowerBound,
                        maximum: Configuration.bodyTextLimitRange.upperBound,
                        default: configuration.bodyTextLimit),
                ],
                required: ["id"]),
            annotations: .init(
                readOnlyHint: true, destructiveHint: false, idempotentHint: true,
                openWorldHint: false)
        )
    }

    // MARK: Writes

    static let create = Tool(
        name: createName,
        title: "Create a new document",
        description: """
            Creates a new, unsaved document in Pages — optionally from a named \
            template, optionally with an initial plain-text body.

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
                "body": string(
                    "Optional initial body text, as plain text. Omit to start with an "
                        + "empty document."),
            ]),
        annotations: .init(
            readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false
        )
    )

    static let open = Tool(
        name: openName,
        title: "Open an existing document",
        description: """
            Opens the Pages document at 'path'. Returns the same detail document_get \
            would, so a separate call is not needed right after.

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
            Changes an open document's body text. 'mode' is REQUIRED and decides which \
            of two very different things happens:

              append   — adds your text to the end, keeping everything already there.
              replace  — DISCARDS THE WHOLE BODY and writes your text instead.

            replace cannot be undone by this server. If you are editing something that \
            already exists, read it with document_get first and use append unless the \
            person actually asked you to start over.

            In append mode your text is concatenated onto the existing body exactly as \
            given — begin it with a newline yourself if you want one.

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
            ],
            required: ["id", "mode", "body"]),
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
            Exports an open document to 'to' in 'format' — one of pdf, word, epub, rtf, \
            plain_text or pages09.

            Pages' own sandbox only accepts destinations under Desktop, Documents or \
            Downloads (or another folder separately granted); a path outside that is \
            refused by Pages itself and reported as such.

            Requires confirm=true whenever a file already exists at the destination.
            """,
        inputSchema: object(
            properties: [
                "id": string(idHelp),
                "to": string("Destination POSIX path, including the file extension."),
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
