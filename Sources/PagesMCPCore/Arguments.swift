import Foundation

/// Typed access to a `tools/call` argument bag.
///
/// A class, not a struct, so that reading a number can also record that it was moved into
/// its range without every reader having to be `mutating`. One instance serves one call and
/// never leaves it. The tool hands `notices` to `Format`, which puts them before the data.
public final class Arguments {
    private let values: [String: Value]

    /// One sentence for each number that was moved into its range, in the order read.
    public private(set) var notices: [String] = []

    public init(_ values: [String: Value]?) {
        self.values = values ?? [:]
    }

    /// `nil` when the argument is absent or null, which mean the same: not given.
    private func given(_ name: String) -> Value? {
        guard let raw = values[name], !raw.isNull else { return nil }
        return raw
    }

    /// The text of an argument exactly as it was written, or `nil` when it was not given.
    private func text(_ name: String) throws -> String? {
        guard let raw = given(name) else { return nil }
        guard let text = raw.stringValue else {
            throw ToolError.badArgument(name: name, reason: "text was expected")
        }
        return text
    }

    // MARK: Text

    public func requiredString(_ name: String) throws -> String {
        guard let raw = try text(name) else { throw ToolError.missingArgument(name) }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolError.badArgument(name: name, reason: "it is empty")
        }
        return trimmed
    }

    public func optionalString(_ name: String) throws -> String? {
        guard let raw = try text(name) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `nil` when absent; otherwise kept exactly as written. Unlike every other text
    /// argument a body is never trimmed: leading whitespace is part of what the caller
    /// composed, and text that appends onto an existing document may legitimately begin
    /// with a line break. An empty string is treated the same as absent, since
    /// `create_document`/`update_document` still need to tell "no body given" apart from
    /// "an empty one", which is the caller's job once this returns nil.
    public func optionalBody(_ name: String) throws -> String? {
        guard let raw = try text(name), !raw.isEmpty else { return nil }
        return raw
    }

    // MARK: Flags and numbers

    public func bool(_ name: String, default fallback: Bool = false) throws -> Bool {
        guard let raw = given(name) else { return fallback }
        guard let flag = raw.boolValue else {
            throw ToolError.badArgument(name: name, reason: "true or false was expected")
        }
        return flag
    }

    /// A whole number as it was sent, or `nil` when it was not given. For a number whose
    /// range is only known once the document has been read: the tool moves it into that
    /// range itself, with `ToolStandard.clamp`.
    public func wholeNumber(_ name: String) throws -> Int? {
        guard let raw = given(name) else { return nil }
        guard let number = raw.intValue else {
            throw ToolError.badArgument(name: name, reason: "a whole number was expected")
        }
        return number
    }

    /// A quantity: a size, a count, an offset. Outside its range it is moved to the nearest
    /// allowed value, and `notices` gains the sentence that says which value was used.
    public func int(_ name: String, default fallback: Int, in range: ClosedRange<Int>) throws
        -> Int
    {
        guard let number = try wholeNumber(name) else { return fallback }
        return ToolStandard.clamp(number, to: range, argument: name, notices: &notices)
    }

    /// The `limit` and `offset` of a listing, read the same way by every tool that pages.
    public func page(defaultLimit: Int, limits: ClosedRange<Int>) throws -> (limit: Int, offset: Int) {
        (
            try int("limit", default: defaultLimit, in: limits),
            try int("offset", default: 0, in: ToolCatalog.offsetRange)
        )
    }

    /// The `character_offset` and `max_characters` of a window on one long text.
    public func window() throws -> (characterOffset: Int, maxCharacters: Int) {
        (
            try int("character_offset", default: 0, in: ToolCatalog.offsetRange),
            try int(
                "max_characters", default: ToolCatalog.defaultMaxCharacters,
                in: ToolCatalog.maxCharactersRange)
        )
    }

    // MARK: Enumerations

    /// Required and with no default: see `BodyUpdateMode`.
    public func updateMode(_ name: String) throws -> BodyUpdateMode {
        let raw = try requiredString(name)
        guard let mode = BodyUpdateMode(rawValue: raw.lowercased()) else {
            throw ToolError.badArgument(
                name: name,
                reason: "expected \"append\" or \"replace\", got \"\(ToolStandard.echo(raw))\". "
                    + "\"replace\" discards the document's current body.")
        }
        return mode
    }

    public func exportFormat(_ name: String) throws -> ExportFormat {
        let raw = try requiredString(name)
        guard let format = ExportFormat(rawValue: raw.lowercased()) else {
            let options = ExportFormat.allCases.map(\.rawValue).joined(separator: ", ")
            throw ToolError.badArgument(
                name: name, reason: "expected one of \(options), got \"\(ToolStandard.echo(raw))\"")
        }
        return format
    }

    // MARK: Structured paragraphs

    /// `nil` when the argument is absent. An explicit empty array is rejected, the same as
    /// an empty `body` string: a document with no content is indistinguishable from a
    /// mistake.
    ///
    /// A paragraph's `text` may not contain `\n` — Pages would split it into more
    /// paragraphs than this server told it to style, and every style after the split
    /// would land one paragraph too early. One `StyledParagraph` is one Pages paragraph,
    /// always.
    public func optionalParagraphs(_ name: String) throws -> [StyledParagraph]? {
        guard let raw = given(name) else { return nil }
        guard let entries = raw.arrayValue else {
            throw ToolError.badArgument(name: name, reason: "an array was expected")
        }
        guard !entries.isEmpty else {
            throw ToolError.badArgument(
                name: name,
                reason: "it is empty. A document with no paragraphs cannot be told apart "
                    + "from a mistake.")
        }

        let options = ParagraphStyle.allCases.map(\.rawValue).joined(separator: ", ")
        return try entries.enumerated().map { index, entry in
            guard let object = entry.objectValue else {
                throw ToolError.badArgument(
                    name: name, reason: "entry \(index) is not an object")
            }
            guard let text = object["text"]?.stringValue, !text.isEmpty else {
                throw ToolError.badArgument(
                    name: name, reason: "entry \(index) is missing non-empty 'text'")
            }
            guard !text.contains("\n") else {
                throw ToolError.badArgument(
                    name: name,
                    reason: "entry \(index)'s text contains a newline. Each array entry is "
                        + "one Pages paragraph — split multi-line content into separate "
                        + "entries instead.")
            }
            // A style of the wrong type is refused rather than read as "body": the caller
            // asked for a look, and silently giving another one hides the mistake.
            guard let styleValue = object["style"], !styleValue.isNull else {
                return StyledParagraph(text: text, style: .body)
            }
            guard let styleName = styleValue.stringValue else {
                throw ToolError.badArgument(
                    name: name,
                    reason: "entry \(index)'s style is not text, expected one of \(options)")
            }
            guard let style = ParagraphStyle(rawValue: styleName) else {
                throw ToolError.badArgument(
                    name: name,
                    reason: "entry \(index) has style \"\(ToolStandard.echo(styleName))\", "
                        + "expected one of \(options)")
            }
            return StyledParagraph(text: text, style: style)
        }
    }
}
