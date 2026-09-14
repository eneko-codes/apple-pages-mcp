import AppKit
import Foundation
import PagesBridge

/// `PageStore` backed by the real Pages app, driven through Apple events.
///
/// Nothing here reads a document's file directly: every read is Pages doing the work and
/// handing back the result, which is why Pages has to be running and why every write
/// happens against whatever the app currently has open.
///
/// The Apple events themselves live in the `PagesBridge` Objective-C target; see its
/// header for why they cannot live in Swift, and for the one thing Pages needed that
/// Notes did not — `body text` is Pages' own "rich text" class, not a plain-text
/// property, so reading it needs an explicit `as text` coercion that the bridge performs
/// with `sendEvent:id:parameters:`. What stays here is the mapping between Pages' loose
/// dictionaries and this server's value types, plus the decisions the bridge deliberately
/// does not make: whether a document is too protected to touch, and what counts as
/// "would overwrite".
public struct ScriptingBridgePageStore: PageStore {
    /// Pages' real `CFBundleIdentifier`. The App Store now lists the app as "Pages
    /// Creator Studio" — a display-name change, not a different app — but the bundle
    /// identifier this server, TCC and `NSRunningApplication` all key on is unchanged.
    public static let bundleIdentifier = "com.apple.Pages"

    public init() {}

    // MARK: Availability

    public func availability() -> PagesAvailability {
        guard
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier) != nil
        else { return .notInstalled }

        // "Not running" is checked before consent, and the order matters. Consent is
        // reported as pending until the first Apple event, and that event would launch
        // Pages — starting an app on the owner's behalf is exactly the side effect this
        // server refuses to have. Answering `.notRunning` first keeps the refusal ahead
        // of the launch.
        guard PagesBridge.isPagesRunning else { return .notRunning }

        switch Self.automationPermission() {
        case OSStatus(errAEEventNotPermitted): return .automationDenied
        case OSStatus(errAEEventWouldRequireUserConsent): return .consentNotGranted
        case OSStatus(procNotFound): return .notRunning
        default: return .ready
        }
    }

    /// Asks TCC whether this process may drive Pages, **without sending a real event and
    /// without raising a dialog** (`askUserIfNeeded: false`). That is what lets
    /// `pages_status` be honest about permissions while touching no document at all.
    static func automationPermission() -> OSStatus {
        var target = AEAddressDesc()
        let identifier = Data(bundleIdentifier.utf8)
        let created = identifier.withUnsafeBytes { bytes in
            AECreateDesc(typeApplicationBundleID, bytes.baseAddress, bytes.count, &target)
        }
        guard created == noErr else { return OSStatus(created) }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false)
    }

    private func guardAvailability() throws {
        let state = availability()
        guard !state.blocksCalls else { throw ToolError.notAvailable(state) }
    }

    /// The bridge reports failures as `NSError`; the tool layer speaks `ToolError`.
    private func storeFailure(_ error: Error) -> ToolError {
        .storeFailure(error.localizedDescription)
    }

    private func isDocumentMissing(_ error: Error) -> Bool {
        let failure = error as NSError
        return failure.domain == PagesBridgeErrorDomain
            && failure.code == PagesBridgeError.documentNotFound.rawValue
    }

    private func isNeverSaved(_ error: Error) -> Bool {
        let failure = error as NSError
        return failure.domain == PagesBridgeErrorDomain
            && failure.code == PagesBridgeError.neverSaved.rawValue
    }

    // MARK: Mapping

    private func summary(from raw: [String: Any]) -> DocumentSummary {
        DocumentSummary(
            identifier: raw["id"] as? String ?? "",
            name: raw["name"] as? String ?? "",
            path: raw["path"] as? String,
            pageCount: raw["pageCount"] as? Int ?? 0,
            sectionCount: raw["sectionCount"] as? Int ?? 0,
            tableCount: raw["tableCount"] as? Int ?? 0,
            imageCount: raw["imageCount"] as? Int ?? 0,
            chartCount: raw["chartCount"] as? Int ?? 0,
            isPasswordProtected: raw["passwordProtected"] as? Bool ?? false,
            hasBodyText: raw["hasBodyText"] as? Bool ?? false,
            hasFacingPages: raw["facingPages"] as? Bool ?? false,
            isModified: raw["modified"] as? Bool ?? false,
            templateName: raw["templateName"] as? String)
    }

    private func detail(from raw: [String: Any]) -> DocumentDetail {
        DocumentDetail(
            summary: summary(from: raw), bodyText: raw["bodyText"] as? String ?? "",
            pageTexts: raw["pageTexts"] as? [String])
    }

    // MARK: Reads

    public func documents() async throws -> [DocumentSummary] {
        try guardAvailability()
        let raw: [[String: Any]]
        do { raw = try PagesBridge.openDocuments() } catch { throw storeFailure(error) }
        return raw.map(summary(from:))
    }

    public func fetch(identifier: String, includePageTexts: Bool) async throws -> DocumentDetail? {
        try guardAvailability()
        let raw: [String: Any]
        do {
            raw = try PagesBridge.document(
                withIdentifier: identifier, includePageTexts: includePageTexts)
        } catch where isDocumentMissing(error) {
            // Not a failure: the owner can close a document between two calls, which is
            // ordinary. The tool layer turns nil into its own "check documents_list".
            return nil
        } catch {
            throw storeFailure(error)
        }
        return detail(from: raw)
    }

    public func installedTemplateNames() async throws -> [String] {
        try guardAvailability()
        do { return try PagesBridge.installedTemplateNames() } catch { throw storeFailure(error) }
    }

    // MARK: Writes

    /// Reads a document back after a write, so a receipt describes what Pages ended up
    /// with rather than what was asked for.
    private func reread(_ identifier: String) async throws -> DocumentDetail {
        guard let document = try await fetch(identifier: identifier, includePageTexts: false)
        else { throw ToolError.notFound(identifier: identifier) }
        return document
    }

    public func create(_ draft: DocumentDraft) async throws -> DocumentDetail {
        try guardAvailability()
        let raw: [String: Any]
        do {
            raw = try PagesBridge.createDocument(
                withTemplateName: draft.templateName, initialBodyText: draft.initialBodyText)
        } catch { throw storeFailure(error) }
        return detail(from: raw)
    }

    public func open(path: String) async throws -> DocumentDetail {
        try guardAvailability()
        let raw: [String: Any]
        do { raw = try PagesBridge.openDocument(atPath: path) } catch { throw storeFailure(error) }
        return detail(from: raw)
    }

    public func updateBody(identifier: String, text: String) async throws -> DocumentDetail {
        try guardAvailability()
        let raw: [String: Any]
        do {
            raw = try PagesBridge.setBodyText(text, ofDocumentWithIdentifier: identifier)
        } catch where isDocumentMissing(error) {
            throw ToolError.notFound(identifier: identifier)
        } catch {
            throw storeFailure(error)
        }
        return detail(from: raw)
    }

    public func save(identifier: String, path: String?) async throws -> DocumentDetail {
        try guardAvailability()
        let existing = try await reread(identifier)
        let raw: [String: Any]
        do {
            raw = try PagesBridge.saveDocument(withIdentifier: identifier, toPath: path)
        } catch where isDocumentMissing(error) {
            throw ToolError.notFound(identifier: identifier)
        } catch where isNeverSaved(error) {
            throw ToolError.neverSaved(name: existing.name, action: "there is nowhere to save it")
        } catch {
            throw storeFailure(error)
        }
        return detail(from: raw)
    }

    public func close(identifier: String, saving: Bool) async throws -> DocumentDetail {
        try guardAvailability()
        let existing = try await reread(identifier)
        let raw: [String: Any]
        do {
            raw = try PagesBridge.closeDocument(withIdentifier: identifier, saving: saving)
        } catch where isDocumentMissing(error) {
            throw ToolError.notFound(identifier: identifier)
        } catch where isNeverSaved(error) {
            throw ToolError.neverSaved(
                name: existing.name,
                action: "closing with saving=true would make Pages show its own save panel")
        } catch {
            throw storeFailure(error)
        }
        return detail(from: raw)
    }

    public func export(identifier: String, toPath: String, format: ExportFormat) async throws
        -> ExportReceipt
    {
        try guardAvailability()
        do {
            let raw = try PagesBridge.exportDocument(
                withIdentifier: identifier, toPath: toPath, format: format.rawValue)
            return ExportReceipt(path: raw["path"] as? String ?? toPath, format: format)
        } catch where isDocumentMissing(error) {
            throw ToolError.notFound(identifier: identifier)
        } catch {
            throw storeFailure(error)
        }
    }
}
