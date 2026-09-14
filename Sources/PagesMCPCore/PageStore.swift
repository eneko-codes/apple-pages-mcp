import Foundation

/// Whether Pages can be driven at all, and if not, why.
///
/// There is no `authorizationStatus` for Apple events the way there is for Contacts or
/// EventKit, so this collapses several distinct causes — Pages missing, Pages not
/// running, consent refused — into one value the tools can act on.
public enum PagesAvailability: Sendable, Equatable {
    case ready
    case notInstalled
    /// Pages is installed but not launched. This server does not launch it: starting an
    /// app on someone's behalf is a side effect they did not ask for.
    case notRunning
    case automationDenied
    /// macOS has not asked yet. The first real Apple event raises the dialog.
    case consentNotGranted

    /// Whether a tool call must be refused outright.
    ///
    /// `.consentNotGranted` deliberately does **not** block, which is why "may a call
    /// proceed" is a different question from "is Pages ready". macOS only shows the
    /// Automation dialog when a real Apple event is sent, so refusing here would mean the
    /// dialog never appears and the permission could never be granted at all. If consent
    /// is then refused, the event fails and the error path reports it.
    public var blocksCalls: Bool {
        switch self {
        case .ready, .consentNotGranted: return false
        case .notInstalled, .notRunning, .automationDenied: return true
        }
    }
}

/// The seam between the tool layer and Pages.
///
/// Nothing above this protocol sends an Apple event, which is what lets the tests drive
/// every branch against an in-memory double — with Pages closed and no document touched.
public protocol PageStore: Sendable {
    func availability() -> PagesAvailability

    /// Every document currently open in Pages. Unlike Notes' folders, this is the whole
    /// of what Pages can be asked about: it has no library of documents that are not
    /// open, so there is nothing to search — only what is already on screen.
    func documents() async throws -> [DocumentSummary]

    /// `includePageTexts` is opt-in: it is one Apple event per page on top of the one for
    /// the whole body, and most callers only want the body.
    func fetch(identifier: String, includePageTexts: Bool) async throws -> DocumentDetail?

    /// Every installed template's display name, for resolving `create`'s `templateName`
    /// and for naming what actually exists when a caller asks for one that doesn't.
    func installedTemplateNames() async throws -> [String]

    func create(_ draft: DocumentDraft) async throws -> DocumentDetail

    /// Opens the file at `path`. Refuses a password-protected file before sending the
    /// Apple event: Pages would otherwise show its own password prompt and block waiting
    /// for someone at the keyboard, and there is no parameter to answer it with even if
    /// this server wanted to.
    func open(path: String) async throws -> DocumentDetail

    /// Replaces the document's whole body. Appending is composed above this seam, where
    /// the tests can reach it.
    func updateBody(identifier: String, text: String) async throws -> DocumentDetail

    /// Replaces the document's whole body with `paragraphs`, one paragraph per entry, each
    /// styled according to `ParagraphStyle.preset`. Replace-only — appending styled
    /// paragraphs onto an existing rich-text body is not implemented; splicing new,
    /// separately-styled paragraphs into place among ones already there needs paragraph
    /// index bookkeeping this server does not currently do, and getting that wrong risks
    /// restyling text that was never meant to change.
    func replaceStyledParagraphs(identifier: String, paragraphs: [StyledParagraph]) async throws
        -> DocumentDetail

    /// Saves to `path`, or to the document's existing path when `path` is nil.
    func save(identifier: String, path: String?) async throws -> DocumentDetail

    /// Closes the document. Returns the document's record as it was immediately before
    /// closing, so the caller can describe what disappeared. Refuses `saving: true` on a
    /// document with no path — see `PageStore.open` for why a blocking dialog is refused
    /// rather than risked.
    func close(identifier: String, saving: Bool) async throws -> DocumentDetail

    func export(identifier: String, toPath: String, format: ExportFormat) async throws
        -> ExportReceipt
}
