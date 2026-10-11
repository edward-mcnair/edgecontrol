import SwiftUI

struct ApplicationLauncherWidget: DashboardWidget {
    let widgetId = "application-launcher"
    let displayName = "App Launcher"
    let description = "Your apps, one tap away. Tap + to add; hold an icon to replace or remove."
    let iconName = "square.grid.2x2"
    let category: WidgetCategory = .info
    let supportedSizes = WidgetSizeRange(min: .size(2, 2), max: .size(24, 12))
    let defaultSize = WidgetSize.size(4, 2)
    let configSchema = [
        ConfigSchemaEntry(key: "showNames", label: "Show application names", type: .toggle, defaultValue: .bool(true))
    ]
    @MainActor func body(size: WidgetSize, config: WidgetConfig) -> any View {
        if config.string("_instanceId").isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "square.grid.2x2").font(.largeTitle)
                Text("App Launcher").font(.headline)
                Text("Your apps, one tap away").font(.caption)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            LauncherTile(config: config)
        }
    }
}

private struct LauncherTile: View {
    let config: WidgetConfig
    @EnvironmentObject private var layoutEngine: LayoutEngine
    @State private var regionID = UUID()
    private var active: Bool { config.bool("_mediaActive", default: true) && !config.bool("_mediaEditing") }
    var body: some View {
        LauncherPanel(
            items: LauncherItem.decode(config.string("launcherApps")),
            showNames: config.bool("showNames", default: true), active: active
        ) { items in
            let pageID = config.string("_pageId"), instanceID = config.string("_instanceId")
            guard
                let placement = layoutEngine.document.pages.first(where: { $0.id == pageID })?
                    .widgets.first(where: { $0.instanceId == instanceID })
            else { return }
            var saved = placement.config
            let previous = placement.config.string("launcherApps")
            if LauncherItem.decodeIfValid(previous) == nil {
                // Keep a list that couldn't be read instead of losing it.
                saved["launcherAppsUnreadable"] = .string(previous)
            }
            saved["launcherApps"] = .string(LauncherItem.encode(items))
            layoutEngine.updateWidgetConfig(pageId: pageID, instanceId: instanceID, config: saved)
        }
        .background(
            GeometryReader { geo in
                MediaTouchAnchor(id: regionID, frame: geo.frame(in: .named(TouchCoordinate.name)), enabled: active)
            }
        )
        .onDisappear { MediaTouchRouting.shared.unregister(regionID) }
    }
}

struct LauncherPanel: NSViewRepresentable {
    let items: [LauncherItem?]
    let showNames: Bool
    let active: Bool
    let save: ([LauncherItem?]) -> Void
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LauncherPanelView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 480, height: proposal.height ?? 232)
    }
    func makeNSView(context: Context) -> LauncherPanelView { LauncherPanelView() }
    func updateNSView(_ view: LauncherPanelView, context: Context) {
        view.configure(items: items, showNames: showNames, active: active, save: save)
    }
    static func dismantleNSView(_ view: LauncherPanelView, coordinator: ()) { view.deactivate() }
}
