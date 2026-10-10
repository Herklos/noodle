import NoodleCore
import NoodleRuntime
import NoodleRuntimeSettings
import NoodleSettingsUI
import SwiftUI

/// The tool in a bot's list. Models are shared by every bot, so its edit button opens the same
/// sheet as Settings.
struct ImageGenerationToolRow: View {
    let controller: ImageGenerationController
    let onRemove: () -> Void
    @State private var editing = false

    var body: some View {
        HStack(spacing: 10) {
            ImageGenerationIcon(size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text("Image Generation").lineLimit(1)
                HStack(spacing: 4) {
                    if controller.models.isEmpty && controller.downloadingID == nil {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    Text(controller.summary).foregroundStyle(.secondary).lineLimit(1)
                }.font(.caption)
            }
            Spacer()
            Button { editing = true } label: { Image(systemName: "pencil").foregroundStyle(.secondary) }
                .buttonStyle(.plain).help("Choose image models")
            Button(action: onRemove) { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain).help("Remove Image Generation from this bot")
        }
        .padding(8)
        .sheet(isPresented: $editing) { ImageModelsSheet(controller: controller).noodleSheetSizing() }
    }
}

