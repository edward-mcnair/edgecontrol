import SwiftUI

struct AppleMusicWidget: DashboardWidget {
    let widgetId = "apple-music"
    let displayName = "Apple Music"
    let description =
        "Native Apple Music playback, catalog search, library albums, songs and playlists with touch controls."
    let iconName = "music.note"
    let category: WidgetCategory = .media
    let supportedSizes = WidgetSizeRange(min: .size(4, 5), max: .size(24, 12))
    let defaultSize = WidgetSize.size(8, 6)
    let configSchema: [ConfigSchemaEntry] = []
    @MainActor func body(size: WidgetSize, config: WidgetConfig) -> any View {
        if config.string("_instanceId").isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "music.note").font(.largeTitle).foregroundStyle(.pink)
                Text("Apple Music").font(.headline)
                Text("Your library. Your music. Right here.").font(.caption)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            AppleMusicTile(
                editing: config.bool("_mediaEditing"), active: config.bool("_mediaActive", default: true),
                visible: config.bool("_mediaVisible", default: true))
        }
    }
}
private struct AppleMusicTile: View {
    let editing: Bool
    /// Accepts touches.
    let active: Bool
    /// On the current page; playback follows this, not `active`.
    let visible: Bool
    @State private var id = UUID()
    var body: some View {
        AppleMusicPanel(touchEnabled: active && !editing, model: .shared)
            .background(.black)
            .background(
                GeometryReader { geo in
                    MediaTouchAnchor(
                        id: id, frame: geo.frame(in: .named(TouchCoordinate.name)), enabled: active && !editing)
                }
            )
            .onAppear { AppleMusicModel.shared.setVisible(id, visible) }
            .onChange(of: visible) { _, value in AppleMusicModel.shared.setVisible(id, value) }
            .onDisappear {
                MediaTouchRouting.shared.unregister(id)
                AppleMusicModel.shared.setVisible(id, false)
            }
    }
}
