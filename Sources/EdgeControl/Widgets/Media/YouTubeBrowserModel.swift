import AppKit
import SwiftUI
import WebKit

@MainActor
final class YouTubeBrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published var hasLoaded = false
    @Published var status = "Not tested · no website loaded"
    @Published var fillsVideoArea = false
    @Published var changingVideoArea = false
    private var layoutGeneration = 0
    private var urlObservation: NSKeyValueObservation?
    let webView: WKWebView
    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(
            forIdentifier: UUID(uuidString: "D9F84713-FA9B-48C6-9037-1235638CD107")!)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.fillsVideoArea else { return }
                await self.setVideoAreaFilled(false)
            }
        }
        // Deliberately no user-agent spoofing, injected auth scripts or cookie imports.
    }
    // Presentation-only styling retains the original player, account, controls and playback.
    // No iframe replacement, stream extraction, authentication changes or media reload.
    static func videoAreaScript(_ enabled: Bool) -> String {
        """
        (() => {
          const key = 'data-edge-media-path';
          const styleID = 'edge-media-video-area';
          document.getElementById(styleID)?.remove();
          document.querySelectorAll('[' + key + ']').forEach(e => e.removeAttribute(key));
          if (!\(enabled ? "true" : "false")) {
            window.dispatchEvent(new Event('resize'));
            return false;
          }
          const player = document.getElementById('movie_player');
          if (!player || !player.querySelector('video')) return false;
          // Live ancestor selectors follow YouTube when theater mode reparents its player.
          const style = document.createElement('style');
          style.id = styleID;
          style.textContent = `
            html:has(#movie_player video), body:has(#movie_player video) {
              overflow: hidden !important; background: black !important;
            }
            body:has(#movie_player video), body:has(#movie_player video) :has(#movie_player) {
              transform: none !important; perspective: none !important;
              filter: none !important; contain: none !important;
              content-visibility: visible !important; overflow: visible !important;
            }
            body:has(#movie_player video) > :not(:has(#movie_player)):not(#movie_player),
            body:has(#movie_player video) :has(#movie_player) > :not(:has(#movie_player)):not(#movie_player) {
              visibility: hidden !important; pointer-events: none !important;
            }
            #movie_player {
              position: fixed !important; inset: 0 !important; margin: 0 !important;
              width: 100vw !important; height: 100vh !important;
              min-width: 0 !important; min-height: 0 !important;
              max-width: none !important; max-height: none !important;
              z-index: 2147483647 !important; background: black !important;
            }
            #movie_player .html5-video-container {
              width: 100% !important; height: 100% !important;
            }
            #movie_player video {
              width: 100% !important; height: 100% !important;
              left: 0 !important; top: 0 !important; object-fit: contain !important;
            }
            #movie_player .ytp-chrome-bottom {
              width: calc(100% - 24px) !important; left: 12px !important;
            }
          `;
          document.head.appendChild(style);
          window.dispatchEvent(new Event('resize'));
          return true;
        })()
        """
    }
    func toggleVideoArea() {
        guard !changingVideoArea else { return }
        Task { await setVideoAreaFilled(!fillsVideoArea) }
    }
    func setVideoAreaFilled(_ enabled: Bool) async {
        guard !enabled || ["www.youtube.com", "youtube.com", "m.youtube.com"].contains(webView.url?.host ?? "") else {
            status = "Open a YouTube video first."; return
        }
        let generation = layoutGeneration
        changingVideoArea = true
        defer { changingVideoArea = false }
        do {
            let filled = (try await webView.evaluateJavaScript(Self.videoAreaScript(enabled)) as? Bool) == true
            guard generation == layoutGeneration else { return }
            fillsVideoArea = filled
            status =
                fillsVideoArea
                ? "Video fills this panel · Restore page returns to browsing"
                : (enabled ? "Open a video before filling the video area." : "YouTube page restored")
        } catch {
            fillsVideoArea = false
            status = "Could not change video layout: \(error.localizedDescription)"
        }
    }
    func loadHome() { navigate(URL(string: "https://www.youtube.com/")!) }
    func search(_ text: String) {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        if let direct = URL(string: input), direct.scheme == "https",
            ["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be"].contains(direct.host ?? "")
        {
            navigate(direct); return
        }
        var url = URLComponents(string: "https://www.youtube.com/results")!
        url.queryItems = [URLQueryItem(name: "search_query", value: text)]
        navigate(url.url!)
    }
    func navigate(_ url: URL) { hasLoaded = true; status = "Loading…"; webView.load(URLRequest(url: url)) }
    func openExternal() {
        let url = webView.url ?? URL(string: "https://www.youtube.com/")!
        guard url.scheme == "https" else { return }
        NSWorkspace.shared.open(url)
    }
    func clearSession() {
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        let store = webView.configuration.websiteDataStore
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
            [weak self] in
            Task { @MainActor in
                self?.hasLoaded = false; self?.status = "YouTube website data cleared"
            }
        }
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // Reload may keep the same URL, so URL observation alone cannot reset the toolbar.
        layoutGeneration += 1
        fillsVideoArea = false
        status = "Loading…"
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        layoutGeneration += 1
        fillsVideoArea = false
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        status = "\(webView.url?.host ?? "Local test")"
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { status = error.localizedDescription }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        status = error.localizedDescription
    }
    /// Pages that belong in the panel: YouTube and Google sign-in/consent.
    /// Everything else (links in video descriptions, sponsors) opens in your
    /// browser, keeping arbitrary sites out of the signed-in panel.
    nonisolated static func opensInPanel(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        let domains = ["youtube.com", "youtu.be", "google.com", "youtube-nocookie.com"]
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        guard ["https", "about"].contains(url.scheme ?? "") else {
            status = "Unsupported navigation was not opened"; decisionHandler(.cancel); return
        }
        // Embedded frames (players, sign-in widgets, ads) load as the page
        // needs; only whole-page navigations are kept to YouTube and Google.
        if url.scheme == "https", navigationAction.targetFrame?.isMainFrame ?? true, !Self.opensInPanel(url) {
            NSWorkspace.shared.open(url)
            status = "Opened \(url.host ?? "link") in your browser"
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // Pop-ups: YouTube's own stay in the panel, anything else goes to the
        // browser rather than replacing the video you're watching.
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url, url.scheme == "https" {
            if Self.opensInPanel(url) {
                navigate(url)
            } else {
                NSWorkspace.shared.open(url); status = "Opened \(url.host ?? "link") in your browser"
            }
        }
        return nil
    }

    // MARK: Recovery

    private var recentCrashes: [Date] = []
    /// WebKit's content process can be killed (memory pressure, long sleep).
    /// Without this the panel stays blank until Reload; reload automatically,
    /// but stop after repeated crashes so a broken page can't loop.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        layoutGeneration += 1
        fillsVideoArea = false
        let now = Date()
        recentCrashes = recentCrashes.filter { now.timeIntervalSince($0) < 120 } + [now]
        guard recentCrashes.count <= 2 else {
            status = "YouTube stopped repeatedly. Tap Reload to try again."
            return
        }
        status = "YouTube stopped unexpectedly · reloading"
        if webView.url != nil { webView.reload() } else if hasLoaded { loadHome() }
    }

    // MARK: Page dialogs

    func webView(
        _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "YouTube"
        alert.informativeText = message
        guard let window = webView.window, window.attachedSheet == nil else { completionHandler(); return }
        alert.beginSheetModal(for: window) { _ in completionHandler() }
    }
    func webView(
        _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "YouTube"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        guard let window = webView.window, window.attachedSheet == nil else { completionHandler(false); return }
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }
}

/// The session's web view outlives any one host: a tile on the grid and its
/// expanded (focus) copy take turns showing it. Each host is a plain container
/// that claims the web view when it is created or updated, so whichever host
/// is current shows the page however SwiftUI orders the swap.
struct YouTubeBrowserView: NSViewRepresentable {
    let model: YouTubeBrowserModel
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        claim(into: container)
        return container
    }
    func updateNSView(_ container: NSView, context: Context) { claim(into: container) }
    private func claim(into container: NSView) {
        let web = model.webView
        guard web.superview !== container else { return }
        web.removeFromSuperview()
        web.frame = container.bounds
        web.autoresizingMask = [.width, .height]
        container.addSubview(web)
    }
}
