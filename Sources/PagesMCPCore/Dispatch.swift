import Foundation
import Synchronization

/// Returns the first of two outcomes: the work finishing, or the limit passing.
///
/// The timer is a dispatch timer, not a `Task.sleep`, and the work is not a child of a task
/// group. An Apple event that Pages does not answer holds its thread and cannot be
/// cancelled, and a task group would wait for it forever; a timer on the cooperative pool
/// could be starved by the same stuck threads. The stuck work is abandoned, not stopped:
/// its late result is discarded.
enum Deadline {

    private final class Outcome<Value: Sendable>: Sendable {
        private let continuation: Mutex<CheckedContinuation<Value?, Never>?>

        init(_ continuation: CheckedContinuation<Value?, Never>) {
            self.continuation = Mutex(continuation)
        }

        /// Only the first caller resumes; the other finds it empty.
        func resume(returning value: Value?) {
            continuation.withLock { pending in
                pending?.resume(returning: value)
                pending = nil
            }
        }
    }

    /// `nil` when `limit` passed before `work` finished.
    static func run<Value: Sendable>(
        within limit: Duration, _ work: @escaping @Sendable () async -> Value
    ) async -> Value? {
        let seconds = Double(limit.components.seconds) + Double(limit.components.attoseconds) / 1e18
        return await withCheckedContinuation { continuation in
            let outcome = Outcome<Value>(continuation)
            let task = Task {
                outcome.resume(returning: await work())
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                outcome.resume(returning: nil)
                task.cancel()
            }
        }
    }
}

/// Routes a `tools/call` to the store and renders the answer.
///
/// Never sends an Apple event itself — everything goes through `PageStore`, which is
/// what lets the tests drive every branch below with Pages closed and no document
/// touched.
public struct PageTools: ToolHandler {
    private let store: any PageStore
    private let timeout: Duration
    private let format = Format()

    /// The bridge gives each Apple event 30 seconds, and a call that meets a dialog in
    /// Pages spends them on one event and then reports what happened. Twice that lets such
    /// a call give its own, clearer error, and still answers a call that is stuck on event
    /// after event well inside `ToolStandard.timeLimit`.
    public static let defaultTimeout = Duration.seconds(60)

    public init(store: any PageStore, timeout: Duration = PageTools.defaultTimeout) {
        self.store = store
        self.timeout = timeout
    }

    public func handle(_ parameters: ToolCall) async -> ToolOutput {
        let started = ContinuousClock.now
        let outcome = await Deadline.run(within: timeout) {
            do {
                return Result<String, any Error>.success(try await run(parameters))
            } catch {
                return .failure(error)
            }
        }
        switch outcome {
        case .success(let text)?:
            return ToolOutput(text: text, isError: false)
        case .failure(let error)?:
            return failure(error, tool: parameters.name, since: started)
        case nil:
            return failure(
                ToolError.timedOut(seconds: Int(timeout.components.seconds)),
                tool: parameters.name, since: started)
        }
    }

    private func failure(
        _ error: any Error, tool: String, since started: ContinuousClock.Instant
    ) -> ToolOutput {
        Diagnostics.toolFailed(tool, error: error, since: started)
        let message =
            (error as? ToolError)?.message
            ?? ToolError.storeFailure(error.localizedDescription).message
        return ToolOutput(text: message, isError: true)
    }

    private func run(_ parameters: ToolCall) async throws -> String {
        let arguments = Arguments(parameters.arguments)

        // Reports availability instead of failing on it: this is the tool you reach for
        // precisely when the others are refusing to work.
        if parameters.name == ToolCatalog.statusName {
            return format.status(
                store.availability(), binaryPath: Self.binaryPath, deadline: timeout)
        }

        let state = store.availability()
        // A call whose consent has never been asked for still has to go through: sending
        // the Apple event is what raises the dialog.
        guard !state.blocksCalls else { throw ToolError.notAvailable(state) }

        switch parameters.name {
        case ToolCatalog.documentsListName:
            return try await documents(arguments)

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
            throw ToolError.unknownTool(parameters.name)
        }
    }

    // MARK: Reads

    private func documents(_ arguments: Arguments) async throws -> String {
        let page = try arguments.page(
            defaultLimit: ToolCatalog.defaultDocumentLimit, limits: ToolCatalog.documentLimitRange)
        // Pages lists its documents front window first, which changes whenever someone
        // clicks one. A page boundary needs an order that does not.
        let open = try await store.documents().sorted(by: Self.precedes)
        return ToolStandard.page(
            of: open, limit: page.limit, offset: page.offset, things: "documents",
            notices: arguments.notices
        ) {
            format.documents($0, matching: open.count)
        }
    }

    /// By name as the Finder would order it, then by id, so that two documents never tie:
    /// several untitled ones share a name.
    static func precedes(_ first: DocumentSummary, _ second: DocumentSummary) -> Bool {
        let order = first.name.compare(second.name, options: [.caseInsensitive, .numeric])
        if order != .orderedSame { return order == .orderedAscending }
        if first.name != second.name { return first.name < second.name }
        return first.identifier < second.identifier
    }

    private func get(_ arguments: Arguments) async throws -> String {
        let identifier = try arguments.requiredString("id")
        let window = try arguments.window()
        let firstAsked = try arguments.wholeNumber("first_page")
        let lastAsked = try arguments.wholeNumber("last_page")
        var notices = arguments.notices

        guard firstAsked != nil || lastAsked != nil else {
            let document = try await requireOpenDocument(identifier, pages: nil)
            return ToolStandard.fitting(window.maxCharacters) {
                format.detail(
                    document, characterOffset: window.characterOffset, maxCharacters: $0,
                    notices: notices)
            }
        }

        if let firstAsked, let lastAsked, lastAsked < firstAsked {
            throw ToolError.badArgument(
                name: "last_page",
                reason: "\(lastAsked) is before first_page=\(firstAsked). Pages are numbered "
                    + "from \(ToolCatalog.firstPageNumber) and both ends are included, so "
                    + "last_page must be first_page or a later page.")
        }

        // The page count is only known once the document has been read, so the pages are
        // asked for as sent and moved into the document afterwards. Only a first_page
        // past the last page makes the store return none of what the moved range holds,
        // and costs a second read.
        let lowest = ToolCatalog.firstPageNumber
        let askedFirst = max(firstAsked ?? lowest, lowest)
        let askedLast = max(lastAsked ?? Int.max, askedFirst)
        var document = try await requireOpenDocument(identifier, pages: askedFirst...askedLast)
        let pageCount = document.summary.pageCount

        guard pageCount >= lowest, !document.summary.isPasswordProtected else {
            return format.detail(
                document, firstPage: lowest, characterOffset: window.characterOffset,
                maxCharacters: window.maxCharacters, notices: notices)
        }
        let existing = lowest...pageCount
        let first = firstAsked.map {
            ToolStandard.clamp($0, to: existing, argument: "first_page", notices: &notices)
        } ?? lowest
        let last = lastAsked.map {
            ToolStandard.clamp($0, to: existing, argument: "last_page", notices: &notices)
        } ?? pageCount
        if first != askedFirst {
            document = try await requireOpenDocument(identifier, pages: first...last)
        }

        return ToolStandard.fitting(window.maxCharacters) {
            format.detail(
                document, firstPage: first, characterOffset: window.characterOffset,
                maxCharacters: $0, notices: notices)
        }
    }

    // MARK: Writes

    private func create(_ arguments: Arguments) async throws -> String {
        let templateName = try arguments.optionalString("template")
        if let templateName {
            let installed = try await store.installedTemplateNames()
            guard installed.contains(where: { $0.caseInsensitiveCompare(templateName) == .orderedSame })
            else { throw ToolError.templateNotFound(name: templateName, available: installed) }
        }

        let body = try arguments.optionalBody("body")
        let paragraphs = try arguments.optionalParagraphs("paragraphs")
        guard body == nil || paragraphs == nil else {
            throw ToolError.badArgument(
                name: "paragraphs", reason: "cannot be given together with 'body' — pick one")
        }

        let draft = DocumentDraft(
            templateName: templateName, initialBodyText: body, paragraphs: paragraphs)
        return format.created(try await store.create(draft))
    }

    private func update(_ arguments: Arguments) async throws -> String {
        let identifier = try arguments.requiredString("id")
        // Decoded before the document is fetched so a missing or misspelt mode is
        // reported without a round trip, and so no path can reach the store with mode
        // unresolved.
        let mode = try arguments.updateMode("mode")
        let body = try arguments.optionalBody("body")
        let paragraphs = try arguments.optionalParagraphs("paragraphs")
        switch (body, paragraphs) {
        case (nil, nil):
            throw ToolError.badArgument(
                name: "body", reason: "either 'body' or 'paragraphs' is required")
        case (.some, .some):
            throw ToolError.badArgument(
                name: "paragraphs", reason: "cannot be given together with 'body' — pick one")
        default:
            break
        }
        if paragraphs != nil, mode != .replace {
            throw ToolError.badArgument(
                name: "paragraphs",
                reason: "only works with mode=replace — splicing styled paragraphs into "
                    + "an existing body at the right position is not implemented")
        }

        let existing = try await requireOpenDocument(identifier, pages: nil)
        guard !existing.summary.isPasswordProtected else {
            throw ToolError.documentPasswordProtected(
                name: existing.name, action: mode == .append ? "appending to it" : "replacing it")
        }

        if let paragraphs {
            let updated = try await store.replaceStyledParagraphs(
                identifier: identifier, paragraphs: paragraphs)
            return format.updated(updated, mode: mode, previousLength: existing.bodyText.count)
        }

        // Read, compose, write. A document edited in Pages.app between those two steps
        // loses that edit, which is inherent to a scripting interface with no
        // compare-and-swap — it is why append exists rather than making the caller send
        // the whole body back.
        let composed: String
        switch mode {
        case .append:
            composed = existing.bodyText + (body ?? "")
        case .replace:
            composed = body ?? ""
        }
        guard !composed.isEmpty else {
            throw ToolError.badArgument(
                name: "body",
                reason: "it is empty. A document with no content cannot be told apart "
                    + "from a mistake, and replacing one with nothing is the mistake this "
                    + "server refuses hardest.")
        }

        let updated = try await store.updateBody(identifier: identifier, text: composed)
        return format.updated(updated, mode: mode, previousLength: existing.bodyText.count)
    }

    private func save(_ arguments: Arguments) async throws -> String {
        let identifier = try arguments.requiredString("id")
        let requestedPath = try arguments.optionalString("path")
        let confirmed = try arguments.bool("confirm")
        let existing = try await requireOpenDocument(identifier, pages: nil)
        guard !existing.summary.isPasswordProtected else {
            throw ToolError.documentPasswordProtected(name: existing.name, action: "saving it")
        }

        if let destination = requestedPath ?? existing.summary.path,
            FileManager.default.fileExists(atPath: destination), !confirmed
        {
            // A path the caller sent is repeated clipped; the document's own path is
            // Pages' data, not the caller's text, and is what the person has to recognise.
            let named = requestedPath.map(ToolStandard.echo) ?? destination
            throw ToolError.confirmationRequired(action: "Saving over '\(named)'")
        }

        return format.saved(try await store.save(identifier: identifier, path: requestedPath))
    }

    private func close(_ arguments: Arguments) async throws -> String {
        let identifier = try arguments.requiredString("id")
        let saving = try arguments.bool("saving")
        // Read whether or not it is needed, so that a confirm of the wrong type is refused
        // on every call and not only on the one that would overwrite something.
        let confirmed = try arguments.bool("confirm")
        if saving, !confirmed {
            throw ToolError.confirmationRequired(
                action: "Closing '\(ToolStandard.echo(identifier))' with saving=true")
        }
        return format.closed(try await store.close(identifier: identifier, saving: saving), saved: saving)
    }

    private func export(_ arguments: Arguments) async throws -> String {
        let identifier = try arguments.requiredString("id")
        let destination = try arguments.requiredString("to")
        let exportFormat = try arguments.exportFormat("format")
        let confirmed = try arguments.bool("confirm")

        let existing = try await requireOpenDocument(identifier, pages: nil)
        guard !existing.summary.isPasswordProtected else {
            throw ToolError.documentPasswordProtected(name: existing.name, action: "exporting it")
        }
        if FileManager.default.fileExists(atPath: destination), !confirmed {
            throw ToolError.confirmationRequired(
                action: "Exporting over '\(ToolStandard.echo(destination))'")
        }

        let receipt = try await store.export(
            identifier: identifier, toPath: destination, format: exportFormat)
        return format.exported(receipt, from: existing)
    }

    // MARK: Documents

    /// Loads a document. Every tool that takes an id goes through here.
    private func requireOpenDocument(_ identifier: String, pages: ClosedRange<Int>?) async throws
        -> DocumentDetail
    {
        guard let document = try await store.fetch(identifier: identifier, pages: pages)
        else { throw ToolError.notFound(identifier: identifier) }
        return document
    }

    static var binaryPath: String {
        CommandLine.arguments.first.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            ?? "(unknown)"
    }
}
