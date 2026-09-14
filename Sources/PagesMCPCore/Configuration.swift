import Foundation

/// Numeric limits, fixed to sensible defaults. Pages has no scan ceiling the way Notes
/// does — there is nothing to walk, only the documents already open — so the one real
/// knob is how much of a document's body text `document_get` hands back by default.
///
/// Parsing is hand-rolled rather than pulling in an argument-parsing package — the whole
/// surface is one number, and every dependency in this repo has to earn its place.
public struct Configuration: Sendable, Equatable {
    /// Default truncation for the text `document_get` returns. The tool's own
    /// `text_limit` still wins. Higher than Notes' default: a document routinely runs to
    /// many pages, where a note rarely does.
    public var bodyTextLimit: Int = 20_000

    public init() {}

    public static let bodyTextLimitRange = 500...500_000

    /// True when an argument is an unsubstituted manifest placeholder.
    ///
    /// Claude Desktop leaves `${user_config.key}` untouched when the person left that
    /// setting empty, so the literal text arrives as an argument. Kept for whichever
    /// numeric flag below is actually passed a value.
    static func isPlaceholder(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("${") && trimmed.hasSuffix("}")
    }

    /// Unknown flags are ignored rather than fatal. A server that will not launch is much
    /// harder to diagnose than one running on a default.
    public static func parse(_ arguments: [String]) -> Configuration {
        var configuration = Configuration()
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            let value = index + 1 < arguments.count ? arguments[index + 1] : nil

            func clamped(_ range: ClosedRange<Int>) -> Int? {
                guard let value, !isPlaceholder(value), let number = Int(value) else {
                    return nil
                }
                return min(max(number, range.lowerBound), range.upperBound)
            }

            switch flag {
            case "--body-text-limit":
                if let number = clamped(bodyTextLimitRange) { configuration.bodyTextLimit = number }
                index += 2

            default:
                index += 1
            }
        }
        return configuration
    }
}
