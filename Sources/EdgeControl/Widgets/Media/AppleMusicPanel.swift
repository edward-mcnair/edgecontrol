import AppKit
import SwiftUI

/// Native buttons use the same frame-based HID routing as the YouTube toolbar.
struct AppleMusicPanel: NSViewRepresentable {
    let touchEnabled: Bool
    @ObservedObject var model: AppleMusicModel
    // The grid owns our size. AppKit's fitting width includes full song titles,
    // so allowing SwiftUI to use it makes the panel wider than its clipped tile.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AppleMusicPanelView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 480, height: proposal.height ?? 680)
    }
    func makeNSView(context: Context) -> AppleMusicPanelView { AppleMusicPanelView(model: model) }
    func updateNSView(_ view: AppleMusicPanelView, context: Context) {
        view.render()
        if touchEnabled {
            MediaTouchRouting.shared.registerToolbar(view.routingID, root: view, controls: view.controls)
        } else {
            MediaTouchRouting.shared.unregisterToolbar(view.routingID)
        }
    }
    static func dismantleNSView(_ view: AppleMusicPanelView, coordinator: ()) {
        MediaTouchRouting.shared.unregisterToolbar(view.routingID)
        view.model.removeCapacity(view.routingID)
    }
}

@MainActor final class AppleMusicPanelView: NSView {
    let routingID = UUID()
    let model: AppleMusicModel
    private var reportedCapacity: Int?
    private(set) var controls: [NSControl] = []
    private let search = NSTextField(string: "")
    private let art = NSImageView()
    private let track = NSTextField(labelWithString: "")
    private let artist = NSTextField(labelWithString: "")
    private let album = NSTextField(labelWithString: "")
    private var artworkWidth: NSLayoutConstraint!
    private var artworkHeight: NSLayoutConstraint!
    private let status = NSTextField(wrappingLabelWithString: "")
    private let elapsed = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private var connect: NSButton!
    private var library: NSButton!
    private var albumsButton: NSButton!
    private var songsButton: NSButton!
    private var playlistsButton: NSButton!
    private var backAlbums: NSButton!
    private var scopeLine: NSStackView!
    private var searchLine: NSStackView!
    private var albumActions: NSStackView!
    private let albumHeading = NSTextField(wrappingLabelWithString: "")
    private var playAlbum: NSButton!
    private var submit: NSButton!
    private var play: NSButton!
    private var previous: NSButton!
    private var next: NSButton!
    private var pageBack: NSButton!
    private var pageNext: NSButton!
    private var rows: [NSButton] = []
    private let browse = NSStackView()
    private let playerView = NSStackView()
    private var browseBack: NSButton!
    private var nowPlaying: NSButton!
    private let brand = NSTextField(labelWithString: "♫  Apple Music")

    init(model: AppleMusicModel) {
        self.model = model
        super.init(frame: .zero)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.045, alpha: 1).cgColor
        layer?.cornerRadius = 8
        let column = NSStackView()
        column.orientation = .vertical; column.spacing = 6; column.alignment = .leading
        addSubview(column); column.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
        func line(_ views: [NSView], spacing: CGFloat = 8, in destination: NSStackView? = nil) -> NSStackView {
            let destination = destination ?? column
            let line = NSStackView(views: views); line.orientation = .horizontal
            line.alignment = .centerY; line.spacing = spacing
            destination.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: destination.widthAnchor).isActive = true
            return line
        }
        func space() -> NSView {
            let v = NSView(); v.setContentHuggingPriority(.defaultLow, for: .horizontal); return v
        }
        brand.font = .systemFont(ofSize: 20, weight: .semibold)
        brand.textColor = .systemPink
        connect = button("Connect", "person.crop.circle", #selector(connectAccount), width: 110)
        browseBack = button("Browse", "chevron.left", #selector(returnToBrowse), width: 100)
        nowPlaying = button("Now Playing", "waveform", #selector(openPlayer), width: 140)
        _ = line([browseBack, brand, space(), connect, nowPlaying])
        for section in [playerView, browse] {
            section.orientation = .vertical; section.alignment = .leading; section.spacing = 8
            column.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        art.imageScaling = .scaleProportionallyUpOrDown
        art.wantsLayer = true; art.layer?.cornerRadius = 10; art.layer?.masksToBounds = true
        artworkWidth = art.widthAnchor.constraint(equalToConstant: 176)
        artworkHeight = art.heightAnchor.constraint(equalToConstant: 176)
        NSLayoutConstraint.activate([artworkWidth, artworkHeight])
        track.font = .systemFont(ofSize: 22, weight: .semibold)
        artist.font = .systemFont(ofSize: 15); artist.textColor = .secondaryLabelColor
        album.font = .systemFont(ofSize: 12); album.textColor = .secondaryLabelColor
        for text in [track, artist, album] {
            text.lineBreakMode = .byTruncatingTail
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let info = NSStackView(views: [track, artist, album, elapsed]); info.orientation = .vertical;
        info.alignment = .leading; info.spacing = 7
        for label in [track, artist, album, elapsed] {
            label.widthAnchor.constraint(lessThanOrEqualTo: info.widthAnchor).isActive = true
        }
        info.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        elapsed.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular);
        elapsed.textColor = .secondaryLabelColor
        let breathingRoom = NSView()
        breathingRoom.heightAnchor.constraint(equalToConstant: 28).isActive = true
        playerView.addArrangedSubview(breathingRoom)
        let artLeft = space(), artRight = space()
        _ = line([artLeft, art, artRight], in: playerView)
        artLeft.widthAnchor.constraint(equalTo: artRight.widthAnchor).isActive = true
        playerView.addArrangedSubview(info)
        info.widthAnchor.constraint(equalTo: playerView.widthAnchor).isActive = true
        for label in [track, artist, album, elapsed] { label.alignment = .center }
        info.alignment = .centerX
        previous = button("Previous track", "backward.end.fill", #selector(previousTrack))
        play = button("Play", "play.fill", #selector(toggle), width: 110)
        next = button("Next track", "forward.end.fill", #selector(nextTrack))
        library = button("Library", "music.note.list", #selector(openLibrary), width: 88)
        let transportLeft = space(), transportRight = space()
        _ = line([transportLeft, previous, play, next, transportRight], spacing: 12, in: playerView)
        transportLeft.widthAnchor.constraint(equalTo: transportRight.widthAnchor).isActive = true
        for control in [previous!, play!, next!] {
            control.constraints.first { $0.firstAttribute == .height }?.constant = 52
            control.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        }
        play.contentTintColor = .systemPink
        albumsButton = button("Albums", "square.stack", #selector(showAlbums), width: 90)
        songsButton = button("Songs", "music.note", #selector(showSongs), width: 80)
        playlistsButton = button("Playlists", "music.note.list", #selector(showPlaylists), width: 100)
        scopeLine = line([albumsButton, songsButton, playlistsButton, space(), library], in: browse)
        search.placeholderString = "Search albums, songs or artists"
        search.font = .systemFont(ofSize: 15); search.bezelStyle = .roundedBezel
        search.target = self; search.action = #selector(searchCatalog)
        search.setAccessibilityLabel("Search Apple Music")
        search.heightAnchor.constraint(equalToConstant: 44).isActive = true
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        search.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        controls.append(search)
        submit = button("Search", "magnifyingglass", #selector(searchCatalog), width: 100)
        searchLine = line([search, submit], in: browse)
        albumHeading.font = .systemFont(ofSize: 20, weight: .semibold)
        albumHeading.maximumNumberOfLines = 2
        browse.addArrangedSubview(albumHeading)
        albumHeading.widthAnchor.constraint(equalTo: browse.widthAnchor).isActive = true
        backAlbums = button("Albums", "chevron.left", #selector(returnToAlbums), width: 100)
        playAlbum = button("Play Album", "play.fill", #selector(startAlbum), width: 140)
        albumActions = line([backAlbums, space(), playAlbum], in: browse)
        for index in 0..<10 {
            let row = button("", "play.circle", #selector(selectSong), width: nil)
            row.tag = index; row.alignment = .left; row.font = .systemFont(ofSize: 14)
            row.lineBreakMode = .byTruncatingTail
            row.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            browse.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: browse.widthAnchor).isActive = true
            rows.append(row)
        }
        pageBack = button("Previous results", "chevron.left", #selector(backPage))
        pageNext = button("Next results", "chevron.right", #selector(nextPage))
        count.lineBreakMode = .byTruncatingTail
        count.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        count.font = .systemFont(ofSize: 12); count.textColor = .secondaryLabelColor
        _ = line([count, space(), pageBack, pageNext], in: browse)
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 2
        column.addArrangedSubview(status)
        status.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        let filler = NSView(); column.addArrangedSubview(filler)
        filler.setContentHuggingPriority(.defaultLow, for: .vertical)
        render()
    }
    override func layout() {
        let artworkSize = max(112, min(320, bounds.width - 48, bounds.height - 330))
        let capacity = min(10, max(4, Int((bounds.height - 285) / 52)))
        if capacity != reportedCapacity && !model.showingNowPlaying {
            reportedCapacity = capacity
            Task { @MainActor [weak self] in
                guard let self else { return }
                model.setCapacity(routingID, capacity)
                render()
            }
        }
        if artworkWidth?.constant != artworkSize {
            artworkWidth?.constant = artworkSize
            artworkHeight?.constant = artworkSize
        }
        super.layout()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func button(_ title: String, _ symbol: String, _ action: Selector, width: CGFloat? = 44) -> NSButton {
        let b = NSButton(title: width == 44 ? "" : title, target: self, action: action)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        b.imagePosition = width == 44 ? .imageOnly : .imageLeading
        b.bezelStyle = .regularSquare; b.font = .systemFont(ofSize: 14, weight: .medium)
        b.wantsLayer = true; b.layer?.cornerRadius = 8; b.layer?.masksToBounds = true
        b.toolTip = title; b.setAccessibilityLabel(title)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.heightAnchor.constraint(equalToConstant: 44).isActive = true
        if let width { b.widthAnchor.constraint(equalToConstant: width).isActive = true }
        controls.append(b); return b
    }
    func render() {
        let showPlayer = model.showingNowPlaying
        brand.stringValue = showPlayer ? "Now Playing" : "♫  Apple Music"
        brand.font = .systemFont(ofSize: showPlayer ? 16 : 20, weight: .semibold)
        brand.textColor = showPlayer ? .secondaryLabelColor : .systemPink
        needsLayout = true
        if showPlayer && !browse.isHidden { window?.makeFirstResponder(nil) }
        browse.isHidden = showPlayer
        playerView.isHidden = !showPlayer
        browseBack.isHidden = !showPlayer
        nowPlaying.isHidden = showPlayer || !model.hasQueue
        connect.isHidden = showPlayer || model.authorized
        connect.title = model.authorized ? "Connected" : "Connect"
        connect.isEnabled = !model.authorized && !model.busy
        library.isEnabled = model.authorized && !model.busy
        submit.isEnabled = model.authorized && !model.busy
        search.isEnabled = model.authorized
        play.isEnabled = model.hasQueue && !model.busy
        previous.isEnabled = model.hasQueue && !model.busy
        next.isEnabled = model.hasQueue && !model.busy
        play.title = model.playing ? "Pause" : "Play"
        play.setAccessibilityLabel(play.title)
        play.image = NSImage(
            systemSymbolName: model.playing ? "pause.fill" : "play.fill", accessibilityDescription: play.title)
        track.stringValue = model.title; artist.stringValue = model.artist
        album.stringValue = model.album
        album.toolTip = model.album
        art.image = model.artwork ?? NSImage(systemSymbolName: "music.note", accessibilityDescription: "Album artwork")
        art.contentTintColor = model.artwork == nil ? .systemPink : nil
        let seconds = model.elapsed.isFinite ? max(0, Int(model.elapsed)) : 0
        elapsed.stringValue =
            model.hasQueue
            ? String(format: "Song · %d:%02d · %@", seconds / 60, seconds % 60, model.playing ? "Playing" : "Paused")
            : ""
        status.stringValue = model.busy ? "Working with Apple Music…" : model.status
        let viewingAlbum = model.viewingCollection
        scopeLine.isHidden = viewingAlbum
        searchLine.isHidden = viewingAlbum
        albumActions.isHidden = !viewingAlbum
        albumHeading.isHidden = !viewingAlbum
        albumHeading.stringValue =
            model.viewingCollection ? "\(model.collectionTitle)\n\(model.collectionSubtitle)" : ""
        playAlbum.isEnabled = model.authorized && !model.busy && model.resultCount > 0
        playAlbum.title = model.selectedPlaylist != nil ? "Play Playlist" : "Play Album"
        playAlbum.setAccessibilityLabel(playAlbum.title)
        backAlbums.title = model.selectedPlaylist != nil ? "Playlists" : "Albums"
        backAlbums.setAccessibilityLabel("Back to " + backAlbums.title)
        search.placeholderString =
            model.scope == .playlists ? "Search your playlists" : "Search albums, songs or artists"
        playlistsButton.state = model.scope == .playlists ? .on : .off
        playlistsButton.contentTintColor = model.scope == .playlists ? .systemPink : .labelColor
        playlistsButton.isEnabled = !model.busy
        albumsButton.state = model.scope == .albums ? .on : .off
        songsButton.state = model.scope == .songs ? .on : .off
        albumsButton.contentTintColor = model.scope == .albums ? .systemPink : .labelColor
        songsButton.contentTintColor = model.scope == .songs ? .systemPink : .labelColor
        albumsButton.isEnabled = !model.busy
        songsButton.isEnabled = !model.busy
        for (index, row) in rows.enumerated() {
            let label = index < model.pageSize ? model.resultTitle(at: index) : ""
            row.isHidden = label.isEmpty
            row.isEnabled = model.authorized && !label.isEmpty && !model.busy
            row.title = label
            let symbol =
                !viewingAlbum && model.scope == .playlists
                ? "music.note.list" : (!viewingAlbum && model.scope == .albums ? "square.stack" : "play.circle")
            row.image = label.isEmpty ? nil : NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            row.setAccessibilityLabel(label.isEmpty ? "No result" : label)
            row.toolTip = label
        }
        count.stringValue =
            model.resultCount == 0
            ? "Search or open Library to choose music"
            : "\(model.resultsHeading) · \(model.page + 1) / \(model.pageCount)"
        pageBack.isEnabled = model.page > 0 && !model.busy
        pageNext.isEnabled = model.page + 1 < model.pageCount && !model.busy
    }
    @objc private func returnToBrowse() { model.showingNowPlaying = false; render() }
    @objc private func openPlayer() { model.showingNowPlaying = true; render() }
    @objc private func showAlbums() { model.selectScope(.albums); render() }
    @objc private func showPlaylists() { model.selectScope(.playlists); render() }
    @objc private func showSongs() { model.selectScope(.songs); render() }
    @objc private func returnToAlbums() { model.backToAlbums() }
    @objc private func startAlbum() {
        if model.selectedPlaylist != nil { model.playPlaylist() } else { model.playAlbum() }
    }
    @objc private func connectAccount() { model.connect() }
    @objc private func openLibrary() { model.loadLibrary() }
    @objc private func searchCatalog() { model.search(search.stringValue) }
    @objc private func toggle() { model.togglePlayback() }
    @objc private func previousTrack() { model.skip(false) }
    @objc private func nextTrack() { model.skip(true) }
    @objc private func backPage() { model.movePage(-1) }
    @objc private func nextPage() { model.movePage(1) }
    @objc private func selectSong(_ sender: NSButton) {
        model.selectResult(at: sender.tag)
    }
}
