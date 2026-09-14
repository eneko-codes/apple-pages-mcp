import Foundation

@testable import PagesMCPCore

/// An in-memory `PageStore`.
///
/// Every test in this suite runs against this double, so the suite never sends an Apple
/// event and never touches a document the owner wrote. Every fixture below is invented.
final class FakePageStore: PageStore, @unchecked Sendable {

    var availabilityValue: PagesAvailability = .ready
    var documentsValue: [String: DocumentDetail] = [:]
    var templateNames: [String] = ["Blank", "Essay", "Letter"]

    /// Set to make the next call fail, so the error path is reachable.
    var failure: (any Error)?

    // Recorded so a test can prove what a tool actually asked the store to do.
    private(set) var created: [DocumentDraft] = []
    private(set) var opened: [String] = []
    private(set) var updatedBodies: [(identifier: String, text: String)] = []
    private(set) var restyled: [(identifier: String, paragraphs: [StyledParagraph])] = []
    private(set) var saved: [(identifier: String, path: String?)] = []
    private(set) var closed: [(identifier: String, saving: Bool)] = []
    private(set) var exported: [(identifier: String, path: String, format: ExportFormat)] = []

    func availability() -> PagesAvailability { availabilityValue }

    func documents() async throws -> [DocumentSummary] {
        if let failure { throw failure }
        return documentsValue.values.map(\.summary)
    }

    func fetch(identifier: String, includePageTexts: Bool) async throws -> DocumentDetail? {
        if let failure { throw failure }
        guard let document = documentsValue[identifier] else { return nil }
        guard includePageTexts else {
            return DocumentDetail(summary: document.summary, bodyText: document.bodyText)
        }
        return document
    }

    func installedTemplateNames() async throws -> [String] {
        if let failure { throw failure }
        return templateNames
    }

    func create(_ draft: DocumentDraft) async throws -> DocumentDetail {
        if let failure { throw failure }
        created.append(draft)
        let identifier = "x-invented-\(created.count)"
        let text = draft.paragraphs.map { $0.map(\.text).joined(separator: "\n") } ?? draft.initialBodyText
        let document = Fixtures.document(
            id: identifier, name: text.map { String($0.prefix(40)) } ?? "Untitled",
            text: text ?? "", templateName: draft.templateName)
        documentsValue[identifier] = document
        return document
    }

    func open(path: String) async throws -> DocumentDetail {
        if let failure { throw failure }
        opened.append(path)
        let identifier = "x-opened-\(opened.count)"
        let document = Fixtures.document(
            id: identifier, name: (path as NSString).lastPathComponent, text: "opened contents",
            path: path)
        documentsValue[identifier] = document
        return document
    }

    func updateBody(identifier: String, text: String) async throws -> DocumentDetail {
        if let failure { throw failure }
        updatedBodies.append((identifier: identifier, text: text))
        guard let existing = documentsValue[identifier] else { throw ToolError.storeFailure("gone") }
        let updated = DocumentDetail(summary: existing.summary, bodyText: text)
        documentsValue[identifier] = updated
        return updated
    }

    func replaceStyledParagraphs(identifier: String, paragraphs: [StyledParagraph]) async throws
        -> DocumentDetail
    {
        if let failure { throw failure }
        restyled.append((identifier: identifier, paragraphs: paragraphs))
        guard let existing = documentsValue[identifier] else { throw ToolError.storeFailure("gone") }
        let text = paragraphs.map(\.text).joined(separator: "\n")
        let updated = DocumentDetail(summary: existing.summary, bodyText: text)
        documentsValue[identifier] = updated
        return updated
    }

    func save(identifier: String, path: String?) async throws -> DocumentDetail {
        if let failure { throw failure }
        guard let existing = documentsValue[identifier] else { throw ToolError.storeFailure("gone") }
        guard let destination = path ?? existing.summary.path else {
            throw ToolError.neverSaved(name: existing.name, action: "there is nowhere to save it")
        }
        saved.append((identifier: identifier, path: path))
        let resaved = DocumentDetail(
            summary: Fixtures.withPath(existing.summary, path: destination),
            bodyText: existing.bodyText)
        documentsValue[identifier] = resaved
        return resaved
    }

    func close(identifier: String, saving: Bool) async throws -> DocumentDetail {
        if let failure { throw failure }
        guard let existing = documentsValue[identifier] else { throw ToolError.storeFailure("gone") }
        if saving, existing.summary.path == nil {
            throw ToolError.neverSaved(
                name: existing.name,
                action: "closing with saving=true would make Pages show its own save panel")
        }
        closed.append((identifier: identifier, saving: saving))
        documentsValue.removeValue(forKey: identifier)
        return existing
    }

    func export(identifier: String, toPath: String, format: ExportFormat) async throws
        -> ExportReceipt
    {
        if let failure { throw failure }
        guard documentsValue[identifier] != nil else { throw ToolError.storeFailure("gone") }
        exported.append((identifier: identifier, path: toPath, format: format))
        return ExportReceipt(path: toPath, format: format)
    }
}

// MARK: - Fixtures

enum Fixtures {

    /// Invented throughout. Nothing here is taken from the owner's real documents.
    static func document(
        id: String, name: String, text: String, path: String? = nil, locked: Bool = false,
        templateName: String? = nil
    ) -> DocumentDetail {
        DocumentDetail(
            summary: DocumentSummary(
                identifier: id, name: name, path: path, pageCount: max(1, text.count / 2000),
                sectionCount: 1, tableCount: 0, imageCount: 0, chartCount: 0,
                isPasswordProtected: locked, hasBodyText: !text.isEmpty, hasFacingPages: false,
                isModified: path == nil, templateName: templateName),
            bodyText: locked ? "" : text)
    }

    static func withPath(_ summary: DocumentSummary, path: String) -> DocumentSummary {
        DocumentSummary(
            identifier: summary.identifier, name: summary.name, path: path,
            pageCount: summary.pageCount, sectionCount: summary.sectionCount,
            tableCount: summary.tableCount, imageCount: summary.imageCount,
            chartCount: summary.chartCount, isPasswordProtected: summary.isPasswordProtected,
            hasBodyText: summary.hasBodyText, hasFacingPages: summary.hasFacingPages,
            isModified: false, templateName: summary.templateName)
    }
}
