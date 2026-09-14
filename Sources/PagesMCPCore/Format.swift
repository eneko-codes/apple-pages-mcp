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

    /// A document with no title of its own still needs something to print.
    static func displayName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(untitled)" : trimmed
    }

    // MARK: Containers

    public func documents(_ documents: [DocumentSummary]) -> String {
        guard !documents.isEmpty else {
            return "No documents are open in Pages. Use open_document or create_document."
        }
        let width = documents.map { Self.displayName($0.name).count }.max() ?? 0
        var lines = [
            "\(documents.count) document\(documents.count == 1 ? "" : "s") open in Pages:"
        ]
        for document in documents {
            var line = document.isPasswordProtected ? "🔒 " : "   "
            line += Self.pad(Self.displayName(document.name), to: width)
            line += "  \(document.pageCount) page" + (document.pageCount == 1 ? "" : "s")
            line += document.path == nil ? "  (never saved)" : ""
            line += document.isModified ? "  •unsaved changes" : ""
            lines.append(line + "  id=\(document.identifier)")
        }
        lines.append("")
        lines.append("🔒 marks a password-protected document: no tool here will touch it.")
        return lines.joined(separator: "\n")
    }

    // MARK: Documents

    /// `text` is already truncated by the caller, which is where the limit lives so the
    /// policy stays testable.
    public func detail(_ document: DocumentDetail, text: String, truncated: Bool) -> String {
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
            return output
        }

        output += "\n\n" + text
        if truncated {
            output += "\n\n[Cut at \(text.count) characters. Raise 'text_limit' to read more.]"
        }
        if let pageTexts = document.pageTexts {
            output += "\n\n--- by page ---\n"
            for (index, pageText) in pageTexts.enumerated() {
                output += "\n[page \(index + 1)]\n\(pageText)\n"
            }
        }
        return output
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

    public func status(_ state: PagesAvailability, binaryPath: String, configuration: Configuration)
        -> String
    {
        let headline: String
        switch state {
        case .ready: headline = "Pages: RUNNING, automation permitted."
        case .notInstalled: headline = "Pages: NOT INSTALLED."
        case .notRunning: headline = "Pages: NOT RUNNING."
        case .automationDenied: headline = "Pages automation: DENIED."
        case .consentNotGranted: headline = "Pages automation: not requested yet."
        }

        var text = headline + "\n\n"
        text += Self.block([
            ("binary", binaryPath),
            ("target", ScriptingBridgePageStore.bundleIdentifier),
            ("app display name", "\"Pages Creator Studio\" in System Settings and dialogs"),
            ("process", "pid \(ProcessInfo.processInfo.processIdentifier)"),
            ("body text limit", "\(configuration.bodyTextLimit) characters"),
        ])
        if state != .ready {
            text += "\n\n" + ToolError.availabilityMessage(state)
        }
        return text
    }
}
