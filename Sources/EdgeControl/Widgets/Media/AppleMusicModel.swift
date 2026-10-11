import AppKit
import Combine
@preconcurrency import MusicKit

/// One native queue per app. Multiple tiles reflect the same playback session.
@MainActor final class AppleMusicModel: ObservableObject {
    enum SearchScope: String { case albums, songs, playlists }
    static let shared = AppleMusicModel()
    @Published private(set) var scope: SearchScope = .albums
    @Published private(set) var albums: [Album] = []
    @Published private(set) var selectedAlbum: Album?
    @Published private(set) var albumTracks: [Track] = []
    private var albumResultsPage = 0
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var selectedPlaylist: Playlist?
    @Published private(set) var playlistEntries: [Playlist.Entry] = []
    var viewingCollection: Bool { selectedAlbum != nil || selectedPlaylist != nil }
    var collectionTitle: String { selectedPlaylist?.name ?? selectedAlbum?.title ?? "" }
    var collectionSubtitle: String { selectedPlaylist?.curatorName ?? selectedAlbum?.artistName ?? "Your library" }
    @Published private(set) var authorized = false
    @Published private(set) var busy = false
    @Published private(set) var playing = false
    @Published private(set) var songs: [Song] = []
    @Published private(set) var status = "Connect your Apple Music account to browse and listen."
    @Published private(set) var title = "Your music, within reach"
    @Published private(set) var artist = "Apple Music"
    @Published private(set) var artwork: NSImage?
    @Published private(set) var album = ""
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var hasQueue = false
    @Published private(set) var library = false
    @Published var page = 0
    @Published private(set) var pageSize = 4
    @Published var showingNowPlaying = false
    private var operation: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var artworkURL: URL?
    private var generation = 0
    private var timer: AnyCancellable?
    private var visibleTiles: Set<UUID> = []
    private var player: ApplicationMusicPlayer { .shared }
    var visibleSongs: ArraySlice<Song> { songs.dropFirst(page * pageSize).prefix(pageSize) }
    var resultCount: Int {
        if selectedPlaylist != nil { return playlistEntries.count }
        if selectedAlbum != nil { return albumTracks.count }
        switch scope {
        case .albums: return albums.count;
        case .songs: return songs.count;
        case .playlists: return playlists.count
        }
    }
    var pageCount: Int { max(1, (resultCount + pageSize - 1) / pageSize) }
    var resultsHeading: String {
        if let selectedPlaylist { return "\(selectedPlaylist.name) · \(playlistEntries.count) tracks" }
        if let selectedAlbum { return "\(selectedAlbum.title) · \(albumTracks.count) tracks" }
        return "\(library ? "Library" : "Catalog") \(scope.rawValue)"
    }

    init(songs: [Song] = [], albums: [Album] = [], playlists: [Playlist] = []) {
        self.songs = songs; self.albums = albums; self.playlists = playlists
        if !songs.isEmpty { scope = .songs }
    }
    /// Library-vs-catalog mode before Playlists (which is library-only), so
    /// leaving Playlists returns to the catalog search results you had.
    private var libraryBeforePlaylists = false
    func selectScope(_ value: SearchScope) {
        guard value != scope || viewingCollection else { return }
        let leavingPlaylists = scope == .playlists && value != .playlists
        if value == .playlists && scope != .playlists { libraryBeforePlaylists = library }
        scope = value; selectedAlbum = nil; albumTracks = []; selectedPlaylist = nil; playlistEntries = []; page = 0
        if value == .playlists { library = true; loadLibrary(); return }
        if leavingPlaylists { library = libraryBeforePlaylists }
        if library { loadLibrary() }
    }
    func resultTitle(at index: Int) -> String {
        let offset = page * pageSize + index
        guard offset >= 0, offset < resultCount else { return "" }
        if selectedPlaylist != nil {
            let entry = playlistEntries[offset]
            return "\(offset + 1). \(entry.title) — \(entry.artistName)"
        }
        if scope == .playlists { return "Playlist · \(playlists[offset].name)" }
        if selectedAlbum != nil {
            let track = albumTracks[offset]
            return "\(offset + 1). \(track.title)"
        }
        if scope == .albums {
            let album = albums[offset]
            return "Album · \(album.title) — \(album.artistName) · \(album.trackCount) tracks"
        }
        let song = songs[offset]
        return "Song · \(song.title) — \(song.artistName)"
    }
    func selectResult(at index: Int) {
        let offset = page * pageSize + index
        guard offset >= 0, offset < resultCount else { return }
        if selectedPlaylist != nil {
            playPlaylist(startingAt: playlistEntries[offset])
        } else if scope == .playlists {
            openPlaylist(playlists[offset])
        } else if selectedAlbum != nil {
            playAlbum(startingAt: albumTracks[offset])
        } else if scope == .albums {
            openAlbum(albums[offset])
        } else {
            play(songs[offset])
        }
    }
    func backToAlbums() {
        operation?.cancel(); generation += 1; busy = false
        selectedAlbum = nil; albumTracks = []; selectedPlaylist = nil; playlistEntries = [];
        page = min(albumResultsPage, max(0, (resultCount - 1) / pageSize))
    }
    func openAlbum(_ album: Album) {
        guard authorized, !busy else { return }
        run { [self] in
            let loaded = try await album.with([.tracks])
            var batch = loaded.tracks
            var tracks = Array(batch ?? [])
            while batch?.hasNextBatch == true {
                try Task.checkCancellation()
                batch = try await batch?.nextBatch()
                tracks.append(contentsOf: batch ?? [])
            }
            try Task.checkCancellation()
            displayAlbum(loaded, tracks: tracks)
        }
    }
    func displayAlbum(_ album: Album, tracks: [Track]) {
        albumResultsPage = page; page = 0
        selectedAlbum = album; albumTracks = tracks
        status =
            tracks.isEmpty
            ? "No playable tracks are available for this album."
            : "\(album.title) · \(album.artistName) · \(tracks.count) tracks"
    }
    func playAlbum(startingAt track: Track? = nil) {
        guard authorized, !busy, let selectedAlbum, !albumTracks.isEmpty else { return }
        run { [self] in
            let subscription = try await MusicSubscription.current
            try Task.checkCancellation()
            guard subscription.canPlayCatalogContent else {
                status = "An active Apple Music subscription is needed."; return
            }
            // The album queue preserves album order, independent of search ranking.
            if let track {
                player.queue = ApplicationMusicPlayer.Queue(album: selectedAlbum, startingAt: track)
            } else {
                player.queue = ApplicationMusicPlayer.Queue(for: [selectedAlbum])
            }
            player.state.shuffleMode = .off
            try await player.play()
            if Task.isCancelled || visibleTiles.isEmpty { player.pause(); return }
            showingNowPlaying = true
            status = "Playing album: \(selectedAlbum.title)"
            refresh()
        }
    }

    func openPlaylist(_ playlist: Playlist) {
        guard authorized, !busy else { return }
        run { [self] in
            let loaded = try await playlist.with([.entries])
            var batch = loaded.entries
            var entries = Array(batch ?? [])
            while batch?.hasNextBatch == true {
                try Task.checkCancellation()
                batch = try await batch?.nextBatch()
                entries.append(contentsOf: batch ?? [])
            }
            try Task.checkCancellation()
            displayPlaylist(loaded, entries: entries)
        }
    }
    func displayPlaylist(_ playlist: Playlist, entries: [Playlist.Entry]) {
        albumResultsPage = page; page = 0
        selectedAlbum = nil; albumTracks = []
        selectedPlaylist = playlist; playlistEntries = entries
        status =
            entries.isEmpty ? "This playlist has no available tracks." : "\(playlist.name) · \(entries.count) tracks"
    }
    func playPlaylist(startingAt entry: Playlist.Entry? = nil) {
        guard authorized, !busy, let selectedPlaylist, !playlistEntries.isEmpty else { return }
        run { [self] in
            let subscription = try await MusicSubscription.current
            try Task.checkCancellation()
            guard subscription.canPlayCatalogContent else {
                status = "An active Apple Music subscription is needed."; return
            }
            if let entry {
                player.queue = ApplicationMusicPlayer.Queue(playlist: selectedPlaylist, startingAt: entry)
            } else {
                player.queue = ApplicationMusicPlayer.Queue(for: [selectedPlaylist])
            }
            player.state.shuffleMode = .off
            try await player.play()
            if Task.isCancelled || visibleTiles.isEmpty { player.pause(); return }
            showingNowPlaying = true
            status = "Playing playlist: \(selectedPlaylist.name)"
            refresh()
        }
    }

    func setVisible(_ id: UUID, _ visible: Bool) {
        if visible { visibleTiles.insert(id) } else { visibleTiles.remove(id) }
        if visibleTiles.isEmpty {
            // Expanding or collapsing a tile removes one host just before the
            // other appears; pause only if no tile shows up.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, self.visibleTiles.isEmpty else { return }
                self.pause()
                self.timer = nil
            }
        } else if timer == nil {
            refresh()
            timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
    }
    func connect() {
        run { [self] in
            let result = await MusicAuthorization.request()
            authorized = result == .authorized
            guard authorized else {
                status =
                    "Music access is off. Allow EdgeControl in System Settings → Privacy & Security → Media & Apple Music."
                return
            }
            status = "Connected. Search Apple Music or open Library."
            refresh()
        }
    }
    func search(_ text: String) {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard authorized, !term.isEmpty else { return }
        if scope == .playlists { loadLibrary(playlistQuery: term); return }
        run { [self] in
            var request = MusicCatalogSearchRequest(term: term, types: [Song.self, Album.self])
            request.limit = 25
            let results = try await request.response()
            try Task.checkCancellation()
            songs = Array(results.songs); albums = Array(results.albums)
            selectedAlbum = nil; albumTracks = []; selectedPlaylist = nil; playlistEntries = []; page = 0;
            library = false
            status = "\(albums.count) albums · \(songs.count) songs. Choose Albums or Songs above."
        }
    }
    func loadLibrary(playlistQuery: String? = nil) {
        guard authorized else { return }
        run { [self] in
            if scope == .playlists {
                var request = MusicLibraryRequest<Playlist>()
                request.limit = 100
                request.sort(by: \.name, ascending: true)
                if let playlistQuery { request.filter(text: playlistQuery) }
                var loaded: [Playlist] = []
                var seen = Set<MusicItemID>()
                // Pages of 100 until a short page. Bounded, and stops if a page
                // repeats items (an ignored offset would otherwise loop forever).
                for _ in 0..<100 {
                    let results = try await request.response()
                    try Task.checkCancellation()
                    let fresh = results.items.filter { seen.insert($0.id).inserted }
                    loaded.append(contentsOf: fresh)
                    if results.items.count < 100 || fresh.isEmpty { break }
                    request.offset += results.items.count
                }
                playlists = loaded
            } else if scope == .albums {
                var request = MusicLibraryRequest<Album>()
                request.limit = 100; request.sort(by: \.title, ascending: true)
                let results = try await request.response()
                try Task.checkCancellation()
                albums = Array(results.items)
            } else {
                var request = MusicLibraryRequest<Song>()
                request.limit = 100; request.sort(by: \.title, ascending: true)
                let results = try await request.response()
                try Task.checkCancellation()
                songs = Array(results.items)
            }
            selectedAlbum = nil; albumTracks = []; selectedPlaylist = nil; playlistEntries = []; page = 0;
            library = true
            status =
                resultCount == 0
                ? (scope == .playlists
                    ? "No playlists found in your Music library." : "Nothing here yet. Try searching the catalog.")
                : "\(resultCount) library \(scope.rawValue)\(scope != .playlists && resultCount == 100 ? " (first 100)" : "")"
        }
    }
    func play(_ song: Song) {
        guard authorized, !busy else { return }
        run { [self] in
            let subscription = try await MusicSubscription.current
            try Task.checkCancellation()
            guard subscription.canPlayCatalogContent else {
                status = "An active Apple Music subscription is needed. Check your account in the Music app."
                return
            }
            player.queue = ApplicationMusicPlayer.Queue(for: songs, startingAt: song)
            try await player.play()
            if Task.isCancelled || visibleTiles.isEmpty { player.pause(); return }
            showingNowPlaying = true
            status = "Playing a song · \(library ? "library songs" : "search results") queue"
            refresh()
        }
    }
    func togglePlayback() {
        guard authorized, hasQueue else { return }
        if playing {
            pause()
        } else {
            run { [self] in
                try await player.play()
                if Task.isCancelled || visibleTiles.isEmpty { player.pause(); return }
                refresh()
            }
        }
    }
    func skip(_ next: Bool) {
        guard authorized, hasQueue, !busy else { return }
        run { [self] in
            if next { try await player.skipToNextEntry() } else { try await player.skipToPreviousEntry() }
            if Task.isCancelled || visibleTiles.isEmpty { player.pause(); return }
            refresh()
        }
    }
    func pause() {
        generation += 1
        operation?.cancel(); operation = nil; busy = false
        guard authorized else { return }
        player.pause(); playing = false
    }
    func setPageSize(_ value: Int) {
        let value = min(10, max(4, value))
        guard value != pageSize else { return }
        let offset = page * pageSize
        let albumOffset = albumResultsPage * pageSize
        pageSize = value
        page = min(offset / value, pageCount - 1)
        albumResultsPage = albumOffset / value
    }
    /// Rows each visible panel can show. Browsing state is shared, so the
    /// shared page size is the smallest capacity: every tile fits its rows,
    /// and differently sized tiles no longer take turns overriding it.
    private var capacities: [UUID: Int] = [:]
    func setCapacity(_ panel: UUID, _ rows: Int) {
        guard capacities[panel] != rows else { return }
        capacities[panel] = rows
        applyCapacities()
    }
    func removeCapacity(_ panel: UUID) {
        guard capacities.removeValue(forKey: panel) != nil else { return }
        applyCapacities()
    }
    private func applyCapacities() {
        if let smallest = capacities.values.min() { setPageSize(smallest) }
    }
    func movePage(_ delta: Int) { page = min(max(0, page + delta), pageCount - 1) }
    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        operation?.cancel(); generation += 1
        let current = generation
        busy = true
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if generation == current { busy = false; operation = nil } }
            do { try await work() } catch is CancellationError {} catch {
                guard generation == current else { return }
                if let apiError = error as? MusicDataRequest.Error {
                    status = "Apple Music: \(apiError.title). \(apiError.detailText)"
                } else {
                    status = "Apple Music couldn’t complete this request. \(error.localizedDescription)"
                }
            }
        }
    }
    private func refresh() {
        let wasAuthorized = authorized
        authorized = MusicAuthorization.currentStatus == .authorized
        guard authorized else {
            if wasAuthorized {
                pause()
                player.pause()
                hasQueue = false; playing = false; artwork = nil; showingNowPlaying = false
                artworkTask?.cancel(); artworkURL = nil; songs = []; albums = []; playlists = [];
                selectedPlaylist = nil; playlistEntries = []; selectedAlbum = nil; albumTracks = []; page = 0
                title = "Music access is off"
                artist = "Connect Apple Music to continue"
                status = "Allow EdgeControl in System Settings → Privacy & Security → Media & Apple Music."
            }
            return
        }
        if !wasAuthorized { status = "Connected. Search Apple Music or open Library." }
        let entry = player.queue.currentEntry
        hasQueue = entry != nil
        playing = player.state.playbackStatus == .playing
        elapsed = player.playbackTime
        title = entry?.title ?? "Choose something you love"
        artist = entry?.subtitle ?? "Search Apple Music or browse your library"
        if case .song(let song) = entry?.item {
            album = song.albumTitle.map { "From album: \($0)" } ?? "Song"
        } else {
            album = ""
        }
        let url = entry?.artwork?.url(width: 400, height: 400)
        if url != artworkURL {
            artworkURL = url; artwork = nil; artworkTask?.cancel()
            if let url {
                artworkTask = Task { [weak self] in
                    guard let (data, _) = try? await URLSession.shared.data(from: url), !Task.isCancelled else {
                        return
                    }
                    self?.artwork = NSImage(data: data)
                }
            }
        }
    }
}
