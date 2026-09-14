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
    case storeFailure(String)

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
                No open document has the id '\(identifier)'.

                Pages only knows about documents open right now — there is no library to \
                search the way Notes has folders. Call documents_list to see what is \
                actually open, or open_document if the file you mean is not open yet.
                """

        case .templateNotFound(let name, let available):
            let list = available.isEmpty ? "(none found)" : available.joined(separator: ", ")
            return """
                No template '\(name)'.

                Templates installed: \(list)

                Matching ignores case but nothing else.
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
