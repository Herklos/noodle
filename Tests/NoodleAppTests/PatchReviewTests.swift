import Foundation
import NoodleCore
import XCTest
@testable import Noodle

@MainActor final class PatchReviewTests: XCTestCase {
    private let diff = """
    diff --git a/Sources/App.swift b/Sources/App.swift
    index 1111111..2222222 100644
    --- a/Sources/App.swift
    +++ b/Sources/App.swift
    @@ -1,3 +1,4 @@ struct App {
         let name: String
    +    let version: Int
         let build: Int
         var title: String
    diff --git a/README.md b/README.md
    index 3333333..4444444 100644
    --- a/README.md
    +++ b/README.md
    @@ -1 +1 @@
    -# App
    +# The App

    """

    private func fixture() throws -> StoreFixture {
        let fixture = try StoreFixture()
        addTeardownBlock { @MainActor in fixture.cleanUp() }
        return fixture
    }

    private func attachment(_ text: String, named name: String = "change.patch", in f: StoreFixture) throws -> ConversationAttachment {
        try f.repository.importAttachment(data: Data(text.utf8), originalFilename: name, into: f.directA.id,
                                          mediaType: "application/octet-stream")
    }

    func testOnlyAFileThatReadsAsAPatchOpensInAReview() throws {
        let f = try fixture()
        let patch = try attachment(diff, in: f)
        XCTAssertTrue(patch.isPatchFile)
        XCTAssertEqual(PatchCache.patchNow(at: f.store.attachmentFileURL(patch))?.files.count, 2)

        // Named like a patch, but Quick Look shows it as the text it is.
        let notes = try attachment("Remember to review the patch.", named: "notes.diff", in: f)
        XCTAssertTrue(notes.isPatchFile)
        XCTAssertNil(PatchCache.patchNow(at: f.store.attachmentFileURL(notes)))

        let text = try attachment(diff, named: "change.txt", in: f)
        XCTAssertFalse(text.isPatchFile)
    }

    func testViewedFilesFoldAwayAndAreRemembered() throws {
        let f = try fixture()
        let attachment = try attachment(diff, in: f)
        let patch = try XCTUnwrap(Patch(diff))
        var saved: [Set<String>] = []
        let model = PatchReviewModel(patch: patch, attachment: attachment, viewed: []) {
            saved.append($0)
            f.store.saveViewedPatchFiles($0, for: attachment)
        }
        model.toggle("README.md")
        model.select(path: "README.md", hunk: 0, line: 1, extending: false)
        model.setViewed("README.md", true)
        XCTAssertEqual(model.viewed, ["README.md"])
        XCTAssertFalse(model.expanded.contains("README.md"))
        XCTAssertNil(model.selection)
        XCTAssertEqual(saved, [["README.md"]])
        XCTAssertEqual(f.store.viewedPatchFiles(attachment), ["README.md"])
        XCTAssertEqual(PatchReviewStore(fileURL: f.repository.rootURL.appendingPathComponent("patch-reviews.json")).viewed(attachment),
                       ["README.md"])

        model.setViewed("README.md", false)
        XCTAssertEqual(f.store.viewedPatchFiles(attachment), [])
    }

    func testACommentQuotesTheSelectedLinesOfItsPatch() throws {
        let f = try fixture()
        let attachment = try attachment(diff, in: f)
        let patch = try XCTUnwrap(Patch(diff))
        let model = PatchReviewModel(patch: patch, attachment: attachment, viewed: []) { _ in }
        XCTAssertNil(model.selectedQuote)

        model.select(path: "Sources/App.swift", hunk: 0, line: 1, extending: false)
        model.select(path: "Sources/App.swift", hunk: 0, line: 2, extending: true)
        XCTAssertTrue(model.isSelected(path: "Sources/App.swift", hunk: 0, line: 2))
        XCTAssertFalse(model.isSelected(path: "Sources/App.swift", hunk: 0, line: 0))
        let quote = try XCTUnwrap(model.selectedQuote)
        XCTAssertEqual(quote, "Sources/App.swift:2-3\n+    let version: Int\n     let build: Int")

        // Saved as any other annotation: it waits in the composer and names the patch as its source.
        let note = AttachmentAnnotation(source: attachment, quote: quote, comment: "Should this be optional?")
        try f.store.saveAnnotation(note, content: AnnotationContent.data(for: note, snapshot: nil), source: attachment)
        let saved = try XCTUnwrap(f.store.pendingAttachments(for: f.directA.id).last?.annotation)
        XCTAssertEqual(saved.sourceAttachmentID, attachment.id)
        XCTAssertEqual(saved.quote, quote)
        XCTAssertEqual(patch.place(of: quote)?.line, 2)

        // Selecting one line, then the same line again, lets go of it.
        model.select(path: "README.md", hunk: 0, line: 0, extending: true)
        XCTAssertEqual(model.selection?.lines, 0...0)
        model.select(path: "README.md", hunk: 0, line: 0, extending: false)
        XCTAssertNil(model.selection)
    }
}
