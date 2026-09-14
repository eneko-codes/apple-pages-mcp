import Foundation
import MCP

/// Routes a `tools/call` to the store and renders the answer.
///
/// Never sends an Apple event itself — everything goes through `PageStore`, which is
/// what lets the tests drive every branch below with Pages closed and no document
/// touched.
public struct PageTools: Sendable {
    private let store: any PageStore
    private let configuration: Configuration
    private let format: Format

    public init(store: any PageStore, configuration: Configuration = Configuration()) {
        self.store = store
        self.configuration = configuration
        self.format = Format()
    }

    public func handle(_ parameters: CallTool.Parameters) async -> CallTool.Result {
        do {
            let text = try await run(parameters)
            return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
        } catch let error as ToolError {
            return .init(
                content: [.text(text: error.message, annotations: nil, _meta: nil)], isError: true)
        } catch {
            return .init(
                content: [
                    .text(
                        text: ToolError.storeFailure(error.localizedDescription).message,
                        annotations: nil, _meta: nil)
                ], isError: true)
        }
    }

    private func run(_ parameters: CallTool.Parameters) async throws -> String {
        let arguments = Arguments(parameters.arguments)

        // Reports availability instead of failing on it: this is the tool you reach for
        // precisely when the others are refusing to work.
        if parameters.name == ToolCatalog.statusName {
            return format.status(
                store.availability(), binaryPath: Self.binaryPath, configuration: configuration)
        }

        let state = store.availability()
        // A call whose consent has never been asked for still has to go through: sending
        // the Apple event is what raises the dialog.
        guard !state.blocksCalls else { throw ToolError.notAvailable(state) }

        switch parameters.name {
        case ToolCatalog.documentsListName:
            return format.documents(try await store.documents())

        case ToolCatalog.getName:
            return try await get(arguments)

        case ToolCatalog.createName:
            return try await create(arguments)

        case ToolCatalog.openName:
            let document = try await store.open(path: try arguments.requiredString("path"))
            return format.opened(document)

        case ToolCatalog.updateName:
            return try await update(arguments)

        case ToolCatalog.saveName:
            return try await save(arguments)

        case ToolCatalog.closeName:
            return try await close(arguments)

        case ToolCatalog.exportName:
            return try await export(arguments)

        default:
            throw ToolError.badArgument(
                name: "name", reason: "'\(parameters.name)' is not a tool of this server")
        }
    }

    // MARK: Reads

    private func get(_ arguments: Arguments) async throws -> String {
        let wantsPages = arguments.bool("by_page")
        let document = try await requireOpenDocument(
            try arguments.requiredString("id"), includePageTexts: wantsPages)
        let limit = try arguments.int(
            "text_limit", default: configuration.bodyTextLimit,
            in: Configuration.bodyTextLimitRange)

        // Truncation lives here rather than in the store so the policy is reachable from
        // a test.
        let truncated = document.bodyText.count > limit
        let text = truncated ? String(document.bodyText.prefix(limit)) : document.bodyText
        return format.detail(document, text: text, truncated: truncated)
    }

    // MARK: Writes

    private func create(_ arguments: Arguments) async throws -> String {
        let templateName = arguments.optionalString("template")
        if let templateName {
            let installed = try await store.installedTemplateNames()
            guard installed.contains(where: { $0.caseInsensitiveCompare(templateName) == .orderedSame })
            else { throw ToolError.templateNotFound(name: templateName, available: installed) }
        }
        let draft = DocumentDraft(
            templateName: templateName, initialBodyText: arguments.optionalString("body"))
        return format.created(try await store.create(draft))
    }

    private func update(_ arguments: Arguments) async throws -> String {
        let identifier = try arguments.requiredString("id")
        // Decoded before the document is fetched so a missing or misspelt mode is
        // reported without a round trip, and so no path can reach the store with mode
        // unresolved.
        let mode = try arguments.updateMode("mode")
        let body = try arguments.requiredBody("body")

        let existing = try await requireOpenDocument(identifier, includePageTexts: false)
        guard !existing.summary.isPasswordProtected else {
            throw ToolError.documentPasswordProtected(
                name: existing.name, action: mode == .append ? "appending to it" : "replacing it")
        }

        // Read, compose, write. A document edited in Pages.app between those two steps
        // loses that edit, which is inherent to a scripting interface with no
        // compare-and-swap — it is why append exists rather than making the caller send
        // the whole body back.
        let composed: String
        switch mode {
        case .append:
            composed = existing.bodyText + body
        case .replace:
            composed = body
        }

        let updated = try await store.updateBody(identifier: identifier, text: composed)
        return format.updated(updated, mode: mode, previousLength: existing.bodyText.count)
    }

    private func save(_ arguments: Arguments) async throws -> String {
        let identifier = try arguments.requiredString("id")
        let requestedPath = arguments.optionalString("path")
        let existing = try await requireOpenDocument(identifier, includePageTexts: false)
        guard !existing.summary.isPasswordProtected else {
            throw ToolError.documentPasswordProtected(name: existing.name, action: "saving it")
        }

        if let destination = requestedPath ?? existing.summary.path,
            FileManager.default.fileExists(atPath: destination), !arguments.bool("confirm")
        {
            throw ToolError.confirmationRequired(action: "Saving over '\(destination)'")
        }

        return format.saved(try await store.save(identifier: identifier, path: requestedPath))
    }

    private func close(_ arguments: Arguments) async throws -> String {
        let identifier = try arguments.requiredString("id")
        let saving = arguments.bool("saving")
        if saving, !arguments.bool("confirm") {
            throw ToolError.confirmationRequired(action: "Closing '\(identifier)' with saving=true")
        }
        return format.closed(try await store.close(identifier: identifier, saving: saving), saved: saving)
    }

    private func export(_ arguments: Arguments) async throws -> String {
        let identifier = try arguments.requiredString("id")
        let destination = try arguments.requiredString("to")
        let exportFormat = try arguments.exportFormat("format")

        let existing = try await requireOpenDocument(identifier, includePageTexts: false)
        guard !existing.summary.isPasswordProtected else {
            throw ToolError.documentPasswordProtected(name: existing.name, action: "exporting it")
        }
        if FileManager.default.fileExists(atPath: destination), !arguments.bool("confirm") {
            throw ToolError.confirmationRequired(action: "Exporting over '\(destination)'")
        }

        let receipt = try await store.export(
            identifier: identifier, toPath: destination, format: exportFormat)
        return format.exported(receipt, from: existing)
    }

    // MARK: Documents

    /// Loads a document. Every tool that takes an id goes through here.
    private func requireOpenDocument(_ identifier: String, includePageTexts: Bool) async throws
        -> DocumentDetail
    {
        guard
            let document = try await store.fetch(
                identifier: identifier, includePageTexts: includePageTexts)
        else { throw ToolError.notFound(identifier: identifier) }
        return document
    }

    static var binaryPath: String {
        CommandLine.arguments.first.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            ?? "(unknown)"
    }
}
