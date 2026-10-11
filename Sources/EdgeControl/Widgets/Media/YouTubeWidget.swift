import SwiftUI
import WebKit

struct YouTubeWidget: DashboardWidget {
    let widgetId = "youtube"
    let displayName = "YouTube"
    let description = "Your YouTube account, video and touch controls in a resizable media tile."
    let iconName = "play.rectangle.fill"
    let category: WidgetCategory = .media
    let supportedSizes = WidgetSizeRange(min: .size(4, 3), max: .size(24, 12))
    let defaultSize = WidgetSize.size(8, 5)
    let configSchema: [ConfigSchemaEntry] = []

    @MainActor func body(size: WidgetSize, config: WidgetConfig) -> any View {
        if config.string("_instanceId").isEmpty {
            VStack(spacing: 12) {
                Image(systemName: iconName).font(.largeTitle).foregroundStyle(.red)
                Text("YouTube").font(.headline)
                Text("Browse, sign in and play inside your dashboard.")
                    .font(.caption).multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
        } else {
            YouTubeTile(
                instanceID: config.string("_instanceId"), editing: config.bool("_mediaEditing"),
                active: config.bool("_mediaActive", default: true),
                visible: config.bool("_mediaVisible", default: true))
        }
    }
}

private struct YouTubeTile: View {
    let instanceID: String
    let editing: Bool
    /// Accepts touches: on the current page, not editing, nothing else expanded.
    let active: Bool
    /// On the current page. Playback follows this, not `active`, so expanding
    /// another widget over the dashboard doesn't pause the video.
    let visible: Bool
    @StateObject private var browser: YouTubeBrowserModel
    init(instanceID: String, editing: Bool, active: Bool, visible: Bool) {
        self.instanceID = instanceID
        self.editing = editing
        self.active = active
        self.visible = visible
        _browser = StateObject(wrappedValue: YouTubeSessions.shared.model(for: instanceID))
    }
    @State private var regionID = UUID()

    var body: some View {
        VStack(spacing: 0) {
            YouTubeToolbar(touchEnabled: !editing && active, browser: browser)
                .frame(height: 56)
                .padding(.horizontal, 8)
            YouTubeBrowserView(model: browser)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .background(
            GeometryReader { geo in
                MediaTouchAnchor(
                    id: regionID, frame: geo.frame(in: .named(TouchCoordinate.name)), enabled: !editing && active)
            }
        )
        .onAppear { if visible && !browser.hasLoaded { browser.loadHome() } }
        .onChange(of: visible) { _, nowVisible in
            if nowVisible && !browser.hasLoaded { browser.loadHome() }
            if !nowVisible { browser.webView.pauseAllMediaPlayback(completionHandler: {}) }
        }
        .onDisappear {
            MediaTouchRouting.shared.unregister(regionID)
            // Expanding or collapsing the tile replaces this host with another;
            // only a tile that is really gone (page left far behind) pauses.
            YouTubeSessions.shared.pauseIfUnhosted(instanceID)
        }
    }
}

/// Preserve each tile's page/player through dashboard paging and focus mode.
@MainActor final class YouTubeSessions {
    static let shared = YouTubeSessions()
    private var models: [String: YouTubeBrowserModel] = [:]
    func model(for id: String) -> YouTubeBrowserModel {
        if let existing = models[id] { return existing }
        let model = YouTubeBrowserModel()
        models[id] = model
        return model
    }
    /// Pauses a session whose web view no host has claimed once the current
    /// view swap has settled.
    func pauseIfUnhosted(_ id: String) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let model = self?.models[id], model.webView.window == nil else { return }
            model.webView.pauseAllMediaPlayback(completionHandler: {})
        }
    }
    func pauseAll() {
        for model in models.values { model.webView.pauseAllMediaPlayback(completionHandler: {}) }
    }
    func retainOnly(_ ids: Set<String>) {
        for id in Array(models.keys) where !ids.contains(id) {
            models[id]?.webView.pauseAllMediaPlayback(completionHandler: {})
            models[id]?.webView.stopLoading()
            models.removeValue(forKey: id)
        }
    }
}
