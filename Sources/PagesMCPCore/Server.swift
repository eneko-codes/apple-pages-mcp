import Foundation

public enum PagesMCPServer {

    public static let name = "apple-pages-mcp"
    public static let version = "2.0.0"

    /// Returned from `initialize`. It carries what per-tool descriptions cannot state
    /// once: the id workflow, how a long result is reached, the rules that surprise
    /// people, and where policy lives.
    public static let instructions = """
        Access to the macOS Pages app through Apple events. Pages must be running; this \
        server never launches it. The app may show as "Pages Creator Studio" in permission \
        dialogs and System Settings: the same app under the name Apple now gives it.

        Pages has no library: it only knows the documents open right now. Workflow: \
        documents_list to see what is open, open_document for a file that is not, then \
        document_get for its content.

        EVERY RESULT IS BOUNDED AND SAYS WHAT IT LEFT OUT. document_get returns the first \
        \(ToolCatalog.defaultMaxCharacters) characters of the body; when there is more, the \
        first lines of the result say how much and the character_offset that returns the \
        rest (max_characters up to \(ToolCatalog.maxCharactersRange.upperBound) a window). \
        first_page and last_page return the text of those pages instead, through the same \
        window. documents_list returns \(ToolCatalog.defaultDocumentLimit) documents to a \
        page; limit and offset reach the rest. A size, an offset or a page number outside \
        its range is moved to the nearest allowed value and the first lines say which was \
        used; a wrong type is refused. A call not finished after \
        \(PageTools.defaultTimeout.components.seconds) seconds is abandoned and answered \
        with an error, but a write already sent to Pages may still take effect: check \
        before repeating it.

        document_get returns PLAIN TEXT and never reports paragraph styling: Pages has no \
        scriptable form of its formatting, so there is no way to read back what style a \
        paragraph was given.

        update_document requires an explicit mode. "append" adds to the end; "replace" \
        DISCARDS the whole body and cannot be undone from here.

        create_document and update_document (replace mode only) accept 'paragraphs' as \
        an alternative to plain-text 'body': one entry per paragraph, each styled as \
        title/heading1/heading2/heading3/quote/body through a fixed font, size and color. \
        These are NOT Pages' own named paragraph styles, which are not scriptable: a styled \
        paragraph will not appear in a Table of Contents and will not follow a theme \
        change, and quote is only italic grey text. Tables, shapes, images and charts \
        cannot be created through Pages' scripting interface at all, so there is no tool \
        for them.

        Password-protected documents are listed but refused by every tool that would \
        read, write or export one, and no tool accepts a password.

        Pages autosaves a newly created document into iCloud Drive within seconds, \
        whether or not save_document is ever called. A document made only to be discarded \
        is not necessarily discarded by closing it without saving.

        Opening a password-protected file makes Pages show its own dialog and wait for \
        someone at the keyboard; open_document cannot answer it and fails when its wait \
        runs out. close_document refuses saving=true on a never-saved document rather \
        than meet the same kind of dialog.

        Write tools carry a verb prefix (create_, open_, update_, save_, close_, \
        export_). save_document and export_document require confirm=true whenever the \
        destination file already exists; close_document requires it for saving=true. \
        There is no delete tool of any kind.

        A document's id can change on its own while it stays open, as seen right after a \
        save. If a call reports that no open document has that id, call documents_list \
        again before assuming it closed.

        save_document to a NEW path for an already-saved document is unreliable in Pages \
        itself: it can report success while writing nothing. This server checks that the \
        file landed and fails when it did not; export_document (format pages09) is the \
        dependable way to put a copy at a new path. Its destination must end in the \
        extension the format expects.

        What may be used at any moment is decided by the permission switches in the \
        client, not by this code.
        """

    /// The store is a parameter so the whole server can be driven by a double. Nothing
    /// in this function sends an Apple event by itself.
    public static func run(store: (any PageStore)? = nil) async {
        let store = store ?? ScriptingBridgePageStore()
        Diagnostics.started(version: version)
        await serveStandardStreams(handler: handler(tools: PageTools(store: store)))
    }

    public static func handler(tools: PageTools) -> MCPHandler {
        MCPHandler(
            name: name, version: version, instructions: instructions,
            catalog: ToolCatalog.all(), tools: tools)
    }
}
