import AppKit

struct LauncherItem: Codable, Equatable {
    let path: String
    let bundleIdentifier: String?
    let name: String

    @MainActor static func application(at url: URL) -> LauncherItem? {
        // Finder aliases and symbolic links to apps resolve to the app itself.
        let url = url.isFileURL ? ((try? URL(resolvingAliasFileAt: url)) ?? url) : url
        guard url.isFileURL, url.pathExtension.lowercased() == "app",
            let bundle = Bundle(url: url), bundle.executableURL != nil,
            FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return LauncherItem(
            path: url.path, bundleIdentifier: bundle.bundleIdentifier,
            name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
    }

    @MainActor func resolvedURL() -> URL? {
        let original = URL(fileURLWithPath: path)
        if let current = Self.application(at: original),
            bundleIdentifier == nil || current.bundleIdentifier == bundleIdentifier
        {
            return original
        }
        guard let bundleIdentifier,
            let moved = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
            Self.application(at: moved) != nil
        else { return nil }
        return moved
    }

    static func decode(_ value: String) -> [LauncherItem?] {
        decodeIfValid(value) ?? []
    }
    /// nil when a non-empty saved list can't be read, so the caller can keep
    /// the original text rather than overwrite it with the next change.
    static func decodeIfValid(_ value: String) -> [LauncherItem?]? {
        if value.isEmpty { return [] }
        return try? JSONDecoder().decode([LauncherItem?].self, from: Data(value.utf8))
    }
    static func encode(_ items: [LauncherItem?]) -> String {
        guard let data = try? JSONEncoder().encode(items) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}

struct LauncherGrid {
    let columns: Int
    let rows: Int
    var capacity: Int { columns * rows }
    init(size: CGSize) {
        columns = max(1, Int(((size.width - 24) / 112).rounded()))
        rows = max(1, Int(((size.height - 56) / 100).rounded()))
    }
    func pageCount(itemCount: Int) -> Int { max(1, (itemCount + capacity - 1) / capacity) }
}
