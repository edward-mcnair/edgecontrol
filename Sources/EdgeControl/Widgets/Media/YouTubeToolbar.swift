import AppKit
import SwiftUI

/// Real AppKit controls provide deterministic HID actions independent of the
/// desktop cursor, plus normal mouse, keyboard and accessibility behavior.
struct YouTubeToolbar: NSViewRepresentable {
    var touchEnabled = true
    @ObservedObject var browser: YouTubeBrowserModel
    func makeCoordinator() -> Coordinator { Coordinator(browser: browser) }
    func makeNSView(context: Context) -> NSStackView {
        let c = context.coordinator
        let stack = NSStackView()
        c.root = stack
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        func add(_ symbol: String, _ label: String, _ action: Selector, title: String = "") -> NSButton {
            let button = NSButton(
                image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: c, action: action)
            button.bezelStyle = .regularSquare
            button.title = title
            button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
            button.font = .systemFont(ofSize: 13, weight: .medium)
            button.wantsLayer = true
            button.layer?.cornerRadius = 8
            button.layer?.masksToBounds = true
            button.toolTip = label
            button.setAccessibilityLabel(label)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: title.isEmpty ? 44 : 116).isActive = true
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
            c.controls.append(button)
            stack.addArrangedSubview(button)
            return button
        }
        _ = add("chevron.left", "Back", #selector(Coordinator.back))
        _ = add("house", "YouTube home", #selector(Coordinator.home))
        c.search.placeholderString = "Search YouTube or paste a link"
        c.search.font = .systemFont(ofSize: 14)
        c.search.controlSize = .large
        c.search.bezelStyle = .roundedBezel
        c.search.heightAnchor.constraint(equalToConstant: 36).isActive = true
        c.search.target = c
        c.search.action = #selector(Coordinator.submit)
        c.search.setAccessibilityLabel("Search YouTube or paste a link")
        c.search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        c.search.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        c.controls.append(c.search)
        stack.addArrangedSubview(c.search)
        c.search.widthAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
        _ = add("magnifyingglass", "Search", #selector(Coordinator.submit))
        c.fill = add(
            "arrow.up.left.and.arrow.down.right", "Fill video tile", #selector(Coordinator.fillVideo),
            title: "Fill video")
        _ = add("arrow.clockwise", "Reload", #selector(Coordinator.reload))
        _ = add("safari", "Open in browser", #selector(Coordinator.openExternal))
        return stack
    }
    func updateNSView(_ view: NSStackView, context: Context) {
        let c = context.coordinator
        if touchEnabled {
            MediaTouchRouting.shared.registerToolbar(c.id, root: view, controls: c.controls)
        } else {
            MediaTouchRouting.shared.unregisterToolbar(c.id)
        }
        c.fill?.isEnabled = browser.hasLoaded && !browser.changingVideoArea
        let label = browser.fillsVideoArea ? "Restore browsing" : "Fill video tile"
        c.fill?.title = browser.fillsVideoArea ? "Browse" : "Fill video"
        c.fill?.toolTip = label
        c.fill?.setAccessibilityLabel(label)
        c.fill?.image = NSImage(
            systemSymbolName: browser.fillsVideoArea
                ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
            accessibilityDescription: label)
    }
    static func dismantleNSView(_ view: NSStackView, coordinator: Coordinator) {
        MediaTouchRouting.shared.unregisterToolbar(coordinator.id)
    }
    @MainActor final class Coordinator: NSObject {
        let id = UUID()
        weak var root: NSStackView?
        var controls: [NSControl] = []
        let browser: YouTubeBrowserModel
        let search = NSTextField(string: "")
        var fill: NSButton?
        init(browser: YouTubeBrowserModel) { self.browser = browser }
        @objc func back() { browser.webView.goBack() }
        @objc func home() { browser.loadHome() }
        @objc func submit() { browser.search(search.stringValue) }
        @objc func fillVideo() { browser.toggleVideoArea() }
        @objc func reload() { browser.webView.reload() }
        @objc func openExternal() { browser.openExternal() }
    }
}
