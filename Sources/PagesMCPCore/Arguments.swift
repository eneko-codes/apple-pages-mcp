import Foundation
import MCP

/// Typed access to a `tools/call` argument bag.
public struct Arguments {
    private let values: [String: Value]

    public init(_ values: [String: Value]?) {
        self.values = values ?? [:]
    }

    // MARK: Scalars

    public func requiredString(_ name: String) throws -> String {
        guard let raw = values[name]?.stringValue else { throw ToolError.missingArgument(name) }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolError.badArgument(name: name, reason: "it is empty")
        }
        return trimmed
    }

    /// A document's body text, kept exactly as it was written.
    ///
    /// Unlike every other string argument this one is not trimmed: leading whitespace is
    /// part of what the caller composed, and text that appends onto an existing document
    /// may legitimately begin with a line break.
    public func requiredBody(_ name: String) throws -> String {
        guard let raw = values[name]?.stringValue else { throw ToolError.missingArgument(name) }
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError.badArgument(
                name: name,
                reason: "it is empty. A document with no content cannot be told apart "
                    + "from a mistake, and replacing one with nothing is the mistake this "
                    + "server refuses hardest.")
        }
        return raw
    }

    public func optionalString(_ name: String) -> String? {
        guard let text = values[name]?.stringValue else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func bool(_ name: String, default fallback: Bool = false) -> Bool {
        values[name]?.boolValue ?? fallback
    }

    /// Clamps rather than rejects: a model asking for more than the ceiling means "as much
    /// as you will give me".
    public func int(_ name: String, default fallback: Int, in range: ClosedRange<Int>) throws
        -> Int
    {
        guard let raw = values[name] else { return fallback }
        guard let number = raw.intValue else {
            throw ToolError.badArgument(name: name, reason: "an integer was expected")
        }
        return Swift.min(Swift.max(number, range.lowerBound), range.upperBound)
    }

    // MARK: Enumerations

    /// Required and with no default: see `BodyUpdateMode`.
    public func updateMode(_ name: String) throws -> BodyUpdateMode {
        let raw = try requiredString(name)
        guard let mode = BodyUpdateMode(rawValue: raw.lowercased()) else {
            throw ToolError.badArgument(
                name: name,
                reason: "expected \"append\" or \"replace\", got \"\(raw)\". "
                    + "\"replace\" discards the document's current body.")
        }
        return mode
    }

    public func exportFormat(_ name: String) throws -> ExportFormat {
        let raw = try requiredString(name)
        guard let format = ExportFormat(rawValue: raw.lowercased()) else {
            let options = ExportFormat.allCases.map(\.rawValue).joined(separator: ", ")
            throw ToolError.badArgument(
                name: name, reason: "expected one of \(options), got \"\(raw)\"")
        }
        return format
    }
}
