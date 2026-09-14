import Foundation

/// One open document, without its body text — what `documents_list` shows.
public struct DocumentSummary: Sendable, Equatable {
    public let identifier: String
    public let name: String
    /// `nil` for a document that has never been saved — a different fact from an empty
    /// path, which Pages never actually reports.
    public let path: String?
    public let pageCount: Int
    public let sectionCount: Int
    public let tableCount: Int
    public let imageCount: Int
    public let chartCount: Int
    public let isPasswordProtected: Bool
    public let hasBodyText: Bool
    public let hasFacingPages: Bool
    public let isModified: Bool
    public let templateName: String?

    public init(
        identifier: String, name: String, path: String?, pageCount: Int, sectionCount: Int,
        tableCount: Int, imageCount: Int, chartCount: Int, isPasswordProtected: Bool,
        hasBodyText: Bool, hasFacingPages: Bool, isModified: Bool, templateName: String?
    ) {
        self.identifier = identifier
        self.name = name
        self.path = path
        self.pageCount = pageCount
        self.sectionCount = sectionCount
        self.tableCount = tableCount
        self.imageCount = imageCount
        self.chartCount = chartCount
        self.isPasswordProtected = isPasswordProtected
        self.hasBodyText = hasBodyText
        self.hasFacingPages = hasFacingPages
        self.isModified = isModified
        self.templateName = templateName
    }
}

public struct DocumentDetail: Sendable, Equatable {
    public let summary: DocumentSummary
    /// The document's whole body, coerced to plain text. Pages' own dictionary types
    /// `body text` as rich text; this server only ever reads and writes the plain-text
    /// coercion of it, the same ceiling `note_get` documents for Notes' HTML — except
    /// here there is no "ask for the markup instead" option at all, because Pages'
    /// scripting dictionary exposes no string form of the formatting.
    public let bodyText: String
    /// One plain-text string per page, in document order. `nil` means "not requested",
    /// a different fact from "the document has one empty page".
    public let pageTexts: [String]?

    public init(summary: DocumentSummary, bodyText: String, pageTexts: [String]? = nil) {
        self.summary = summary
        self.bodyText = bodyText
        self.pageTexts = pageTexts
    }

    public var identifier: String { summary.identifier }
    public var name: String { summary.name }
}

public struct DocumentDraft: Sendable, Equatable {
    public var templateName: String?
    public var initialBodyText: String?

    public init(templateName: String? = nil, initialBodyText: String? = nil) {
        self.templateName = templateName
        self.initialBodyText = initialBodyText
    }
}

/// What `update_document` does with the text it is given.
///
/// Required on the tool, with no default — the same reasoning as Notes' `update_note`:
/// silently replacing a document's whole body by accident is this server's most
/// expensive possible mistake, and a default would make it the outcome of forgetting an
/// argument.
public enum BodyUpdateMode: String, Sendable, Equatable {
    case append
    case replace
}

/// A destination format for `export_document`. Every case here is a real entry in Pages'
/// own `export format` enumeration — nothing invented, nothing Pages cannot actually
/// produce.
public enum ExportFormat: String, Sendable, Equatable, CaseIterable {
    case pdf
    case word
    case epub
    case rtf
    case plainText = "plain_text"
    case pages09
}

public struct ExportReceipt: Sendable, Equatable {
    public let path: String
    public let format: ExportFormat

    public init(path: String, format: ExportFormat) {
        self.path = path
        self.format = format
    }
}
