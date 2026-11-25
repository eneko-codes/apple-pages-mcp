import Foundation

public enum ToolError: Error, Equatable {
    case notAvailable(PagesAvailability)
    case missingArgument(String)
    case badArgument(name: String, reason: String)
    case notFound(identifier: String)
    case templateNotFound(name: String, available: [String])
    case documentPasswordProtected(name: String, action: String)
    case neverSaved(name: String, action: String)
    case confirmationRequired(action: String)
    case unknownTool(String)
    case timedOut(seconds: Int)
    case storeFailure(String)

    /// How many template names an error lists. A Mac has about a hundred installed, and an
    /// error is no place for all of them.
    static let candidateCount = 8

    /// `available` with the names that share the most words with `name` first, then in
    /// alphabetical order, so that the few an error shows are the likeliest ones meant.
    static func closest(to name: String, among available: [String]) -> [String] {
        let words = Set(
            name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        func shared(_ candidate: String) -> Int {
            let folded = candidate.lowercased()
            return words.filter { folded.contains($0) }.count
        }
        return available.sorted { first, second in
            let (firstShared, secondShared) = (shared(first), shared(second))
            if firstShared != secondShared { return firstShared > secondShared }
            let order = first.localizedCaseInsensitiveCompare(second)
            return order == .orderedSame ? first < second : order == .orderedAscending
        }
    }

    public var message: String {
        switch self {
        case .notAvailable(let state):
            return Self.availabilityMessage(state)

        case .missingArgument(let name):
            return "Missing required argument '\(name)'."

        case .badArgument(let name, let reason):
            return "Argument '\(name)' is not valid: \(reason)"

        case .notFound(let identifier):
            return """
                No open document has the id '\(ToolStandard.echo(identifier))'.

                Pages only knows about documents open right now — there is no library to \
                search the way Notes has folders. Call documents_list to see what is \
                actually open, or open_document if the file you mean is not open yet.

                A document's id can change on its own while it stays open the whole time \
                — observed live during this server's own testing, right after a save. If \
                you held on to an id from an earlier documents_list, call it again rather \
                than assuming the document closed.
                """

        case .templateNotFound(let name, let available):
            let shown = Self.closest(to: name, among: available).prefix(Self.candidateCount)
            let others = available.count - shown.count
            let list: String
            if available.isEmpty {
                list = "Pages reported no installed template."
            } else if others == 0 {
                list = "Templates installed: \(shown.joined(separator: ", "))."
            } else {
                list =
                    "The closest \(shown.count) of the \(available.count) installed: "
                    + "\(shown.joined(separator: ", ")), and \(others) others."
            }
            return """
                No template '\(ToolStandard.echo(name))'.

                \(list)

                Matching ignores case but nothing else. The template chooser in Pages \
                (File > New) shows every name; leave 'template' out for a blank document.
                """

        case .documentPasswordProtected(let name, let action):
            return """
                '\(name)' is a password-protected document, so \(action) is refused.

                This server never opens, reads, writes or exports a document Pages \
                reports as password protected, and never accepts a password as an \
                argument — the same policy apple-pdf-mcp uses for encrypted PDFs.

                Open it yourself in Pages, unlock it there, and make the change in the \
                app if it really has to happen through this document.
                """

        case .neverSaved(let name, let action):
            return """
                '\(name)' has never been saved, so \(action).

                Pass a 'path' to say where it should be saved.
                """

        case .confirmationRequired(let action):
            return """
                \(action) requires confirm=true.

                This would overwrite a file on disk, and this server cannot undo that. \
                Call again with confirm=true only if you really mean it.
                """

        case .unknownTool(let name):
            return "'\(ToolStandard.echo(name))' is not a tool of this server."

        case .timedOut(let seconds):
            return """
                The call did not finish within \(seconds) seconds and was abandoned.

                Pages may be busy, or showing a dialog that waits for someone at the \
                keyboard. An Apple event already sent cannot be recalled, so a create, \
                update, save, close or export may still take effect: check with \
                documents_list or document_get before repeating one.

                A read changed nothing. document_get does less work with a narrower \
                first_page to last_page range, or with neither, which reads the body in \
                one event. documents_list reads every open document whatever its limit, \
                so it cannot be narrowed, only tried again.
                """

        case .storeFailure(let detail):
            return "Pages returned an error: \(detail)"
        }
    }

    static func availabilityMessage(_ state: PagesAvailability) -> String {
        switch state {
        case .ready:
            return "Pages is running and automation is permitted."

        case .notInstalled:
            return """
                Pages was not found on this Mac.

                This server drives the Pages app through Apple events; without it there \
                is nothing to talk to.
                """

        case .notRunning:
            return """
                Pages is not running.

                This server does not launch it: starting an app on your behalf is a side \
                effect you did not ask for. Open Pages and try again.
                """

        case .consentNotGranted:
            return """
                Automation permission for Pages has not been granted yet.

                macOS raises the dialog the first time this server sends an Apple event. \
                Restart Claude Desktop, call a Pages tool, and approve \
                "apple-pages-mcp wants to control Pages" (the app itself may show as \
                "Pages Creator Studio" in that dialog and in System Settings).
                """

        case .automationDenied:
            return """
                Automation permission for Pages is denied.

                Grant it in:
                  System Settings → Privacy & Security → Automation → apple-pages-mcp → enable Pages
                  (Spanish UI: Ajustes del Sistema → Privacidad y seguridad → Automatización)

                Then restart Claude Desktop. The grant is per target app: allowing Pages \
                says nothing about any other app.
                """
        }
    }
}
