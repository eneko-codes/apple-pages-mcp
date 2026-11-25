import Foundation

/// Plain-text rendering of every tool result.
public struct Format: Sendable {
    public init() {}

    // MARK: Helpers

    static func pad(_ text: String, to width: Int) -> String {
        let shortfall = width - text.count
        return shortfall > 0 ? text + String(repeating: " ", count: shortfall) : text
    }

    static func clip(_ text: String, to width: Int) -> String {
        guard text.count > width else { return text }
        return String(text.prefix(width - 1)) + "…"
    }

    static func block(_ rows: [(String, String?)]) -> String {
        let present = rows.compactMap { label, value -> (String, String)? in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return (label, value)
        }
        guard let width = present.map(\.0.count).max() else { return "" }
        let indent = String(repeating: " ", count: width + 3)
        return present.map { label, value in
            let wrapped = value.split(separator: "\n", omittingEmptySubsequences: false)
                .joined(separator: "\n" + indent)
            return "  \(pad(label, to: width)) \(wrapped)"
        }.joined(separator: "\n")
    }

    /// A document with no title of its own still needs something to print. A name is one
    /// line: a file name may hold a line break, and a row or a heading may not.
    static func displayName(_ name: String) -> String {
        let trimmed = name.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "(untitled)" : trimmed
    }

    // MARK: Containers

    /// `documents` is the page to show, already in order; `matching` counts every open
    /// document. The page's position in the whole is the caller's notice, not this text.
    public func documents(_ documents: [DocumentSummary], matching: Int) -> String {
        guard matching > 0 else {
            return "No documents are open in Pages. Use open_document or create_document."
        }
        let width = documents.map { Self.displayName($0.name).count }.max() ?? 0
        var lines = [
            "\(matching) document\(matching == 1 ? "" : "s") open in Pages, ordered by name, then id:"
        ]
        if documents.isEmpty { lines.append("   (nothing at this offset)") }
        for document in documents {
            var line = document.isPasswordProtected ? "🔒 " : "   "
            line += Self.pad(Self.displayName(document.name), to: width)
            line += "  \(document.pageCount) page" + (document.pageCount == 1 ? "" : "s")
            line += document.path == nil ? "  (never saved)" : ""
            line += document.isModified ? "  •unsaved changes" : ""
            lines.append(line + "  id=\(document.identifier)")
        }
        if documents.contains(where: \.isPasswordProtected) {
            lines.append("")
            lines.append("🔒 marks a password-protected document: no tool here will touch it.")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Documents

    /// The text of a run of pages as it is listed and windowed: each page under a heading
    /// with its number, `firstPage` being the number of the first one.
    static func pageListing(_ texts: [String], firstPage: Int) -> String {
        texts.enumerated().map { index, text in "[page \(firstPage + index)]\n\(text)" }
            .joined(separator: "\n\n")
    }

    /// One document: what Pages reports about it, then one window of text. That text is
    /// the body, or, when `firstPage` is given, the listing of `document.pageTexts`, whose
    /// first entry is page `firstPage`. `characterOffset` and `maxCharacters` window it,
    /// because it is the one part of the result with no natural bound.
    public func detail(
        _ document: DocumentDetail, firstPage: Int? = nil, characterOffset: Int,
        maxCharacters: Int, notices: [String]
    ) -> String {
        var notices = notices
        let summary = document.summary
        var output = Self.displayName(summary.name) + "\n"
        output += Self.block([
            ("path", summary.path ?? "(never saved)"),
            ("pages", "\(summary.pageCount)"),
            ("sections", "\(summary.sectionCount)"),
            ("tables", summary.tableCount > 0 ? "\(summary.tableCount)" : nil),
            ("images", summary.imageCount > 0 ? "\(summary.imageCount)" : nil),
            ("charts", summary.chartCount > 0 ? "\(summary.chartCount)" : nil),
            ("template", summary.templateName),
            ("facing pages", summary.hasFacingPages ? "yes" : nil),
            ("unsaved changes", summary.isModified ? "yes" : nil),
            ("locked", summary.isPasswordProtected ? "yes — password protected" : nil),
            ("id", summary.identifier),
        ])

        if summary.isPasswordProtected {
            // Returning empty text here would read as an empty document, which is a
            // different and much more misleading fact than "this is locked".
            output += """


                This document is password protected. This server never reads, writes or \
                exports a locked document's content — open it in Pages to read it there.
                """
            return ToolStandard.withNotices(notices, output)
        }

        let whole: String
        let label: String
        let empty: String
        var pageRange: String?
        if let firstPage, let pageTexts = document.pageTexts {
            whole = Self.pageListing(pageTexts, firstPage: firstPage)
            let lastPage = firstPage + pageTexts.count - 1
            pageRange = "first_page=\(firstPage) and last_page=\(lastPage)"
            switch pageTexts.count {
            case 0: label = "Pages"
            case 1: label = "Page \(firstPage)"
            default: label = "Pages \(firstPage)–\(lastPage)"
            }
            empty = "(this document has no pages)"
        } else {
            whole = document.bodyText
            label = "Body"
            empty = "(the body is empty)"
        }
        let window = ToolStandard.window(
            of: whole, characterOffset: characterOffset, maxCharacters: maxCharacters, label: label)
        if let position = window.notice { notices.append(position) }
        // The window's own sentence names only character_offset, and that alone would
        // return the next window of the body, not of these pages.
        if let pageRange, max(characterOffset, 0) + window.text.count < whole.count {
            notices.append("Keep \(pageRange) in that call.")
        }
        output += "\n\n" + (whole.isEmpty ? empty : window.text)
        return ToolStandard.withNotices(notices, output)
    }

    // MARK: Write receipts

    public func created(_ document: DocumentDetail) -> String {
        var output = "Created '\(Self.displayName(document.name))'.\n"
        output += Self.block([
            ("template", document.summary.templateName),
            ("path", document.summary.path ?? "(not yet saved)"),
            ("id", document.identifier),
        ])
        output += "\n\nPages may autosave this into iCloud Drive within seconds on its "
        output += "own schedule, whether or not save_document is ever called. If this "
        output += "document is disposable, delete the file when done — this server has "
        output += "no delete tool; use the filesystem server's trash tool instead."
        return output
    }

    public func opened(_ document: DocumentDetail) -> String {
        var output = "Opened '\(Self.displayName(document.name))'.\n"
        output += Self.block([
            ("path", document.summary.path),
            ("pages", "\(document.summary.pageCount)"),
            ("id", document.identifier),
        ])
        return output
    }

    /// Says how the document changed size, because that is the one number that shows an
    /// update did what was intended — or that it did not.
    public func updated(_ document: DocumentDetail, mode: BodyUpdateMode, previousLength: Int)
        -> String
    {
        let now = document.bodyText.count
        var output = "Updated '\(Self.displayName(document.name))' (\(mode.rawValue)).\n"
        output += Self.block([
            ("text length", "\(previousLength) → \(now) characters"),
            ("id", document.identifier),
        ])
        if mode == .replace {
            output += "\n\nThe previous body is gone; this server cannot bring it back."
        }
        return output
    }

    public func saved(_ document: DocumentDetail) -> String {
        var output = "Saved '\(Self.displayName(document.name))'.\n"
        output += Self.block([
            ("path", document.summary.path),
            ("id", document.identifier),
        ])
        return output
    }

    /// The receipt is the only record left of a document this server just closed, so it
    /// states plainly whether the changes made in this session survive.
    public func closed(_ document: DocumentDetail, saved: Bool) -> String {
        var output = "Closed '\(Self.displayName(document.name))'"
        output += saved ? ", saving changes.\n" : ", discarding any unsaved changes.\n"
        output += Self.block([
            ("path", document.summary.path ?? "(was never saved)"),
            ("id", document.identifier),
        ])
        return output
    }

    public func exported(_ receipt: ExportReceipt, from document: DocumentDetail) -> String {
        var output = "Exported '\(Self.displayName(document.name))'.\n"
        output += Self.block([
            ("format", receipt.format.rawValue),
            ("to", receipt.path),
        ])
        return output
    }

    // MARK: Status

    public func status(_ state: PagesAvailability, binaryPath: String, deadline: Duration) -> String {
        let headline: String
        switch state {
        case .ready: headline = "Pages: RUNNING, automation permitted."
        case .notInstalled: headline = "Pages: NOT INSTALLED."
        case .notRunning: headline = "Pages: NOT RUNNING."
        case .automationDenied: headline = "Pages automation: DENIED."
        case .consentNotGranted: headline = "Pages automation: not requested yet."
        }

        let window = ToolCatalog.maxCharactersRange
        let documents = ToolCatalog.documentLimitRange
        var text = headline + "\n\n"
        text += Self.block([
            ("binary", binaryPath),
            ("target", ScriptingBridgePageStore.bundleIdentifier),
            ("app display name", "\"Pages Creator Studio\" in System Settings and dialogs"),
            ("process", "pid \(ProcessInfo.processInfo.processIdentifier)"),
            (
                "document_get window",
                "\(ToolCatalog.defaultMaxCharacters) characters by default, up to \(window.upperBound)"
            ),
            (
                "documents_list page",
                "\(ToolCatalog.defaultDocumentLimit) documents by default, up to \(documents.upperBound)"
            ),
            ("longest result", "\(ToolStandard.longestResult) characters"),
            ("call deadline", "\(deadline.components.seconds) seconds"),
        ])
        if state != .ready {
            text += "\n\n" + ToolError.availabilityMessage(state)
        }
        return text
    }
}
