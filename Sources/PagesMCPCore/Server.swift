import Foundation
import MCP

public enum PagesMCPServer {

    public static let name = "apple-pages-mcp"
    public static let version = "1.0.0"

    /// Returned from `initialize`. It carries what per-tool descriptions cannot state
    /// once: the id workflow, the two rules that surprise people, and where policy lives.
    public static let instructions = """
        Access to the macOS Pages app through Apple events.

        Pages has no framework a separate process can use, so this server drives Pages \
        itself, the same way apple-notes-mcp drives Notes. The app may show as "Pages \
        Creator Studio" in permission dialogs and System Settings — that is a display \
        name Apple changed, not a different app.

        Pages has no library the way Notes has folders: it only knows about documents \
        open right now. Workflow: documents_list to see what is open, open_document for \
        a file that is not, then document_get for its content.

        document_get returns PLAIN TEXT and never reports paragraph styling — Pages' own \
        dictionary types body text as rich text with no scriptable string form of the \
        formatting, so there is no "ask for the markup instead" option the way note_get \
        has html=true, and no way to read back what style a paragraph was given.

        update_document requires an explicit mode. "append" adds to the end; "replace" \
        DISCARDS the whole body and cannot be undone from here.

        create_document and update_document (replace mode only) accept 'paragraphs' as \
        an alternative to plain-text 'body': one entry per paragraph, each styled as \
        title/heading1/heading2/heading3/quote/body via a fixed font/size/color preset — \
        the entire scriptable surface Pages exposes for a paragraph of rich text. This \
        is NOT one of Pages' own named paragraph styles (confirmed live: no such thing \
        is scriptable by any name) — a styled paragraph will not appear in a Table of \
        Contents and will not respond to a theme change, the same as manually formatted \
        text. quote is likewise an approximation (italic, grey); Pages has no real \
        block quote. Tables, \
        shapes, images and charts cannot be created through Pages' scripting interface \
        at all — confirmed live, not merely unimplemented here — so there is no tool for \
        any of them.

        Password-protected documents are listed but refused by every tool that would \
        read, write or export one — this server never accepts a password as an \
        argument, matching apple-pdf-mcp's policy for encrypted PDFs.

        Pages autosaves a newly created document into iCloud Drive within seconds, on \
        its own schedule, whether or not save_document is ever called. A document made \
        only to be discarded is not necessarily discarded by closing it without saving.

        Opening a password-protected file, or closing a never-saved document with \
        saving=true, would make Pages show its own dialog and block waiting for someone \
        at the keyboard — open_document and close_document say so and the latter \
        refuses outright rather than risk hanging.

        Write tools carry a verb prefix (create_, open_, update_, save_, close_, \
        export_). save_document and export_document require confirm=true whenever the \
        destination file already exists; close_document requires it for saving=true.

        This server has no delete tool of any kind — removing a document from disk is \
        the filesystem server's job, not this one's.

        A document's id can change on its own while it stays open — observed live, right \
        after a save. If a call reports "no open document has that id", call \
        documents_list again before assuming it closed.

        save_document redirecting an already-saved document to a NEW path is unreliable \
        in Pages itself — it can report success while writing nothing. This server \
        checks the file actually landed and fails honestly when it did not; \
        export_document (format pages09) is the more dependable way to get a copy onto \
        disk at a new path. export_document's destination must end in the extension the \
        chosen format expects (see its own description) — Pages silently writes nothing \
        for a mismatch, same as save.

        This server exposes Pages' full scriptable capability. What may be used at any \
        moment is decided by the permission switches in the client, not by this code.
        """

    /// The store is a parameter so the whole server can be driven by a double. Nothing
    /// in this function sends an Apple event by itself.
    public static func run(
        store: (any PageStore)? = nil,
        configuration: Configuration = Configuration()
    ) async throws {
        let store = store ?? ScriptingBridgePageStore()
        let tools = PageTools(store: store, configuration: configuration)
        let server = Server(
            name: name,
            version: version,
            instructions: instructions,
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: ToolCatalog.all(configuration))
        }
        await server.withMethodHandler(CallTool.self) { await tools.handle($0) }

        // The default StdioTransport logger is a no-op handler. Leave it that way: a
        // logger writing to stdout would interleave with the JSON-RPC stream and break
        // every response after the first log line.
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }
}
