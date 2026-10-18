import HubLink
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension EnvironmentValues {
    /// Opens a message's files in the preview that comments on them, presented by the conversation
    /// rather than the file tapped. Nil while the Hub would drop comments, when files open in Quick Look.
    @Entry var previewAttachments: (@MainActor (AttachmentPreviewRequest) -> Void)?
}

/// The files of a message to preview, from the one tapped.
struct AttachmentPreviewRequest: Identifiable {
    struct Item {
        let attachment: LinkAttachment
        let url: URL
    }

    let id = UUID()
    let items: [Item]
    let start: Int
    /// Who sent the files and when, under their name.
    var subtitle: String?

    /// A text file small enough to read whole shows as its own text, to select and comment on.
    static func isText(_ item: Item) -> Bool {
        guard item.attachment.annotation == nil else { return false }
        let type = UTType(mimeType: item.attachment.mediaType) ?? UTType(filenameExtension: item.url.pathExtension)
        let size = (try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
        return type?.conforms(to: .text) == true && size <= 512 * 1024
    }
}

/// A message's files in Quick Look, or a text file as its own selectable text, with Mark Up to comment
/// on part of what shows and Comment… in Mark Up's menu for the whole file.
struct AttachmentPreviewScreen: View {
    let request: AttachmentPreviewRequest
    let annotating: Annotating
    @State private var content = PreviewContent()
    @State private var current: Int
    @State private var text: String?
    /// The still being marked, while Mark Up is on.
    @State private var snapshot: UIImage?
    @State private var selection: CGRect?
    @State private var commenting: AnnotationRequest?
    /// Whether the comment last open was saved, which ends Mark Up.
    @State private var saved = false
    @Environment(\.dismiss) private var dismiss

    init(request: AttachmentPreviewRequest, annotating: Annotating) {
        self.request = request
        self.annotating = annotating
        _current = State(initialValue: request.start)
    }

    private var item: AttachmentPreviewRequest.Item { request.items[min(current, request.items.count - 1)] }
    private var showsText: Bool { request.items.count == 1 && AttachmentPreviewRequest.isText(item) }

    var body: some View {
        NavigationStack {
            ZStack {
                if showsText {
                    if let text {
                        SelectableTextPreview(text: text, content: content) { quote, range in
                            commenting = AnnotationRequest(sourceAttachmentID: item.attachment.id, sourceFilename: item.attachment.filename,
                                                           quote: quote,
                                                           caption: AnnotationNotes.linesCaption(item.attachment.filename,
                                                                                                 new: AnnotationNotes.lines(of: range, in: text)),
                                                           monospaced: true)
                        }
                    } else {
                        ProgressView()
                    }
                } else {
                    QuickLookContent(urls: request.items.map(\.url), start: request.start, content: content)
                }
                if let snapshot {
                    RegionMarkingCanvas(snapshot: snapshot, selection: $selection) { region in
                        guard let image = snapshot.cgImage else { return }
                        saved = false
                        commenting = AnnotationRequest(sourceAttachmentID: item.attachment.id, sourceFilename: item.attachment.filename,
                                                       region: region, markedPNG: AnnotationNotes.markedPNG(image, region: region))
                    }
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(item.attachment.filename).font(.headline).lineLimit(1).truncationMode(.middle)
                        if let subtitle = request.subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if item.attachment.annotation == nil { markUp }
                    ShareLink(item: item.url)
                }
            }
        }
        // Quick Look tells nothing of a swipe to another file; the title follows it within moments.
        .task {
            guard request.items.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                if snapshot == nil, let index = content.currentIndex, index != current { current = index }
            }
        }
        .task(id: showsText) {
            guard showsText, text == nil else { return }
            let url = item.url
            text = await Task.detached { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }.value
        }
        .sheet(item: $commenting, onDismiss: {
            if saved { snapshot = nil }
            selection = nil
        }) { comment in
            AnnotationCommentSheet(request: comment) { words in
                try annotating.save(comment, words)
                saved = true
            }
        }
    }

    /// Mark Up freezes what shows to drag a box on; its menu comments on the whole file. The one
    /// annotation button in the apps: on the Mac annotating stays by keyboard shortcut only, which a
    /// phone has no keyboard for.
    private var markUp: some View {
        Menu {
            Button("Comment…", systemImage: "text.bubble") {
                snapshot = nil
                saved = false
                commenting = .attachment(item.attachment)
            }
        } label: {
            Label("Mark Up", systemImage: snapshot == nil ? "pencil.tip.crop.circle" : "pencil.tip.crop.circle.fill")
        } primaryAction: {
            if snapshot != nil {
                snapshot = nil
                selection = nil
            } else {
                current = content.currentIndex ?? current
                snapshot = still()
            }
        }
        .tint(snapshot == nil ? nil : .accentColor)
        .accessibilityValue(snapshot == nil ? "Off" : "On")
    }

    /// A picture is marked on itself, as it shows before zooming; anything else on what the preview shows.
    private func still() -> UIImage? {
        if item.attachment.mediaType.hasPrefix("image/"), let image = DecodedImages.downsampled(item.url, to: 2400) { return image }
        return content.snapshot()
    }
}

/// What the preview shows, kept to freeze it for Mark Up and to know which of the files is showing.
@MainActor final class PreviewContent {
    weak var view: UIView?
    weak var quickLook: QLPreviewController?

    var currentIndex: Int? { quickLook?.currentPreviewItemIndex }

    func snapshot() -> UIImage? {
        guard let view, view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        return UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            _ = view.drawHierarchy(in: view.bounds, afterScreenUpdates: false)
        }
    }
}

/// Quick Look inside the preview's own bars, swiping through the message's files as before.
private struct QuickLookContent: UIViewControllerRepresentable {
    let urls: [URL]
    let start: Int
    let content: PreviewContent

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.currentPreviewItemIndex = start
        content.view = controller.view
        content.quickLook = controller
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(urls: urls) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let urls: [URL]

        init(urls: [URL]) { self.urls = urls }

        nonisolated func numberOfPreviewItems(in controller: QLPreviewController) -> Int { urls.count }

        nonisolated func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            urls[index] as NSURL
        }
    }
}

/// A text or code file as its text, selectable, with Comment… beside Copy for what is selected.
private struct SelectableTextPreview: UIViewRepresentable {
    let text: String
    let content: PreviewContent
    let comment: (String, NSRange) -> Void

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.alwaysBounceVertical = true
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 24, right: 10)
        view.text = text
        view.delegate = context.coordinator
        content.view = view
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.comment = comment
    }

    func makeCoordinator() -> Coordinator { Coordinator(comment: comment) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var comment: (String, NSRange) -> Void

        init(comment: @escaping (String, NSRange) -> Void) { self.comment = comment }

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            let text = (textView.text as NSString)
            guard range.length > 0, NSMaxRange(range) <= text.length else { return nil }
            let quote = text.substring(with: range)
            guard !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let action = UIAction(title: "Comment…", image: UIImage(systemName: "text.bubble")) { [weak self] _ in
                self?.comment(quote, range)
            }
            return UIMenu(children: [action] + suggestedActions)
        }
    }
}
