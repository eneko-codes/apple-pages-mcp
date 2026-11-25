import Foundation
import Testing

@testable import PagesMCPCore

/// The edges of the tool standard for this server's own tools: each bound and one past it,
/// the text of each notice, pages and windows that chain, the longest result, and the texts
/// the model reads. Every document, name, path and template in here is invented.
@Suite("Bounds")
struct BoundsTests {

    // MARK: Invented documents, as many as a test asks for

    private static func padded(_ index: Int) -> String {
        String(format: "%04d", index)
    }

    /// A name about as long as an ordinary document's gets.
    private static func ordinaryName(_ index: Int) -> String {
        "Invented quarterly report, second draft \(padded(index)).pages"
    }

    /// As long as an identifier Pages hands out.
    private static func identifier(_ index: Int) -> String {
        "0F2B6C1A-7D3E-4A5B-9C8D-00000000\(padded(index))"
    }

    /// `count` open documents, each never saved and so with unsaved changes: the widest row
    /// the listing prints. The store hands them over in no order.
    private static func open(_ count: Int, name: (Int) -> String = ordinaryName) -> FakePageStore {
        let store = FakePageStore()
        for index in 0..<count {
            store.documentsValue[identifier(index)] = Fixtures.document(
                id: identifier(index), name: name(index), text: "invented")
        }
        return store
    }

    /// The documents of `count` that `text` shows, in the order the tool lists them.
    private static func rows(in text: String, of count: Int) -> [Int] {
        (0..<count).filter { text.contains("\(padded($0)).pages") }
    }

    private func list(_ count: Int, _ arguments: [String: Value] = [:]) async -> ToolResult {
        await call(ToolCatalog.documentsListName, arguments, store: Self.open(count))
    }

    // MARK: Pages of documents

    @Test("A call with no optional argument returns one default page, announced before the data")
    func defaultPage() async {
        let size = ToolCatalog.defaultDocumentLimit
        let result = await list(size + 5)
        #expect(!result.isError)
        #expect(
            result.text.hasPrefix(
                "Showing 1–\(size) of \(size + 5) documents. Pass offset=\(size) for the next page.\n\n"))
        #expect(Self.rows(in: result.text, of: size + 5) == Array(0..<size))
        #expect(result.text.utf16.count <= ToolStandard.usualPage)
    }

    @Test("A result that holds every document from the start carries no notice")
    func wholeListingHasNoNotice() async {
        let size = ToolCatalog.defaultDocumentLimit
        let result = await list(size)
        #expect(Self.rows(in: result.text, of: size).count == size)
        #expect(result.text.hasPrefix("\(size) documents open in Pages, ordered by name, then id:\n"))
        #expect(!result.text.contains("Showing"))
        #expect(!result.text.contains("is outside"))
    }

    @Test("limit at its maximum is used as asked, and a full page of the widest rows fits a result")
    func limitAtItsMaximum() async {
        let maximum = ToolCatalog.documentLimitRange.upperBound
        let result = await list(maximum + 10, ["limit": .int(maximum)])
        #expect(!result.text.contains("is outside"))
        #expect(
            result.text.hasPrefix(
                "Showing 1–\(maximum) of \(maximum + 10) documents. Pass offset=\(maximum) for the next page.\n\n"))
        #expect(Self.rows(in: result.text, of: maximum + 10) == Array(0..<maximum))
        #expect(result.text.utf16.count <= ToolStandard.longestResult)
    }

    @Test("A full page of names as long as a file name may be still fits, unshrunk")
    func longestNamesFit() async {
        let maximum = ToolCatalog.documentLimitRange.upperBound
        let store = Self.open(maximum + 1) { index in
            let name = "invented-\(Self.padded(index)).pages"
            return String(repeating: "n", count: 255 - name.count) + name
        }
        let result = await call(ToolCatalog.documentsListName, ["limit": .int(maximum)], store: store)
        #expect(result.text.hasPrefix("Showing 1–\(maximum) of \(maximum + 1) documents."))
        #expect(result.text.utf16.count <= ToolStandard.longestResult)
    }

    @Test("limit one past either end is moved to the nearest value, and the result says which")
    func limitPastItsRange() async {
        let maximum = ToolCatalog.documentLimitRange.upperBound
        let total = maximum + 10

        let over = await list(total, ["limit": .int(maximum + 1)])
        #expect(
            over.text.hasPrefix(
                """
                limit=\(maximum + 1) is outside 1–\(maximum); \(maximum) was used.
                Showing 1–\(maximum) of \(total) documents. Pass offset=\(maximum) for the next page.


                """))
        #expect(Self.rows(in: over.text, of: total) == Array(0..<maximum))

        let under = await list(total, ["limit": .int(0)])
        #expect(under.text.hasPrefix("limit=0 is outside 1–\(maximum); 1 was used.\nShowing 1–1 of \(total) "))
        #expect(Self.rows(in: under.text, of: total) == [0])
    }

    @Test("Each page starts where the last one ended, and the last says that is all")
    func pagesChain() async {
        let first = await list(7, ["limit": .int(3)])
        #expect(first.text.hasPrefix("Showing 1–3 of 7 documents. Pass offset=3 for the next page.\n\n"))
        #expect(Self.rows(in: first.text, of: 7) == [0, 1, 2])

        let second = await list(7, ["limit": .int(3), "offset": .int(3)])
        #expect(second.text.hasPrefix("Showing 4–6 of 7 documents. Pass offset=6 for the next page.\n\n"))
        #expect(Self.rows(in: second.text, of: 7) == [3, 4, 5])

        let last = await list(7, ["limit": .int(3), "offset": .int(6)])
        #expect(last.text.hasPrefix("Showing 7–7 of 7 documents. That is all.\n\n"))
        #expect(Self.rows(in: last.text, of: 7) == [6])
    }

    @Test("An offset past the end returns no document and says so; a negative one is moved to zero")
    func offsetEdges() async {
        let past = await list(7, ["offset": .int(7)])
        #expect(!past.isError)
        #expect(past.text.hasPrefix("Showing 0 of 7 documents: offset=7 is past the end. That is all.\n\n"))
        #expect(Self.rows(in: past.text, of: 7).isEmpty)
        #expect(past.text.contains("(nothing at this offset)"))

        let lastRow = await list(7, ["offset": .int(6)])
        #expect(Self.rows(in: lastRow.text, of: 7) == [6])

        let negative = await list(7, ["offset": .int(-1)])
        let range = ToolCatalog.offsetRange
        #expect(negative.text.hasPrefix("offset=-1 is outside \(range.lowerBound)–\(range.upperBound); 0 was used.\n\n"))
        #expect(Self.rows(in: negative.text, of: 7) == Array(0..<7))
    }

    @Test("No open document is not an empty page")
    func nothingOpen() async {
        let sentence = "No documents are open in Pages. Use open_document or create_document."
        let none = await list(0)
        #expect(!none.isError)
        #expect(none.text == sentence)

        let skipped = await list(0, ["offset": .int(4)])
        #expect(skipped.text == "Showing 0 of 0 documents: offset=4 is past the end. That is all.\n\n" + sentence)
    }

    @Test("Documents come in name order whatever order Pages hands them over in, and same names go by id")
    func orderIsStatedAndHasNoTies() async {
        let store = FakePageStore()
        for (identifier, name) in [("id-3", "Untitled"), ("id-1", "Untitled"), ("id-2", "untitled 10"), ("id-4", "Untitled 2")] {
            store.documentsValue[identifier] = Fixtures.document(id: identifier, name: name, text: "invented")
        }
        let result = await call(ToolCatalog.documentsListName, store: store)
        #expect(result.text.contains("ordered by name, then id"))
        let positions = ["id=id-1", "id=id-3", "id=id-4", "id=id-2"].compactMap {
            result.text.range(of: $0)?.lowerBound
        }
        #expect(positions.count == 4 && positions == positions.sorted())

        let second = await call(ToolCatalog.documentsListName, ["limit": 1, "offset": 1], store: store)
        #expect(second.text.contains("id=id-3") && !second.text.contains("id=id-1"))
    }

    @Test("A page of rows too wide to fit holds fewer of them and says where to resume")
    func widePageShrinks() async throws {
        let total = 150
        let wide = String(repeating: "w", count: 1000)
        let store = Self.open(total) { "\(wide)-\(Self.padded($0)).pages" }
        let maximum = ToolCatalog.documentLimitRange.upperBound
        var offset = 0
        var seen: [Int] = []
        while offset < total {
            let result = await call(
                ToolCatalog.documentsListName, ["limit": .int(maximum), "offset": .int(offset)], store: store)
            #expect(result.text.utf16.count <= ToolStandard.longestResult)
            let shown = Self.rows(in: result.text, of: total)
            let last = try #require(shown.last)
            #expect(shown.first == offset)
            #expect(shown.count < maximum)
            let next = last + 1 < total ? "Pass offset=\(last + 1) for the next page." : "That is all."
            #expect(result.text.hasPrefix("Showing \(offset + 1)–\(last + 1) of \(total) documents. \(next)\n\n"))
            seen += shown
            offset = last + 1
        }
        #expect(seen == Array(0..<total))
    }

    // MARK: The window on a document's body

    private static let longBody = (0..<1500).map { "Invented sentence number \(padded($0)) of the fixture." }
        .joined(separator: "\n")

    private static let windowID = "window-document"

    private static func holding(_ body: String, pageTexts: [String]? = nil) -> FakePageStore {
        let store = FakePageStore()
        store.documentsValue[windowID] = Fixtures.document(
            id: windowID, name: "Invented.pages", text: body,
            path: "/Users/user/Documents/Invented.pages", pageTexts: pageTexts)
        return store
    }

    /// The text of a result after what Pages reports about the document, whose last row is
    /// the id.
    private func windowText(_ text: String) throws -> String {
        let heading = try #require(text.range(of: "\(Self.windowID)\n\n"))
        return String(text[heading.upperBound...])
    }

    private func read(_ extra: [String: Value] = [:], body: String = longBody) async -> ToolResult {
        await call(
            ToolCatalog.getName, ["id": .string(Self.windowID)].merging(extra) { _, new in new },
            store: Self.holding(body))
    }

    @Test("A long body comes as one default window, announced before the data")
    func defaultWindow() async throws {
        let size = ToolCatalog.defaultMaxCharacters
        let total = Self.longBody.count
        #expect(total > ToolCatalog.maxCharactersRange.upperBound)
        let result = await read()
        #expect(!result.isError)
        #expect(
            result.text.hasPrefix(
                "Body: characters 1–\(size) of \(total). Pass character_offset=\(size) for the rest.\n\nInvented.pages\n"))
        #expect(try windowText(result.text) == String(Self.longBody.prefix(size)))
    }

    @Test("Windows chain: each starts where the last ended, and together they are the whole body")
    func windowsChain() async throws {
        let total = Self.longBody.count
        var offset = 0
        var joined = ""
        while offset < total {
            let result = await read(["character_offset": .int(offset), "max_characters": .int(7000)])
            let window = try windowText(result.text)
            let last = offset + window.count
            let next = last < total ? "Pass character_offset=\(last) for the rest." : "That is all."
            #expect(result.text.hasPrefix("Body: characters \(offset + 1)–\(last) of \(total). \(next)\n\n"))
            #expect(window.count == min(7000, total - offset))
            joined += window
            offset = last
        }
        #expect(joined == Self.longBody)
    }

    @Test("A body that fits one window carries no notice, and an empty one says it is empty")
    func shortBodyHasNoNotice() async throws {
        let short = await read(body: "Only an invented line.")
        #expect(short.text.hasPrefix("Invented.pages\n"))
        #expect(!short.text.contains("characters"))
        #expect(try windowText(short.text) == "Only an invented line.")

        let empty = await read(body: "")
        #expect(empty.text.hasPrefix("Invented.pages\n"))
        #expect(try windowText(empty.text) == "(the body is empty)")
    }

    @Test("max_characters at its maximum is used as asked; one past either end is moved and reported")
    func windowSizeBounds() async throws {
        let maximum = ToolCatalog.maxCharactersRange.upperBound

        let atMaximum = await read(["max_characters": .int(maximum)])
        #expect(!atMaximum.text.contains("is outside"))
        #expect(try windowText(atMaximum.text).count == maximum)
        #expect(atMaximum.text.utf16.count <= ToolStandard.longestResult)

        let over = await read(["max_characters": .int(maximum + 1)])
        #expect(
            over.text.hasPrefix(
                "max_characters=\(maximum + 1) is outside 1–\(maximum); \(maximum) was used.\nBody: characters 1–\(maximum) of "))
        #expect(try windowText(over.text).count == maximum)

        let under = await read(["max_characters": .int(0)])
        #expect(under.text.hasPrefix("max_characters=0 is outside 1–\(maximum); 1 was used.\nBody: characters 1–1 of "))
        #expect(try windowText(under.text) == "I")
    }

    @Test("character_offset past the end returns no text and says so; a negative one is moved to zero")
    func windowOffsetEdges() async throws {
        let total = Self.longBody.count
        let past = await read(["character_offset": .int(total + 50)])
        #expect(!past.isError)
        #expect(
            past.text.hasPrefix(
                "Body: characters 0 of \(total): character_offset=\(total + 50) is past the end. That is all.\n\n"))
        #expect(try windowText(past.text).isEmpty)

        let negative = await read(["character_offset": .int(-3)])
        let range = ToolCatalog.offsetRange
        #expect(
            negative.text.hasPrefix(
                "character_offset=-3 is outside \(range.lowerBound)–\(range.upperBound); 0 was used.\nBody: characters 1–"))
    }

    @Test("A window of characters that take several UTF-16 units each still fits a result, and still chains")
    func windowOfWideCharacters() async throws {
        // Eight UTF-16 units to the character: a full window would be four results long.
        let body = String(repeating: "👩‍👩‍👧", count: 30_000)
        let maximum = ToolCatalog.maxCharactersRange.upperBound
        var offset = 0
        var joined = ""
        while offset < 30_000 {
            let result = await read(
                ["character_offset": .int(offset), "max_characters": .int(maximum)], body: body)
            #expect(result.text.utf16.count <= ToolStandard.longestResult)
            let window = try windowText(result.text)
            #expect(!window.isEmpty && window.count < maximum)
            let last = offset + window.count
            #expect(result.text.contains("Body: characters \(offset + 1)–\(last) of 30000. "))
            joined += window
            offset = last
        }
        #expect(joined == body)
    }

    // MARK: Pages of one document

    private static let fivePages = (1...5).map { "Invented text of page \($0)." }

    private func pages(_ extra: [String: Value], store: FakePageStore? = nil) async -> ToolResult {
        await call(
            ToolCatalog.getName, ["id": .string(Self.windowID)].merging(extra) { _, new in new },
            store: store ?? Self.holding(Self.fivePages.joined(separator: "\n"), pageTexts: Self.fivePages))
    }

    @Test("first_page and last_page return those pages, both ends included, and read no other page")
    func pageRange() async throws {
        let store = Self.holding(Self.fivePages.joined(separator: "\n"), pageTexts: Self.fivePages)
        let result = await pages(["first_page": 2, "last_page": 3], store: store)
        #expect(!result.isError)
        #expect(result.text.hasPrefix("Invented.pages\n"))
        #expect(
            try windowText(result.text)
                == "[page 2]\nInvented text of page 2.\n\n[page 3]\nInvented text of page 3.")
        #expect(store.fetchedPages == [2...3])
    }

    @Test("Without either page argument the body is read and no page is")
    func bodyReadsNoPage() async {
        let store = Self.holding(Self.fivePages.joined(separator: "\n"), pageTexts: Self.fivePages)
        let result = await pages([:], store: store)
        #expect(!result.text.contains("[page"))
        #expect(store.fetchedPages == [nil])
    }

    @Test("One page argument alone runs to the end of the document")
    func openEndedPageRange() async throws {
        let fromFour = await pages(["first_page": 4])
        #expect(try windowText(fromFour.text) == Format.pageListing(Array(Self.fivePages[3...]), firstPage: 4))
        #expect(!fromFour.text.contains("is outside"))

        let toTwo = await pages(["last_page": 2])
        #expect(try windowText(toTwo.text) == Format.pageListing(Array(Self.fivePages[..<2]), firstPage: 1))
    }

    @Test("The last page is used as asked; a page number past either end is moved and the result says which")
    func pageNumberBounds() async throws {
        let atEnd = await pages(["first_page": 5, "last_page": 5])
        #expect(!atEnd.text.contains("is outside"))
        #expect(try windowText(atEnd.text) == "[page 5]\nInvented text of page 5.")

        let lastOver = await pages(["first_page": 4, "last_page": 6])
        #expect(lastOver.text.hasPrefix("last_page=6 is outside 1–5; 5 was used.\n\nInvented.pages\n"))
        #expect(try windowText(lastOver.text) == Format.pageListing(Array(Self.fivePages[3...]), firstPage: 4))

        let store = Self.holding(Self.fivePages.joined(separator: "\n"), pageTexts: Self.fivePages)
        let firstOver = await pages(["first_page": 40], store: store)
        #expect(firstOver.text.hasPrefix("first_page=40 is outside 1–5; 5 was used.\n\nInvented.pages\n"))
        #expect(try windowText(firstOver.text) == "[page 5]\nInvented text of page 5.")
        #expect(store.fetchedPages.last == 5...5)

        let under = await pages(["first_page": 0, "last_page": 1])
        #expect(under.text.hasPrefix("first_page=0 is outside 1–5; 1 was used.\n\nInvented.pages\n"))
        #expect(try windowText(under.text) == "[page 1]\nInvented text of page 1.")
    }

    @Test("A page range that ends before it starts is refused with the form expected")
    func backwardsPageRangeIsRefused() async {
        let store = Self.holding("invented", pageTexts: Self.fivePages)
        let result = await pages(["first_page": 4, "last_page": 2], store: store)
        #expect(result.isError)
        #expect(result.text.contains("Argument 'last_page' is not valid: 2 is before first_page=4."))
        #expect(result.text.contains("numbered from 1 and both ends are included"))
        #expect(store.fetchedPages.isEmpty)
    }

    @Test("Pages are read through the same window, which names the pages it is a window of")
    func pagesAreWindowed() async throws {
        let texts = (1...6).map { page in
            (0..<100).map { "Invented line \(Self.padded($0)) of page \(page)." }.joined(separator: "\n")
        }
        let whole = Format.pageListing(Array(texts[1...4]), firstPage: 2)
        #expect(whole.count > ToolCatalog.defaultMaxCharacters)

        var offset = 0
        var joined = ""
        while offset < whole.count {
            let result = await pages(
                ["first_page": 2, "last_page": 5, "character_offset": .int(offset)],
                store: Self.holding("invented", pageTexts: texts))
            let window = try windowText(result.text)
            let last = offset + window.count
            // character_offset alone would return a window of the body, so a window that
            // does not end the pages also says which pages to keep asking for.
            let next =
                last < whole.count
                ? "Pass character_offset=\(last) for the rest.\nKeep first_page=2 and last_page=5 in that call."
                : "That is all."
            #expect(result.text.hasPrefix("Pages 2–5: characters \(offset + 1)–\(last) of \(whole.count). \(next)\n\n"))
            #expect(result.text.utf16.count <= ToolStandard.longestResult)
            joined += window
            offset = last
        }
        #expect(joined == whole)

        let one = await pages(
            ["first_page": 3, "last_page": 3, "max_characters": 10],
            store: Self.holding("invented", pageTexts: texts))
        #expect(
            one.text.hasPrefix(
                """
                Page 3: characters 1–10 of \(texts[2].count + 9). Pass character_offset=10 for the rest.
                Keep first_page=3 and last_page=3 in that call.


                """))
    }

    @Test("A locked document says so for a page range too, and returns no text")
    func lockedDocumentHasNoPages() async {
        let store = FakePageStore()
        store.documentsValue[Self.windowID] = Fixtures.document(
            id: Self.windowID, name: "Sealed.pages", text: "", locked: true, pageTexts: ["", ""])
        let result = await pages(["first_page": 1], store: store)
        #expect(!result.isError)
        #expect(result.text.contains("password protected"))
        #expect(!result.text.contains("[page"))
    }

    // MARK: Values refused

    @Test("A wrong type is refused with the form expected, and nothing is done")
    func wrongTypesAreRefused() async {
        let identifier: Value = .string(Self.windowID)
        let cases: [(tool: String, arguments: [String: Value], expected: String)] = [
            (ToolCatalog.documentsListName, ["limit": "ten"], "Argument 'limit' is not valid: a whole number was expected"),
            (ToolCatalog.documentsListName, ["limit": 2.5], "Argument 'limit' is not valid: a whole number was expected"),
            (ToolCatalog.documentsListName, ["offset": true], "Argument 'offset' is not valid: a whole number was expected"),
            (ToolCatalog.getName, ["id": 7], "Argument 'id' is not valid: text was expected"),
            (ToolCatalog.getName, ["id": identifier, "max_characters": "all"], "Argument 'max_characters' is not valid: a whole number was expected"),
            (ToolCatalog.getName, ["id": identifier, "character_offset": [1]], "Argument 'character_offset' is not valid"),
            (ToolCatalog.getName, ["id": identifier, "first_page": "two"], "Argument 'first_page' is not valid: a whole number was expected"),
            (ToolCatalog.getName, ["id": identifier, "last_page": 1.5], "Argument 'last_page' is not valid: a whole number was expected"),
            (ToolCatalog.createName, ["template": 3], "Argument 'template' is not valid: text was expected"),
            (ToolCatalog.createName, ["body": ["a"]], "Argument 'body' is not valid: text was expected"),
            (ToolCatalog.createName, ["paragraphs": "one"], "Argument 'paragraphs' is not valid: an array was expected"),
            (ToolCatalog.createName, ["paragraphs": [["text": "x", "style": 1]]], "entry 0's style is not text"),
            (ToolCatalog.closeName, ["id": identifier, "saving": "yes"], "Argument 'saving' is not valid: true or false was expected"),
            (ToolCatalog.closeName, ["id": identifier, "saving": true, "confirm": 1], "Argument 'confirm' is not valid: true or false was expected"),
            (ToolCatalog.saveName, ["id": identifier, "confirm": "true"], "Argument 'confirm' is not valid: true or false was expected"),
            (ToolCatalog.saveName, ["id": identifier, "path": 5], "Argument 'path' is not valid: text was expected"),
            (ToolCatalog.exportName, ["id": identifier, "to": "/tmp/x.pdf", "format": "pdf", "confirm": "no"], "Argument 'confirm' is not valid"),
        ]
        for (tool, arguments, expected) in cases {
            let store = Self.holding("invented")
            let result = await call(tool, arguments, store: store)
            #expect(result.isError, "\(tool) \(arguments)")
            #expect(result.text.contains(expected), "\(tool) \(arguments): \(result.text)")
            #expect(store.created.isEmpty && store.closed.isEmpty && store.saved.isEmpty && store.exported.isEmpty)
        }
    }

    @Test("A whole number sent as 20.0 is taken as 20, and a null as not given")
    func lenientForms() async {
        let listed = await list(30, ["limit": 20.0, "offset": .null])
        #expect(!listed.isError)
        #expect(listed.text.hasPrefix("Showing 1–20 of 30 documents."))

        let whole = await read(["first_page": .null, "last_page": .null, "max_characters": 12.0])
        #expect(whole.text.hasPrefix("Body: characters 1–12 of "))
    }

    // MARK: Errors and time

    @Test("An error repeats at most a short piece of what the caller sent")
    func errorsClipWhatTheyEcho() async {
        let long = String(repeating: "n", count: 5000)
        let clipped = String(repeating: "n", count: ToolStandard.echoWidth) + "…"
        let identifier: Value = .string(Self.windowID)
        let cases: [(tool: String, arguments: [String: Value])] = [
            (long, [:]),
            (ToolCatalog.getName, ["id": .string(long)]),
            (ToolCatalog.createName, ["template": .string(long)]),
            (ToolCatalog.createName, ["paragraphs": [["text": "x", "style": .string(long)]]]),
            (ToolCatalog.updateName, ["id": identifier, "mode": .string(long), "body": "x"]),
            (ToolCatalog.exportName, ["id": identifier, "to": "/tmp/x.pdf", "format": .string(long)]),
            (ToolCatalog.closeName, ["id": .string(long), "saving": true]),
        ]
        for (tool, arguments) in cases {
            let result = await call(tool, arguments, store: Self.holding("invented"))
            #expect(result.isError, "\(tool.prefix(20))")
            #expect(result.text.contains(clipped), "\(tool.prefix(20)): \(result.text.prefix(200))")
            #expect(!result.text.contains(String(repeating: "n", count: ToolStandard.echoWidth + 1)), "\(tool.prefix(20))")
            #expect(result.text.utf16.count <= ToolStandard.longestError / 5, "\(tool.prefix(20))")
        }
    }

    @Test("Overwriting needs confirm, and the path the caller sent is repeated clipped")
    func confirmationClipsThePath() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-pages-mcp-test-\(UUID().uuidString)")
        let folder = directory.appendingPathComponent(String(repeating: "f", count: 200))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = folder.appendingPathComponent("invented.pdf")
        try Data().write(to: existing)

        let store = Self.holding("invented")
        let result = await call(
            ToolCatalog.exportName,
            ["id": .string(Self.windowID), "to": .string(existing.path), "format": "pdf"], store: store)
        #expect(result.isError && store.exported.isEmpty)
        #expect(result.text.contains("requires confirm=true"))
        #expect(result.text.contains(ToolStandard.echo(existing.path)))
        #expect(!result.text.contains(existing.path))
    }

    @Test("An unknown template lists the closest few of those installed and counts the others")
    func templateCandidatesAreCut() async {
        let store = FakePageStore()
        store.templateNames =
            (0..<90).map { "Invented Template \(Self.padded($0))" } + ["School Report", "Modern Report"]
        let result = await call(ToolCatalog.createName, ["template": "modern reprot"], store: store)
        #expect(result.isError && store.created.isEmpty)
        let shown = ToolError.candidateCount
        #expect(result.text.contains("No template 'modern reprot'."))
        #expect(result.text.contains("The closest \(shown) of the 92 installed: Modern Report, Invented Template 0000, "))
        #expect(result.text.contains(", and \(92 - shown) others."))
        #expect(result.text.components(separatedBy: "Invented Template").count - 1 == shown - 1)

        store.templateNames = ["Blank", "Essay", "Letter"]
        let few = await call(ToolCatalog.createName, ["template": "Nonexistent"], store: store)
        #expect(few.text.contains("Templates installed: Blank, Essay, Letter."))
        #expect(!few.text.contains("others"))
    }

    @Test("Every error this server words is far inside the longest error")
    func errorsAreShort() {
        let long = String(repeating: "n", count: 5000)
        let templates = (0..<200).map { "Invented Template \(Self.padded($0))" }
        let errors: [ToolError] = [
            .notAvailable(.notInstalled), .notAvailable(.notRunning), .notAvailable(.automationDenied),
            .notAvailable(.consentNotGranted), .missingArgument("id"),
            .badArgument(name: "limit", reason: "a whole number was expected"),
            .notFound(identifier: long), .templateNotFound(name: long, available: templates),
            .documentPasswordProtected(name: "Sealed.pages", action: "saving it"),
            .neverSaved(name: "Untitled", action: "there is nowhere to save it"),
            .confirmationRequired(action: "Saving over '/Users/user/Documents/Invented.pages'"),
            .unknownTool(long), .timedOut(seconds: 60), .storeFailure("Pages stopped responding"),
        ]
        for error in errors {
            #expect(error.message.utf16.count <= ToolStandard.longestError / 5, "\(Diagnostics.kind(of: error))")
        }
    }

    @Test("The deadline of a call is within the standard's time limit")
    func deadlineIsWithinTheTimeLimit() {
        #expect(PageTools.defaultTimeout <= ToolStandard.timeLimit)
    }

    @Test("A call Pages never answers is abandoned at the deadline, with an error that says what may have happened", .timeLimit(.minutes(1)))
    func hungCallIsAnswered() async {
        let store = Self.open(3)
        store.hangs = true
        let result = await call(ToolCatalog.documentsListName, store: store, timeout: .milliseconds(200))
        #expect(result.isError)
        #expect(result.text.contains("did not finish"))
        #expect(result.text.contains("may still take effect"))
        #expect(result.text.contains("documents_list reads every open document whatever its limit"))
        #expect(ToolError.timedOut(seconds: 60).message.contains("within 60 seconds"))
        #expect(Diagnostics.kind(of: ToolError.timedOut(seconds: 60)) == "ToolError.timedOut")
    }

    @Test("A call that finishes in time is untouched by the deadline")
    func fastCallIsUnaffected() async {
        let result = await call(ToolCatalog.documentsListName, store: Self.open(2), timeout: .seconds(5))
        #expect(!result.isError)
        #expect(result.text.hasPrefix("2 documents open in Pages"))
    }

    // MARK: What the model reads

    @Test("The instructions and every tool description are within the longest a client keeps")
    func textsAreWithinTheLimit() {
        #expect(ToolStandard.overlongTexts(instructions: PagesMCPServer.instructions, catalog: ToolCatalog.all()).isEmpty)
        #expect(!PagesMCPServer.instructions.isEmpty)
    }

    private func result(of line: String?) throws -> [String: Value] {
        let message = try JSONDecoder().decode(Value.self, from: Data(try #require(line).utf8))
        return try #require(message.objectValue?["result"]?.objectValue)
    }

    /// Measured from the server's own answers, after interpolation and JSON encoding, which
    /// is what a client receives. The lengths are printed so a change that brings one near
    /// the limit shows in the test log before it fails.
    @Test("As sent by initialize and tools/list, the instructions and descriptions are within the limit")
    func textsAsSent() async throws {
        let handler = PagesMCPServer.handler(tools: PageTools(store: FakePageStore()))
        let initialize = try result(
            of: await handler.respond(
                to: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#))
        let instructions = try #require(initialize["instructions"]?.stringValue)
        print("instructions as sent: \(instructions.utf16.count) of \(ToolStandard.longestDescription)")
        #expect(instructions.utf16.count <= ToolStandard.longestDescription)
        #expect(instructions == PagesMCPServer.instructions)

        let listed = try result(of: await handler.respond(to: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        let tools = try #require(listed["tools"]?.arrayValue)
        #expect(tools.count == ToolCatalog.all().count)
        for tool in tools {
            let name = try #require(tool.objectValue?["name"]?.stringValue)
            let description = try #require(tool.objectValue?["description"]?.stringValue)
            print("\(name) description as sent: \(description.utf16.count)")
            #expect(description.utf16.count <= ToolStandard.longestDescription, "\(name)")
        }
    }

    private func properties(of name: String) throws -> [String: [String: Value]] {
        let tool = try #require(ToolCatalog.all().first { $0.name == name })
        guard case .object(let schema) = tool.inputSchema,
            case .object(let properties)? = schema["properties"]
        else { return [:] }
        return properties.compactMapValues(\.objectValue)
    }

    @Test("The listing's schema and description state the range and default of limit and offset that the code enforces")
    func schemaStatesThePage() throws {
        let properties = try properties(of: ToolCatalog.documentsListName)
        let limit = try #require(properties["limit"])
        #expect(limit["minimum"]?.intValue == ToolCatalog.documentLimitRange.lowerBound)
        #expect(limit["maximum"]?.intValue == ToolCatalog.documentLimitRange.upperBound)
        #expect(limit["default"]?.intValue == ToolCatalog.defaultDocumentLimit)
        let offset = try #require(properties["offset"])
        #expect(offset["minimum"]?.intValue == ToolCatalog.offsetRange.lowerBound)
        #expect(offset["maximum"]?.intValue == ToolCatalog.offsetRange.upperBound)
        #expect(offset["default"]?.intValue == 0)

        let description = try #require(ToolCatalog.documentsList.description)
        #expect(description.contains("limit (up to \(ToolCatalog.documentLimitRange.upperBound))"))
        #expect(description.contains("\(ToolCatalog.defaultDocumentLimit) to a page in name order"))
    }

    @Test("The window's schema and description state the range and default the code enforces")
    func schemaStatesTheWindow() throws {
        let properties = try properties(of: ToolCatalog.getName)
        let size = try #require(properties["max_characters"])
        #expect(size["minimum"]?.intValue == ToolCatalog.maxCharactersRange.lowerBound)
        #expect(size["maximum"]?.intValue == ToolCatalog.maxCharactersRange.upperBound)
        #expect(size["default"]?.intValue == ToolCatalog.defaultMaxCharacters)
        #expect(ToolCatalog.defaultMaxCharacters == ToolStandard.usualPage)
        #expect(ToolCatalog.maxCharactersRange.upperBound < ToolStandard.longestResult)
        let offset = try #require(properties["character_offset"])
        #expect(offset["minimum"]?.intValue == 0 && offset["default"]?.intValue == 0)
        #expect(offset["maximum"]?.intValue == ToolCatalog.offsetRange.upperBound)

        let description = try #require(ToolCatalog.get.description)
        #expect(description.contains("the first \(ToolCatalog.defaultMaxCharacters) characters of its body"))
        #expect(description.contains("max_characters (up to \(ToolCatalog.maxCharactersRange.upperBound))"))
    }

    @Test("Every number in a schema has a range, and every default lies inside it")
    func everyNumberHasARange() throws {
        // A page number's upper end is the document's own page count, which no schema can
        // state: the description says a number past it is moved to the last page.
        let openEnded: Set = ["first_page", "last_page"]
        for tool in ToolCatalog.all() {
            for (name, property) in try properties(of: tool.name) where property["type"]?.stringValue == "integer" {
                guard let minimum = property["minimum"]?.intValue else {
                    Issue.record("\(tool.name).\(name) states no minimum")
                    continue
                }
                if openEnded.contains(name) {
                    #expect(minimum == ToolCatalog.firstPageNumber)
                    #expect(property["maximum"] == nil && property["default"] == nil)
                    continue
                }
                guard let maximum = property["maximum"]?.intValue else {
                    Issue.record("\(tool.name).\(name) states no maximum")
                    continue
                }
                if let value = property["default"]?.intValue {
                    #expect((minimum...maximum).contains(value), "\(tool.name).\(name)")
                }
            }
        }
    }

    @Test("Only the standard names page and window a result")
    func standardArgumentNames() throws {
        let standard: Set = ["limit", "offset", "character_offset", "max_characters", "first_page", "last_page"]
        // `to` is not here: export_document's `to` is the file to write, not the end of a range.
        let lookalikes: Set = [
            "max", "count", "max_results", "page", "page_size", "pages", "by_page", "skip", "start",
            "from", "text_limit", "max_chars", "max_length", "char_offset", "cursor",
        ]
        var used: Set<String> = []
        for tool in ToolCatalog.all() {
            let names = Set(try properties(of: tool.name).keys)
            #expect(names.isDisjoint(with: lookalikes), "\(tool.name)")
            used.formUnion(names.intersection(standard))
        }
        #expect(used == standard)
    }

    @Test("The instructions state the sizes and the deadline the code uses")
    func instructionsStateTheSizes() {
        let instructions = PagesMCPServer.instructions
        #expect(instructions.contains("the first \(ToolCatalog.defaultMaxCharacters) characters of the body"))
        #expect(instructions.contains("max_characters up to \(ToolCatalog.maxCharactersRange.upperBound)"))
        #expect(instructions.contains("\(ToolCatalog.defaultDocumentLimit) documents to a page"))
        #expect(instructions.contains("after \(PageTools.defaultTimeout.components.seconds) seconds"))
    }

    @Test("pages_status reports the sizes in force")
    func statusStatesTheSizes() async {
        let result = await call(ToolCatalog.statusName)
        #expect(!result.isError)
        #expect(result.text.contains("\(ToolCatalog.defaultMaxCharacters) characters by default, up to \(ToolCatalog.maxCharactersRange.upperBound)"))
        #expect(result.text.contains("\(ToolCatalog.defaultDocumentLimit) documents by default, up to \(ToolCatalog.documentLimitRange.upperBound)"))
        #expect(result.text.contains("\(PageTools.defaultTimeout.components.seconds) seconds"))
    }

    // MARK: Release metadata

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The manifest is read before the server has ever run: a tool missing from it has no
    /// permission switch, and the installer keys on its version alone.
    @Test("The manifest lists exactly the server's tools, and the three version strings agree")
    func manifestMatchesTheServer() throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("extension/manifest.json"))
        let manifest = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let listed = try #require(manifest["tools"] as? [[String: Any]])
        #expect(listed.compactMap { $0["name"] as? String } == ToolCatalog.all().map(\.name))
        #expect(manifest["version"] as? String == PagesMCPServer.version)
        // The manifest is plain JSON and cannot take the figure from the constant.
        let description = try #require(manifest["long_description"] as? String)
        #expect(description.contains("after \(PageTools.defaultTimeout.components.seconds) seconds"))

        let plistData = try Data(contentsOf: Self.root.appendingPathComponent("Resources/Info.plist"))
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        #expect(plist["CFBundleShortVersionString"] as? String == PagesMCPServer.version)
    }
}
