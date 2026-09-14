import Foundation
import MCP
import Testing

@testable import PagesMCPCore

/// Drives the tool layer end to end against `FakePageStore`. No test here sends an
/// Apple event, so the suite runs with Pages closed, no Automation consent, and nothing
/// the owner wrote at risk.
@Suite("Tool dispatch")
struct PageToolsTests {

    private func call(
        _ name: String, _ arguments: [String: Value] = [:],
        store: FakePageStore = FakePageStore(),
        configuration: Configuration = Configuration()
    ) async -> (text: String, isError: Bool) {
        let tools = PageTools(store: store, configuration: configuration)
        let result = await tools.handle(.init(name: name, arguments: arguments))
        guard case .text(let text, _, _) = result.content.first else {
            return ("(no text content)", true)
        }
        return (text, result.isError ?? false)
    }

    private func stocked() -> FakePageStore {
        let store = FakePageStore()
        store.documentsValue = [
            "d1": Fixtures.document(
                id: "d1", name: "Report.pages", text: "Quarterly figures follow.",
                path: "/Users/user/Documents/Report.pages"),
            "d2": Fixtures.document(id: "d2", name: "Untitled", text: "draft thoughts"),
            "d3": Fixtures.document(id: "d3", name: "Sealed.pages", text: "", locked: true),
        ]
        return store
    }

    // MARK: Catalogue

    @Test("Every tool has a unique name, title and description")
    func catalogueIsWellFormed() {
        let tools = ToolCatalog.all()
        let names = tools.map(\.name)
        #expect(names.count == Set(names).count)
        for tool in tools {
            #expect(tool.description?.isEmpty == false, "\(tool.name) has no description")
            #expect(tool.title?.isEmpty == false, "\(tool.name) has no title")
        }
    }

    /// Claude Desktop's schema sanitiser drops a property whose `type` is a union and
    /// hands the model a bare `{}` instead, which stays invisible until a caller happens
    /// to use that field.
    @Test("No property declares a union type")
    func noUnionTypesInSchemas() {
        for tool in ToolCatalog.all() {
            guard case .object(let schema) = tool.inputSchema,
                case .object(let properties)? = schema["properties"]
            else { continue }
            for (property, definition) in properties {
                guard case .object(let fields) = definition else { continue }
                if case .array = fields["type"] {
                    Issue.record("\(tool.name).\(property) declares a union type")
                }
            }
        }
    }

    @Test("Only the writing tools are marked as writes")
    func annotationsAreHonest() {
        let writes = [
            ToolCatalog.createName, ToolCatalog.openName, ToolCatalog.updateName,
            ToolCatalog.saveName, ToolCatalog.closeName, ToolCatalog.exportName,
        ]
        for tool in ToolCatalog.all() {
            #expect(
                tool.annotations.readOnlyHint == !writes.contains(tool.name),
                "\(tool.name) is mis-annotated")
        }
    }

    // MARK: Availability

    @Test("A tool call is refused when Pages is not running")
    func refusesWhenNotRunning() async {
        let store = stocked()
        store.availabilityValue = .notRunning
        let (text, isError) = await call(ToolCatalog.documentsListName, store: store)
        #expect(isError)
        #expect(text.contains("running"))
    }

    /// macOS only raises the Automation dialog when a real Apple event is sent, so
    /// refusing this state would mean the dialog never appears and consent could never
    /// be granted at all.
    @Test("Ungranted consent does not block the call that would trigger the prompt")
    func consentNotGrantedStillProceeds() async {
        let store = stocked()
        store.availabilityValue = .consentNotGranted
        let (_, isError) = await call(ToolCatalog.documentsListName, store: store)
        #expect(!isError)
    }

    @Test("pages_status works while Pages is unreachable")
    func statusWorksWhenUnavailable() async {
        let store = stocked()
        store.availabilityValue = .automationDenied
        let (text, isError) = await call(ToolCatalog.statusName, store: store)
        #expect(!isError)
        #expect(!text.isEmpty)
    }

    // MARK: Reads

    @Test("documents_list reports every open document")
    func documentsListShowsOpenDocuments() async {
        let (text, isError) = await call(ToolCatalog.documentsListName, store: stocked())
        #expect(!isError)
        #expect(text.contains("Report.pages"))
        #expect(text.contains("Sealed.pages"))
    }

    @Test("document_get returns the body as plain text")
    func documentGetReturnsPlainText() async {
        let (text, isError) = await call(
            ToolCatalog.getName, ["id": .string("d1")], store: stocked())
        #expect(!isError)
        #expect(text.contains("Quarterly figures"))
    }

    /// A locked document is visible but unreadable. Returning empty text would look
    /// like an empty document rather than a sealed one.
    @Test("A password-protected document says it is locked rather than returning nothing")
    func lockedDocumentIsReported() async {
        let (text, _) = await call(ToolCatalog.getName, ["id": .string("d3")], store: stocked())
        #expect(text.lowercased().contains("lock"))
    }

    @Test("An unknown id says so")
    func unknownIDIsNamed() async {
        let (text, isError) = await call(
            ToolCatalog.getName, ["id": .string("nope")], store: stocked())
        #expect(isError)
        #expect(text.contains("nope"))
    }

    @Test("An unknown tool name is refused")
    func unknownToolIsRefused() async {
        let (_, isError) = await call("pages_delete_everything", store: stocked())
        #expect(isError)
    }

    // MARK: Writes

    @Test("create_document reaches the store with the template and body it was given")
    func createPassesThrough() async {
        let store = stocked()
        let (_, isError) = await call(
            ToolCatalog.createName,
            ["template": .string("Essay"), "body": .string("ZZTest fixture body")], store: store)
        #expect(!isError)
        #expect(store.created.count == 1)
        #expect(store.created.first?.templateName == "Essay")
    }

    @Test("create_document refuses a template that is not installed")
    func createRefusesUnknownTemplate() async {
        let store = stocked()
        let (text, isError) = await call(
            ToolCatalog.createName, ["template": .string("Nonexistent")], store: store)
        #expect(isError)
        #expect(store.created.isEmpty)
        #expect(text.contains("Nonexistent"))
    }

    @Test("create_document accepts styled paragraphs as an alternative to body")
    func createAcceptsStyledParagraphs() async {
        let store = stocked()
        let (_, isError) = await call(
            ToolCatalog.createName,
            [
                "paragraphs": .array([
                    .object(["text": .string("ZZTest Title"), "style": .string("title")]),
                    .object(["text": .string("Plain paragraph")]),
                ])
            ], store: store)
        #expect(!isError)
        #expect(store.created.count == 1)
        #expect(store.created.first?.paragraphs?.map(\.style) == [.title, .body])
        #expect(store.created.first?.paragraphs?.map(\.text) == ["ZZTest Title", "Plain paragraph"])
    }

    @Test("create_document refuses body and paragraphs together")
    func createRefusesBodyAndParagraphsTogether() async {
        let store = stocked()
        let (text, isError) = await call(
            ToolCatalog.createName,
            [
                "body": .string("x"),
                "paragraphs": .array([.object(["text": .string("y")])]),
            ], store: store)
        #expect(isError)
        #expect(store.created.isEmpty)
        #expect(text.contains("paragraphs"))
    }

    @Test("create_document refuses an unknown paragraph style")
    func createRefusesUnknownParagraphStyle() async {
        let store = stocked()
        let (text, isError) = await call(
            ToolCatalog.createName,
            [
                "paragraphs": .array([
                    .object(["text": .string("x"), "style": .string("h1")])
                ])
            ], store: store)
        #expect(isError)
        #expect(store.created.isEmpty)
        #expect(text.contains("h1"))
    }

    @Test("create_document refuses a paragraph whose text contains a newline")
    func createRefusesEmbeddedNewline() async {
        let store = stocked()
        let (text, isError) = await call(
            ToolCatalog.createName,
            ["paragraphs": .array([.object(["text": .string("line one\nline two")])])],
            store: store)
        #expect(isError)
        #expect(store.created.isEmpty)
        #expect(text.contains("newline"))
    }

    /// The footgun this server is designed against: silently replacing a whole body.
    /// `mode` is required, so neither the model nor a slip can default into destruction.
    @Test("update_document refuses to guess between appending and replacing")
    func updateRequiresAnExplicitMode() async {
        let store = stocked()
        let (text, isError) = await call(
            ToolCatalog.updateName,
            ["id": .string("d2"), "body": .string("more text")], store: store)
        #expect(isError)
        #expect(store.updatedBodies.isEmpty)
        #expect(text.lowercased().contains("mode"))
    }

    @Test("update_document in append mode keeps what was already there")
    func appendKeepsExistingText() async {
        let store = stocked()
        let (_, isError) = await call(
            ToolCatalog.updateName,
            [
                "id": .string("d2"), "body": .string(" and more."), "mode": .string("append"),
            ],
            store: store)
        #expect(!isError)
        let written = store.updatedBodies.first?.text ?? ""
        #expect(written.contains("draft thoughts"), "append must not drop the existing body")
        #expect(written.contains("and more"))
    }

    @Test("update_document in replace mode replaces")
    func replaceReplaces() async {
        let store = stocked()
        let (_, isError) = await call(
            ToolCatalog.updateName,
            ["id": .string("d2"), "body": .string("only this"), "mode": .string("replace")],
            store: store)
        #expect(!isError)
        let written = store.updatedBodies.first?.text ?? ""
        #expect(written == "only this")
    }

    @Test("update_document replace accepts styled paragraphs as an alternative to body")
    func updateReplaceAcceptsStyledParagraphs() async {
        let store = stocked()
        let (_, isError) = await call(
            ToolCatalog.updateName,
            [
                "id": .string("d2"), "mode": .string("replace"),
                "paragraphs": .array([
                    .object(["text": .string("Heading"), "style": .string("heading1")]),
                    .object(["text": .string("A quote"), "style": .string("quote")]),
                ]),
            ], store: store)
        #expect(!isError)
        #expect(store.restyled.first?.identifier == "d2")
        #expect(store.restyled.first?.paragraphs.map(\.style) == [.heading1, .quote])
    }

    @Test("update_document refuses paragraphs with mode=append")
    func updateRefusesParagraphsWithAppend() async {
        let store = stocked()
        let (text, isError) = await call(
            ToolCatalog.updateName,
            [
                "id": .string("d2"), "mode": .string("append"),
                "paragraphs": .array([.object(["text": .string("x")])]),
            ], store: store)
        #expect(isError)
        #expect(store.restyled.isEmpty)
        #expect(text.contains("replace"))
    }

    @Test("update_document requires exactly one of body or paragraphs")
    func updateRequiresBodyOrParagraphs() async {
        let store = stocked()
        let (_, missingBoth) = await call(
            ToolCatalog.updateName, ["id": .string("d2"), "mode": .string("replace")], store: store)
        #expect(missingBoth)

        let (_, both) = await call(
            ToolCatalog.updateName,
            [
                "id": .string("d2"), "mode": .string("replace"), "body": .string("x"),
                "paragraphs": .array([.object(["text": .string("y")])]),
            ], store: store)
        #expect(both)
    }

    @Test("update_document refuses a password-protected document")
    func updateRefusesLocked() async {
        let store = stocked()
        let (text, isError) = await call(
            ToolCatalog.updateName,
            ["id": .string("d3"), "body": .string("x"), "mode": .string("replace")], store: store)
        #expect(isError)
        #expect(store.updatedBodies.isEmpty)
        #expect(text.lowercased().contains("password"))
    }

    @Test("open_document passes the path to the store")
    func openPassesThrough() async {
        let store = stocked()
        let (_, isError) = await call(
            ToolCatalog.openName, ["path": .string("/Users/user/Documents/Other.pages")],
            store: store)
        #expect(!isError)
        #expect(store.opened == ["/Users/user/Documents/Other.pages"])
    }

    @Test("save_document without confirm refuses to overwrite an existing file")
    func saveRequiresConfirmOverExisting() async throws {
        let store = stocked()
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-pages-mcp-test-\(UUID().uuidString).pages")
        try Data().write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let (text, isError) = await call(
            ToolCatalog.saveName,
            ["id": .string("d2"), "path": .string(tempFile.path)], store: store)
        #expect(isError)
        #expect(store.saved.isEmpty)
        #expect(text.contains("confirm"))
    }

    @Test("save_document proceeds without confirm when nothing exists at the destination")
    func saveProceedsWhenDestinationIsClear() async {
        let store = stocked()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-pages-mcp-test-\(UUID().uuidString).pages").path
        let (_, isError) = await call(
            ToolCatalog.saveName, ["id": .string("d2"), "path": .string(destination)], store: store)
        #expect(!isError)
        #expect(store.saved.first?.path == destination)
    }

    @Test("save_document refuses a password-protected document")
    func saveRefusesLocked() async {
        let store = stocked()
        let (text, isError) = await call(
            ToolCatalog.saveName, ["id": .string("d3"), "path": .string("/tmp/x.pages")],
            store: store)
        #expect(isError)
        #expect(store.saved.isEmpty)
        #expect(text.lowercased().contains("password"))
    }

    @Test("close_document defaults to discarding, no confirm required")
    func closeDefaultsToDiscarding() async {
        let store = stocked()
        let (_, isError) = await call(
            ToolCatalog.closeName, ["id": .string("d1")], store: store)
        #expect(!isError)
        #expect(store.closed.first?.saving == false)
    }

    @Test("close_document with saving=true requires confirm=true")
    func closeRequiresConfirmWhenSaving() async {
        let store = stocked()
        let (text, isError) = await call(
            ToolCatalog.closeName, ["id": .string("d1"), "saving": .bool(true)], store: store)
        #expect(isError)
        #expect(store.closed.isEmpty)
        #expect(text.contains("confirm"))
    }

    @Test("close_document with saving=true and confirm=true saves first")
    func closeSavesWhenConfirmed() async {
        let store = stocked()
        let (_, isError) = await call(
            ToolCatalog.closeName,
            ["id": .string("d1"), "saving": .bool(true), "confirm": .bool(true)], store: store)
        #expect(!isError)
        #expect(store.closed.first?.saving == true)
    }

    @Test("export_document without confirm refuses to overwrite an existing file")
    func exportRequiresConfirmOverExisting() async throws {
        let store = stocked()
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-pages-mcp-test-\(UUID().uuidString).pdf")
        try Data().write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let (text, isError) = await call(
            ToolCatalog.exportName,
            ["id": .string("d1"), "to": .string(tempFile.path), "format": .string("pdf")],
            store: store)
        #expect(isError)
        #expect(store.exported.isEmpty)
        #expect(text.contains("confirm"))
    }

    @Test("export_document refuses a password-protected document")
    func exportRefusesLocked() async {
        let store = stocked()
        let (text, isError) = await call(
            ToolCatalog.exportName,
            ["id": .string("d3"), "to": .string("/tmp/x.pdf"), "format": .string("pdf")],
            store: store)
        #expect(isError)
        #expect(store.exported.isEmpty)
        #expect(text.lowercased().contains("password"))
    }

    @Test("export_document rejects a format that is not one of Pages' own")
    func exportRejectsUnknownFormat() async {
        let store = stocked()
        let (text, isError) = await call(
            ToolCatalog.exportName,
            ["id": .string("d1"), "to": .string("/tmp/x.zzz"), "format": .string("zzz")],
            store: store)
        #expect(isError)
        #expect(store.exported.isEmpty)
        #expect(text.contains("zzz"))
    }

    @Test("A store failure is reported rather than swallowed")
    func storeFailureIsReported() async {
        let store = stocked()
        store.failure = ToolError.storeFailure("Pages stopped responding")
        let (text, isError) = await call(ToolCatalog.documentsListName, store: store)
        #expect(isError)
        #expect(text.contains("Pages"))
    }
}
