import CryptoKit
import Foundation
import HubLink
@testable import NoodleMobile
import NoodlePatch
import Testing
import UIKit

/// Comments on files and messages wait above the composer as notes, and go with the next message as
/// files carrying what they refer to, as the Mac's do.
@MainActor @Suite struct AnnotationTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private let source = LinkAttachment(id: UUID(), filename: "review-window.png", mediaType: "image/png", byteCount: 1)

    // MARK: Regions

    /// A box dragged on screen, top-left origin, becomes fractions of the still from its bottom-left corner,
    /// within the picture as it is fitted into the screen.
    @Test func aDraggedBoxBecomesFractionsFromTheBottomLeft() throws {
        let image = AnnotationNotes.fitted(CGSize(width: 200, height: 100), in: CGRect(x: 0, y: 0, width: 400, height: 400))
        #expect(image == CGRect(x: 0, y: 100, width: 400, height: 200))

        let region = try #require(AnnotationNotes.region(of: CGRect(x: 100, y: 100, width: 200, height: 50), in: image))
        #expect(region.x == 0.25)
        #expect(region.y == 0.75)
        #expect(region.width == 0.5)
        #expect(region.height == 0.25)

        // Past the picture's edge, a box keeps only what is on the picture.
        let edge = try #require(AnnotationNotes.region(of: CGRect(x: 300, y: 250, width: 200, height: 200), in: image))
        #expect(edge.x == 0.75 && edge.y == 0 && edge.width == 0.25 && edge.height == 0.25)
        #expect(AnnotationNotes.region(of: CGRect(x: 0, y: 0, width: 50, height: 50), in: image) == nil)
    }

    /// A tap, or a drag too small to mark anything, marks a fingertip's square around the touch.
    @Test func aTapMarksASquareAroundTheTouch() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 300)
        #expect(AnnotationNotes.selection(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 102, y: 140), in: bounds)
            == CGRect(x: 88, y: 88, width: 24, height: 24))
        #expect(AnnotationNotes.selection(from: CGPoint(x: 150, y: 40), to: CGPoint(x: 50, y: 90), in: bounds)
            == CGRect(x: 50, y: 40, width: 100, height: 50))
        #expect(AnnotationNotes.selection(from: CGPoint(x: 2, y: 2), to: CGPoint(x: 2, y: 2), in: bounds)
            == CGRect(x: 0, y: 0, width: 14, height: 14))
    }

    /// The sheet shows the marked part with room around it, top-left origin, within the picture.
    @Test func theSheetShowsTheMarkedPartInItsPlace() {
        let region = LinkAnnotation.Region(x: 0.5, y: 0, width: 0.25, height: 0.25)
        #expect(AnnotationNotes.focus(on: region, in: CGSize(width: 400, height: 400)) == CGRect(x: 144, y: 244, width: 212, height: 156))
    }

    /// The still goes as a PNG with the region outlined in orange, where the region is from the bottom left.
    @Test func theMarkedStillOutlinesTheRegionInOrange() throws {
        let still = try #require(UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100), format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.preferredRange = .standard
            return format
        }()).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }.cgImage)
        let png = try #require(AnnotationNotes.markedPNG(still, region: LinkAnnotation.Region(x: 0.2, y: 0.1, width: 0.5, height: 0.3)))
        let marked = try #require(UIImage(data: png)?.cgImage)
        #expect(marked.width == 100 && marked.height == 100)

        // Read back top-left first: the box spans x 20...70 and, from the top, y 60...90.
        var pixels = [UInt8](repeating: 0, count: 100 * 100 * 4)
        let context = try #require(CGContext(data: &pixels, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(marked, in: CGRect(x: 0, y: 0, width: 100, height: 100))
        func pixel(_ x: Int, _ yFromTop: Int) -> (UInt8, UInt8, UInt8) {
            // The context's memory runs from the top row down.
            let offset = (yFromTop * 100 + x) * 4
            return (pixels[offset], pixels[offset + 1], pixels[offset + 2])
        }
        let edge = pixel(45, 90)
        #expect(edge.0 > 200 && edge.1 > 100 && edge.1 < 180 && edge.2 < 40)
        #expect(pixel(45, 75) == (255, 255, 255))
        #expect(pixel(45, 10) == (255, 255, 255))
    }

    // MARK: Notes

    /// A note's file is named after what it is about, and says what the Mac's says.
    @Test func aTextNoteSaysWhatTheMacSays() {
        let message = UUID()
        let note = LinkAnnotation(version: 2, sourceAttachmentID: source.id, sourceFilename: "Recording.swift", sourceMessageID: message,
                                  quote: "let clock = FrameClock()", comment: "Is this needed?")
        #expect(AnnotationNotes.filename(for: note) == "Annotation — Recording.txt")
        #expect(AnnotationNotes.mediaType(for: note) == "text/plain")
        #expect(AnnotationNotes.text(of: note) == """
            Annotation — Recording.swift

            Comment
            Is this needed?

            Selected text
            let clock = FrameClock()

            Source attachment: \(source.id.uuidString)
            Source message: \(message.uuidString)

            """)

        let whole = LinkAnnotation(version: 2, sourceAttachmentID: source.id, sourceFilename: "plan.pdf", comment: "Shorter")
        #expect(AnnotationNotes.text(of: whole).contains("This comment refers to the whole attachment."))
        let region = LinkAnnotation(version: 2, sourceAttachmentID: source.id, sourceFilename: "shot.png", comment: "Bigger",
                                    region: .init(x: 0, y: 0, width: 1, height: 1))
        #expect(AnnotationNotes.filename(for: region) == "Annotation — shot.png")
        #expect(AnnotationNotes.mediaType(for: region) == "image/png")
    }

    /// A comment on a message quotes it and names the conversation as its source; the message goes by its ID.
    @Test func aCommentOnAMessageQuotesIt() {
        let message = LinkMessage(id: UUID(), conversationID: UUID(), author: .bot(UUID()), body: "Both done.", createdAt: Date(),
                                  delivered: true)
        let request = AnnotationRequest.message(message, quote: "Both done.", author: "Wren", in: "Wren: drafts/today")
        let note = AnnotationNotes.note(request, comment: "  Thanks  ")
        #expect(note.sourceFilename == "Message — Wren- drafts-today.txt")
        #expect(note.sourceMessageID == message.id)
        #expect(note.quote == "Both done.")
        #expect(note.comment == "Thanks")
        #expect(note.version == 2)
        #expect(AnnotationNotes.isValid(note))
        #expect(!AnnotationNotes.isValid(AnnotationNotes.note(request, comment: "  ")))
    }

    /// The sheet says which lines a quote is from.
    @Test func quotesSayWhichLinesTheyAreFrom() {
        #expect(AnnotationNotes.linesCaption("Recording.swift", new: [12, 13, 14, 15]) == "Recording.swift · lines 12–15")
        #expect(AnnotationNotes.linesCaption("Recording.swift", new: [8]) == "Recording.swift · line 8")
        #expect(AnnotationNotes.linesCaption("Recording.swift", new: [], old: [6, 7]) == "Recording.swift · lines 6–7 (removed)")
        let text = "one\ntwo\nthree\nfour"
        #expect(AnnotationNotes.lines(of: NSRange(location: 4, length: 3), in: text) == [2, 2])
        #expect(AnnotationNotes.lines(of: NSRange(location: 5, length: 8), in: text) == [2, 3])
        #expect(AnnotationNotes.lines(of: NSRange(location: 0, length: 4), in: text) == [1, 1])
    }

    /// Lines picked in a patch quote as the Mac quotes them, a drag picking from where it started.
    @Test func pickedPatchLinesQuoteAsOnTheMac() throws {
        let patch = try #require(Patch("""
            diff --git a/Sources/App.swift b/Sources/App.swift
            --- a/Sources/App.swift
            +++ b/Sources/App.swift
            @@ -1,3 +1,4 @@
             let name: String
            -let old: Int
            +let version: Int
            +let build: Int
             let end: Bool

            """))
        let model = PatchReviewModel(patch: patch, viewed: []) { _ in }
        model.select(path: "Sources/App.swift", hunk: 0, line: 3)
        model.drag(path: "Sources/App.swift", hunk: 0, from: 3, to: 1)
        #expect(model.isSelected(path: "Sources/App.swift", hunk: 0, line: 2))
        #expect(!model.isSelected(path: "Sources/App.swift", hunk: 0, line: 4))
        #expect(model.selectedQuote == "Sources/App.swift:2-3\n-let old: Int\n+let version: Int\n+let build: Int")
        #expect(model.selectedText == "let old: Int\nlet version: Int\nlet build: Int")
        #expect(model.selectedCaption == "App.swift · lines 2–3")

        // Tapping the only line picked lets go of it.
        model.select(path: "Sources/App.swift", hunk: 0, line: 0)
        model.select(path: "Sources/App.swift", hunk: 0, line: 0)
        #expect(model.selection == nil)

        let frames = [0: CGRect(x: 0, y: 0, width: 10, height: 10), 1: CGRect(x: 0, y: 10, width: 10, height: 10)]
        #expect(PatchReviewModel.line(at: 14, in: frames) == 1)
        #expect(PatchReviewModel.line(at: 90, in: frames) == 1)
        #expect(PatchReviewModel.line(at: -5, in: frames) == 0)
    }

    // MARK: Waiting notes

    /// Notes wait per conversation, across launches; editing one changes its comment and its file.
    @Test func notesWaitAboveTheComposerAcrossLaunches() throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let conversation = UUID(), other = UUID()
        let drafts = AnnotationDrafts(folder: folder)
        try drafts.save(AnnotationRequest(sourceAttachmentID: source.id, sourceFilename: "notes.txt", quote: "two"),
                        comment: "Say three", in: conversation)
        try drafts.save(AnnotationRequest(sourceAttachmentID: source.id, sourceFilename: source.filename,
                                          region: .init(x: 0, y: 0, width: 0.5, height: 0.5), markedPNG: Data([1, 2, 3])),
                        comment: "Bigger", in: conversation)
        #expect(drafts.drafts(in: other).isEmpty)
        #expect(throws: (any Error).self) { try drafts.save(.attachment(source), comment: " ", in: conversation) }

        let relaunched = AnnotationDrafts(folder: folder)
        let notes = relaunched.drafts(in: conversation)
        #expect(notes.map(\.annotation.comment) == ["Say three", "Bigger"])
        #expect(notes.map(\.filename) == ["Annotation — notes.txt", "Annotation — review-window.png"])
        #expect(try Data(contentsOf: relaunched.url(of: notes[1])) == Data([1, 2, 3]))

        let editing = relaunched.request(editing: notes[0])
        #expect(editing.comment == "Say three" && editing.quote == "two" && editing.draft == notes[0].id)
        try relaunched.save(editing, comment: "Say four", in: conversation)
        #expect(relaunched.drafts(in: conversation).map(\.annotation.comment) == ["Say four", "Bigger"])
        #expect(try String(contentsOf: relaunched.url(of: notes[0]), encoding: .utf8).contains("Comment\nSay four\n"))

        relaunched.remove(notes[1].id, in: conversation)
        #expect(relaunched.drafts(in: conversation).map(\.id) == [notes[0].id])
        #expect(!FileManager.default.fileExists(atPath: relaunched.url(of: notes[1]).path))
    }

    /// Sent, the notes leave the composer as files of the message carrying their annotation; a message that
    /// could not be made puts them back.
    @Test func notesGoWithTheNextMessage() throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let conversation = UUID()
        let drafts = AnnotationDrafts(folder: folder)
        try drafts.save(.attachment(source), comment: "Use the dark one", in: conversation)
        let note = try #require(drafts.drafts(in: conversation).first)

        let files = drafts.take(in: conversation)
        #expect(drafts.drafts(in: conversation).isEmpty)
        #expect(files.map(\.id) == [note.id])
        let (message, attachments) = try OutgoingMessages.make("Two things", files: files, to: conversation)
        #expect(message.attachmentIDs == [note.id])
        #expect(attachments.first?.annotation == note.annotation)
        #expect(attachments.first?.filename == "Annotation — review-window.txt")
        #expect(attachments.first?.mediaType == "text/plain")
        #expect(attachments.first?.pixelSize == nil)

        drafts.restore(files, in: conversation)
        #expect(drafts.drafts(in: conversation).map(\.id) == [note.id])
        let again = drafts.take(in: conversation)
        drafts.discard(again)
        #expect(!FileManager.default.fileExists(atPath: again[0].url.path))
        #expect(AnnotationDrafts(folder: folder).drafts(in: conversation).isEmpty)
    }

    /// A message taken back to edit puts its notes back above the composer, copied in from where it kept them.
    @Test func aMessageTakenBackPutsItsNotesBack() throws {
        let folder = folder(), elsewhere = self.folder()
        defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: elsewhere) }
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let kept = elsewhere.appendingPathComponent("Annotation — review-window.txt")
        try Data("note".utf8).write(to: kept)
        let note = LinkAnnotation(version: 2, sourceAttachmentID: source.id, sourceFilename: source.filename, comment: "Again")
        let conversation = UUID()
        let drafts = AnnotationDrafts(folder: folder)
        drafts.restore([OutgoingFile(url: kept, filename: kept.lastPathComponent, mediaType: "text/plain", annotation: note)],
                       in: conversation)
        let restored = try #require(drafts.drafts(in: conversation).first)
        #expect(restored.annotation == note)
        #expect(try Data(contentsOf: drafts.url(of: restored)) == Data("note".utf8))

        // Notes of a conversation that is gone go with it.
        drafts.retain([])
        #expect(drafts.drafts(in: conversation).isEmpty)
    }

    /// Only a Hub that keeps what a note refers to is offered comments; an older one would pass on a bare file.
    @Test func commentsNeedAHubThatKeepsThem() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // What a pairing keeps of its Hub; the status it last heard is read only beside it.
        struct SavedHub: Encodable {
            var name = "Hub"
            let key: LinkPublicKey
            var endpoints: [LinkEndpoint] = []
            var userName = "Petko"
        }
        try JSONEncoder().encode(SavedHub(key: LinkPublicKey(P256.Signing.PrivateKey().publicKey)))
            .write(to: directory.appendingPathComponent("hub.json"))
        #expect(!HubChats(pairing: HubPairing(directory: directory, deviceName: "iPhone")).canAnnotate)

        let status = LinkStatus(hubName: "Hub", userName: "Petko", planName: "", harnesses: [], endpoints: [], keepsAnnotations: true)
        try JSONEncoder().encode(status).write(to: directory.appendingPathComponent("status.json"))
        #expect(HubChats(pairing: HubPairing(directory: directory, deviceName: "iPhone")).canAnnotate)
    }
}
