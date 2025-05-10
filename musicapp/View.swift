import AVFoundation
import Combine
import MediaPlayer
import SwiftUI
import os

struct SearchBar: View {
    @Binding var text: String

    @State private var isEditing = false
    @State private var textSubject = PassthroughSubject<String, Never>()

    var onChange: ((String) -> Void)
    let placeholder: String
    let debounceSeconds: Double

    var body: some View {
        HStack {
            TextField(placeholder, text: $text)
                .padding(8)
                .padding(.horizontal, 25)
                .background(Color(.systemGray6))
                .cornerRadius(8)
                .overlay(
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.gray)
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 8)
                        if !text.isEmpty {
                            Button(action: {
                                self.text = ""
                            }) {
                                Image(systemName: "multiply.circle.fill")
                                    .foregroundColor(.gray)
                                    .padding(.trailing, 8)
                            }
                        }
                    }
                )
                .onTapGesture {
                    self.isEditing = true
                }
                .onChange(of: text) {
                    textSubject.send(text)
                }
        }
        .onReceive(textSubject.debounce(for: .seconds(debounceSeconds), scheduler: RunLoop.main)) {
            debouncedValue in
            onChange(debouncedValue)
        }
    }
}

class TabState: ObservableObject {
    @Published var selectedTab: Int = 0
}

struct CustomTabView: View {
    @Binding var selection: Int
    let tabs: [TabItem]

    init(selection: Binding<Int>, @TabItemBuilder content: () -> [TabItem]) {
        self._selection = selection
        self.tabs = content()
    }

    var body: some View {
        ZStack {
            ForEach(tabs.indices, id: \.self) { index in
                tabs[index].content
                    .opacity(selection == index ? 1 : 0)
                    .animation(nil, value: selection)

            }
        }
        .overlay(
            // Your custom tab bar remains the same…
            HStack {
                ForEach(tabs.indices, id: \.self) { index in
                    Button(action: {
                        selection = index
                    }) {
                        VStack(spacing: 4) {
                            Image(systemName: tabs[index].systemImage)
                                .font(.system(size: 22, weight: .semibold))
                            Text(tabs[index].label)
                                .font(.caption)
                        }
                        .foregroundColor(selection == index ? .accentColor : .gray)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.top)
            .frame(height: 60)
            .background(.thinMaterial),
            alignment: .bottom
        )
    }
}

// MARK: - Supporting Types

struct TabItem: Identifiable {
    let id = UUID()
    let label: String
    let systemImage: String
    let content: AnyView
    let tag: Int

    init<Content: View>(
        label: String, systemImage: String, tag: Int, @ViewBuilder content: () -> Content
    ) {
        self.label = label
        self.systemImage = systemImage
        self.tag = tag
        self.content = AnyView(content())
    }
}

protocol TabViewBuilder {
    var tabs: [TabItem] { get }
}

@resultBuilder
struct TabItemBuilder {
    static func buildBlock(_ components: TabItem...) -> [TabItem] {
        components
    }
}

// MARK: - TabViewBuilder Implementation

extension CustomTabView {
    struct TabViewContainer: View, TabViewBuilder {
        let tabs: [TabItem]

        var body: some View {
            EmptyView()
        }
    }

    static func buildBlock(_ components: TabItem...) -> TabViewContainer {
        return TabViewContainer(tabs: components)
    }
}

struct MainTabView: View {
    @EnvironmentObject private var dependencies: DependencyContainer
    @EnvironmentObject private var tabState: TabState
    @EnvironmentObject private var playerVM: PlayerViewModel
    @State private var isPlayerPresented = false
    @StateObject private var libraryNavigation = LibraryNavigation()

    var body: some View {
        ZStack(alignment: .bottom) {
            CustomTabView(selection: $tabState.selectedTab) {
                TabItem(label: "Library", systemImage: "books.vertical", tag: 0) {
                    LibraryView(dependencies: dependencies)
                        .environmentObject(libraryNavigation)
                }
                TabItem(label: "Sync", systemImage: "icloud.and.arrow.down", tag: 1) {
                    SyncView(dependencies: dependencies)
                }
            }
            .environmentObject(tabState)
            .accentColor(.cyan)

            MiniPlayerView {
                isPlayerPresented = true
            }
            .padding(.bottom, 60)
        }
        .fullScreenCover(isPresented: $isPlayerPresented) {
            PlayerView().environmentObject(playerVM)
        }
    }
}

// MARK: - SongRow View
struct SongRow: View {
    @EnvironmentObject private var playerVM: PlayerViewModel

    let song: Song
    let onPlay: () -> Void

    var onDelete: (() -> Void)? = nil
    var onAddToPlaylist: (() -> Void)? = nil
    var onEditMetadata: (() -> Void)? = nil
    var onAddToQueue: (() -> Void)? = nil

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(song.title)
                    .font(.headline)
                Text(song.artist)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if song.id == playerVM.currentSong?.id && playerVM.isPlaying {
                // This icon serves as a playing indicator.
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundColor(.green)
            }
        }
        .contentShape(Rectangle())  // Make the whole row tappable
        .onTapGesture {
            onPlay()
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Add to Queue") {
                onAddToQueue?()
            }
            Button("Delete Song", role: .destructive) {
                onDelete?()
            }
            Button("Add to Playlist") {
                onAddToPlaylist?()
            }
            Button("Edit Metadata") {
                onEditMetadata?()
            }
        }
    }
}

struct SongMetadataEditorView: View {
    @Environment(\.dismiss) var dismiss
    let song: Song
    let songRepo: SongRepository
    @State private var title: String
    @State private var artist: String
    @State private var album: String
    @State private var albumArtist: String
    @State private var releaseYear: String
    @State private var discNumber: String
    @State private var trackNumber: String

    private let logger = Logger(subsystem: subsystem, category: "SongMetadataEditorView")

    init(song: Song, songRepo: SongRepository) {
        self.song = song
        self.songRepo = songRepo
        _title = State(initialValue: song.title)
        _artist = State(initialValue: song.artist)
        _album = State(initialValue: song.album)
        _albumArtist = State(initialValue: song.albumArtist)
        _releaseYear = State(initialValue: song.releaseYear != nil ? "\(song.releaseYear!)" : "")
        _discNumber = State(initialValue: song.discNumber != nil ? "\(song.discNumber!)" : "")
        _trackNumber = State(initialValue: song.trackNumber != nil ? "\(song.trackNumber!)" : "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Basic Info")) {
                    TextField("Title", text: $title)
                    TextField("Artist", text: $artist)
                    TextField("Album", text: $album)
                    TextField("Album Artist", text: $albumArtist)
                }
                Section(header: Text("Additional Info")) {
                    TextField("Release Year", text: $releaseYear)
                        .keyboardType(.numberPad)
                    TextField("Disc Number", text: $discNumber)
                        .keyboardType(.numberPad)
                    TextField("Track Number", text: $trackNumber)
                        .keyboardType(.numberPad)
                }
            }
            .navigationTitle("Edit Metadata")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            let updatedSong = Song(
                                id: song.id,
                                songKey: song.songKey,
                                artist: artist,
                                title: title,
                                album: album,
                                albumArtist: albumArtist,
                                releaseYear: Int(releaseYear),
                                discNumber: Int(discNumber),
                                trackNumber: Int(trackNumber),
                                coverArtPath: song.coverArtPath,
                                bookmark: song.bookmark,
                                pathHash: song.pathHash,
                                createdAt: song.createdAt,
                                updatedAt: Date(),
                                localFilePath: song.localFilePath,
                                fileState: song.fileState
                            )
                            do {
                                _ = try await songRepo.upsertSong(updatedSong)
                                NotificationCenter.default.post(
                                    name: Notification.Name("SongListRefresh"), object: nil)
                                dismiss()
                            } catch {
                                logger.error("failed to upsert: \(error)")
                            }
                        }
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Updated SongListViewModel
@MainActor
class SongListViewModel: ObservableObject {
    enum Filter {
        case all
        case artist(String)
        case album(String, artist: String?)
    }

    private let filter: Filter
    private let songRepo: SongRepository
    @Published var songs: [Song] = []
    @Published var totalSongs: Int = 0
    @Published var isLoadingPage: Bool = false

    private var currentPage: Int = 0
    private let pageSize: Int = 50
    private var hasMorePages: Bool = true
    private var currentQuery: String = ""

    private let logger = Logger(
        subsystem: "com.snowbear.musicapp",
        category: "SongListViewModel")

    init(songRepo: SongRepository, filter: Filter) {
        self.songRepo = songRepo
        self.filter = filter
    }

    func reset() {
        currentPage = 0
        songs = []
        hasMorePages = true
    }

    private func loadFilteredSongs() async throws -> [Song] {
        switch filter {
        case .all:
            return try await songRepo.searchSongsFTS(
                query: currentQuery,
                limit: pageSize,
                offset: currentPage * pageSize
            )

        case .artist(let artist):
            let artistFilter = "artist:\"\(artist)\""
            let combinedQuery =
                currentQuery.isEmpty ? artistFilter : "\(currentQuery) \(artistFilter)"
            return try await songRepo.searchSongsFTS(
                query: combinedQuery,
                limit: pageSize,
                offset: currentPage * pageSize
            )

        case .album(let album, _):
            let albumFilter = "album:\"\(album)\""
            let artistFilter = ""

            let combinedQuery: String
            if currentQuery.isEmpty {
                combinedQuery = [albumFilter, artistFilter].filter { !$0.isEmpty }.joined(
                    separator: " ")
            } else {
                combinedQuery = "\(currentQuery) \(albumFilter) \(artistFilter)"
            }

            let cleanedQuery =
                combinedQuery
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
                .joined(separator: " ")

            logger.debug("Album query: \(cleanedQuery)")

            var results = try await songRepo.searchSongsFTS(
                query: cleanedQuery,
                limit: pageSize,
                offset: currentPage * pageSize
            )

            if !results.isEmpty {
                results.sort {
                    if $0.trackNumber == $1.trackNumber {
                        return $0.artist.count < $1.artist.count
                    }
                    return ($0.trackNumber ?? Int.max) < ($1.trackNumber ?? Int.max)
                }
            }
            logger.debug("Returning \(results.count) songs for album \(album)")
            return results

        }
    }

    private func loadTotalSongs() async {
        do {
            let count = try await songRepo.totalSongCount(query: currentQuery)
            totalSongs = count
            logger.debug("Total songs loaded: \(count)")
        } catch {
            logger.error("Failed to load total song count: \(error.localizedDescription)")
            totalSongs = 0
        }
    }

    func loadMoreIfNeeded(currentSong song: Song) {
        if let index = songs.firstIndex(where: { $0.id == song.id }), index >= songs.count - 5 {
            Task { await loadMoreSongs() }
        }
    }

    func loadMoreSongs() async {
        guard !isLoadingPage && hasMorePages else { return }
        isLoadingPage = true
        defer { isLoadingPage = false }

        do {
            let newSongs = try await loadFilteredSongs()
            let received = newSongs.count

            hasMorePages = received >= pageSize

            if case .album = filter {
                logger.debug("need to load \(newSongs.count) songs and sort them")
                songs.append(contentsOf: newSongs)
                songs.sort { (s1, s2) in
                    if let t1 = s1.trackNumber, let t2 = s2.trackNumber {
                        return t1 < t2
                    }
                    return s1.title.localizedStandardCompare(s2.title) == .orderedAscending
                }
            } else {
                songs.append(contentsOf: newSongs)
            }

            if received > 0 {
                currentPage += 1
            }
        } catch {
            logger.error("Error loading more songs: \(error.localizedDescription)")
            hasMorePages = false
        }
    }

    func searchSongs(query: String) async {
        currentQuery = query
        reset()
        await loadTotalSongs()

        do {
            let newSongs = try await loadFilteredSongs()
            if case .album = filter {
                songs = newSongs.sorted { (s1, s2) in
                    if let t1 = s1.trackNumber, let t2 = s2.trackNumber {
                        return t1 < t2
                    }
                    return s1.title.localizedStandardCompare(s2.title) == .orderedAscending
                }
            } else {
                songs = newSongs
            }
            if newSongs.count < pageSize {
                hasMorePages = false
            } else {
                currentPage = 1
            }
            hasMorePages = newSongs.count >= pageSize
        } catch {
            logger.error("Search error: \(error.localizedDescription)")
        }
    }

    func loadInitialSongs() async {
        reset()
        do {
            let initialSongs = try await loadFilteredSongs()
            songs = initialSongs  // Overwrite the array
            if case .album = filter {
                songs = initialSongs.sorted { (s1, s2) in
                    if let t1 = s1.trackNumber, let t2 = s2.trackNumber {
                        return t1 < t2
                    }
                    return s1.title.localizedStandardCompare(s2.title) == .orderedAscending
                }
            } else {
                songs = initialSongs
            }
            if initialSongs.count == pageSize {
                hasMorePages = true
                currentPage = 1
            }
            hasMorePages = initialSongs.count >= pageSize
            await loadTotalSongs()
        } catch {
            logger.error("Initial load error: \(error.localizedDescription)")
            hasMorePages = false
        }
    }
}

// MARK: - Updated SongListView with Player Integration & Persistent Search
struct SongListView: View {
    @EnvironmentObject private var tabState: TabState
    @EnvironmentObject private var dependencies: DependencyContainer

    @ObservedObject private var viewModel: SongListViewModel
    @State private var searchText: String = ""
    @State private var isPlayerPresented: Bool = false
    @EnvironmentObject private var playerVM: PlayerViewModel
    @State private var songToEdit: Song? = nil

    @State private var showingPlaylistSelection = false
    @State private var songForPlaylist: Song? = nil

    private let logger = Logger(subsystem: subsystem, category: "SongListView")

    init(viewModel: SongListViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        return VStack {
            SearchBar(
                text: $searchText,
                onChange: { newValue in
                    Task { await viewModel.searchSongs(query: newValue) }
                },
                placeholder: "Search songs...",
                debounceSeconds: 0.3
            )
            .padding()

            Text("Total songs: \(viewModel.totalSongs)")
                .font(.caption)
                .padding(.horizontal)

            if viewModel.songs.isEmpty && !viewModel.isLoadingPage {
                emptyStateView
            } else {

                List {
                    ForEach(Array(viewModel.songs.enumerated()), id: \.element.uniqueId) {
                        index, song in
                        SongRow(
                            song: song,
                            onPlay: {
                                // Populate the player queue and play the tapped song
                                playerVM.configureQueue(
                                    songs: viewModel.songs, startIndex: index)
                                playerVM.playSong(song)
                            },
                            onDelete: {
                                Task {
                                    if let songId = song.id {
                                        try? await dependencies.songRepository.deleteSong(
                                            songId: songId)
                                        await viewModel.loadInitialSongs()
                                    }
                                }
                            },
                            onAddToPlaylist: {
                                songForPlaylist = song
                                showingPlaylistSelection = true
                            },
                            onEditMetadata: {
                                songToEdit = song
                            },
                            onAddToQueue: {
                                playerVM.addToQueue(song)
                            }
                        )
                        .onAppear {
                            viewModel.loadMoreIfNeeded(currentSong: song)
                        }
                    }
                    if viewModel.isLoadingPage {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    }
                }
                .listStyle(PlainListStyle())
            }
        }
        .onAppear {
            Task {
                if searchText.isEmpty {
                    await viewModel.loadInitialSongs()
                } else {
                    await viewModel.searchSongs(query: searchText)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("SongListRefresh")))
        { _ in
            Task { await viewModel.loadInitialSongs() }
        }
        .onDisappear {
            viewModel.reset()  // Clears the songs array and resets pagination.
        }
        .sheet(isPresented: $showingPlaylistSelection) {
            if let song = songForPlaylist {
                PlaylistSelectionView(
                    song: song,
                    songRepo: dependencies.songRepository,
                    playlistRepo: dependencies.playlistRepo,
                    playlistSongRepo: dependencies.playlistSongRepo
                )
            }
        }
        .sheet(item: $songToEdit) { song in
            SongMetadataEditorView(song: song, songRepo: dependencies.songRepository)
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "music.note.list")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No Songs Found")
                .font(.title2)

            Text(
                searchText.isEmpty
                    ? "Add a music source to get started"
                    : "No matches found for '\(searchText)'"
            )
            .multilineTextAlignment(.center)
            .foregroundColor(.secondary)

            if searchText.isEmpty {
                Button("Add Source") {
                    tabState.selectedTab = 1
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(maxHeight: .infinity)
    }
}

struct PlaylistSelectionView: View {
    let song: Song
    @StateObject private var viewModel: PlaylistListViewModel
    @Environment(\.dismiss) var dismiss

    init(
        song: Song, songRepo: SongRepository, playlistRepo: PlaylistRepository,
        playlistSongRepo: PlaylistSongRepository
    ) {
        self.song = song
        _viewModel = StateObject(
            wrappedValue: PlaylistListViewModel(
                playlistRepo: playlistRepo,
                playlistSongRepo: playlistSongRepo,
                songRepo: songRepo  // Assuming access to song repo
            )
        )
    }

    var body: some View {
        NavigationStack {
            List(viewModel.playlists) { playlist in
                Button(playlist.name) {
                    Task {
                        guard let playlistId = playlist.id, let songId = song.id else { return }
                        try? await viewModel.playlistSongRepo.addSong(
                            playlistId: playlistId,
                            songId: songId
                        )
                        dismiss()
                    }
                }
            }
            .navigationTitle("Select Playlist")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                Task { await viewModel.loadPlaylists() }
            }
        }
    }
}

struct MiniPlayerViewInner: View {
    let currentSong: Song?
    let onTap: (() -> Void)
    let playPauseAction: (() -> Void)
    let isPlaying: Bool

    var body: some View {
        if currentSong != nil {
            Button(action: {
                onTap()
            }) {
                HStack {
                    if let song = currentSong, let cover = coverArt(of: song) {
                        Image(uiImage: cover)
                            .resizable()
                            .frame(width: 50, height: 50)
                            .cornerRadius(5)
                    } else {
                        Image(systemName: "music.note")
                            .scaleEffect(1.6)
                            .frame(width: 50, height: 50)
                            .cornerRadius(5)
                    }

                    VStack(alignment: .leading) {
                        Text(currentSong?.title ?? "No Song")
                        Text(
                            "\(currentSong?.artist ?? "Unknown") - \(currentSong?.album ?? "")"
                        )
                        .font(Oxanium(14))
                        .foregroundColor(.secondary)

                    }
                    Spacer()
                    Button(action: playPauseAction) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 24))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(.trailing, 15)
                .background(Color(UIColor.secondarySystemBackground))
                .overlay(
                    Rectangle()
                        .frame(height: 0.2)  // Height for the top border
                        .foregroundColor(.secondary),
                    alignment: .top  // Align to top
                )
            }
            .buttonStyle(PlainButtonStyle())
        }
    }
}

struct MiniPlayerView: View {
    @EnvironmentObject private var playerVM: PlayerViewModel
    var onTap: () -> Void

    var body: some View {
        MiniPlayerViewInner(
            currentSong: playerVM.currentSong,
            onTap: onTap, playPauseAction: { playerVM.playPause() }, isPlaying: playerVM.isPlaying
        )
    }
}

func coverArt(of song: Song) -> UIImage? {
    guard let coverArtPath = song.coverArtPath else { return nil }
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    let coverURL = docs.appendingPathComponent(coverArtPath)
    return UIImage(contentsOfFile: coverURL.path)
}

struct SelectableSongRow: View {
    let song: Song
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(song.title)
                    .font(.headline)
                Text(song.artist)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isSelected ? .blue : .gray)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onToggle()
        }
        .padding(.vertical, 4)
    }
}

@MainActor
class PlayerViewModel: NSObject, ObservableObject, @preconcurrency AVAudioPlayerDelegate {
    @Published var currentSong: Song?
    @Published var isPlaying = false
    @Published var playbackProgress: Double = 0
    @Published var currentTime: String = "0:00"
    @Published var duration: String = "0:00"

    private var isShuffleEnabled: Bool = false
    private var originalQueue: [Song] = []
    private var isRepeatEnabled: Bool = false

    var queue: [Song] {
        return songs
    }

    private let songRepo: SongRepository?
    private let playlistRepo: PlaylistRepository
    private let playlistSongRepo: PlaylistSongRepository
    private let playerPersistenceService: PlayerPersistenceService?

    //    init(
    //        playerPersistenceService: PlayerPersistenceService, songRepo: SongRepository,
    //        playlistRepo: PlaylistRepository,
    //        playlistSongRepo: PlaylistSongRepository
    //    ) {
    //      self.playerPersistenceService = playerPersistenceService
    //      self.songRepo = songRepo
    //      super.init()
    //        setupAudioSession()
    //        setupRemoteCommands()
    //        setupInterruptionObserver()
    //
    //    }

    func reorderQueue(from source: IndexSet, to destination: Int) {
        songs.move(fromOffsets: source, toOffset: destination)
        if let currentSong = currentSong {
            currentIndex = songs.firstIndex { $0.id == currentSong.id } ?? 0
        }
        Task {
            await playerPersistenceService?.savePlaybackState(
                volume: volume, currentIndex: currentIndex, songs: songs)
        }
    }

    func createPlaylist(name: String) async throws {
        let newPlaylist = Playlist(id: nil, name: name, createdAt: Date(), updatedAt: nil)
        let createdPlaylist = try await playlistRepo.create(playlist: newPlaylist)
        guard let playlistId = createdPlaylist.id else { return }

        for song in songs {
            guard let songId = song.id else { continue }
            try await playlistSongRepo.addSong(playlistId: playlistId, songId: songId)
        }
    }

    @Published var volume: Float = 0.5 {  // default volume now 0.5
        didSet {
            player?.volume = volume
            Task {
                await playerPersistenceService?.savePlaybackState(
                    volume: volume, currentIndex: currentIndex, songs: songs)
            }
        }
    }

    init(
        playerPersistenceService: PlayerPersistenceService? = nil,
        songRepo: SongRepository? = nil,
        playlistRepo: PlaylistRepository,
        playlistSongRepo: PlaylistSongRepository
    ) {
        self.playerPersistenceService = playerPersistenceService
        self.songRepo = songRepo
        self.playlistRepo = playlistRepo
        self.playlistSongRepo = playlistSongRepo
        super.init()
        setupAudioSession()
        setupRemoteCommands()
        setupInterruptionObserver()

        Task {
            if let (songs, currentIndex, currentSong) = await self.playerPersistenceService?
                .restore()
            {
                self.songs = songs
                self.currentIndex = currentIndex
                self.currentSong = currentSong

                if let currentSong = currentSong {
                    stopAndPreloadSong(currentSong)
                }
            }

            if let stored = await self.playerPersistenceService?.getVolume() {
                self.volume = stored - 0.5
            }
        }
    }

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var songs: [Song] = []
    private var currentIndex: Int = 0

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        nextSong()
    }

    func addToQueue(_ song: Song) {
        songs.append(song)
        Task {
            await self.playerPersistenceService?.savePlaybackState(
                volume: self.volume,
                currentIndex: self.currentIndex,
                songs: self.songs
            )
        }
    }

    func configureQueue(songs: [Song], startIndex: Int) {
        self.songs = songs
        self.currentIndex = startIndex
        self.currentSong = songs[safe: startIndex]
        Task {
            await self.playerPersistenceService?.savePlaybackState(
                volume: self.volume, currentIndex: self.currentIndex, songs: self.songs)
        }
    }

    var logger = Logger(subsystem: subsystem, category: "PlayerViewModel")

    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            logger.error("audio session setup error: \(error)")
        }
    }

    private func setupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }

        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.playPause()
            return .success
        }

        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.nextSong()
            return .success
        }

        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.previousSong()
            return .success
        }
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let event = event as? MPChangePlaybackPositionCommandEvent {
                self?.seek(to: event.positionTime)
            }
            return .success
        }

        // Enable commands
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.isEnabled = true
    }

    func updateNowPlayingInfo() {
        guard let song = currentSong, let player = player else { return }

        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = song.title
        nowPlayingInfo[MPMediaItemPropertyArtist] = song.artist
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = song.album
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = player.duration
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? player.rate : 0.0

        if let artwork = coverArt(of: song) {
            let mpArtwork = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = mpArtwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    private func setupInterruptionObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }

    @objc private func handleInterruption(notification: Notification) {
        guard let info = notification.userInfo,
            let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        if type == .began {
            pause()
        } else if type == .ended {
            if let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    play()
                }
            }
        }
    }

    private func stopAndPreloadSong(_ song: Song) {
        stop()

        guard let url = resolveSongURL(song) else {
            logger.error("Can't load song URL.")
            return
        }

        guard url.startAccessingSecurityScopedResource() else {
            logger.error(
                "Failed to start accessing security scoped resource for song: \(song.title)")
            do {
                let newBookmark = try url.bookmarkData(options: [])
                logger.warning("Renewed bookmark for song: \(song.title)")
                var updatedSong = song
                updatedSong.bookmark = newBookmark
                Task {
                    _ = try await songRepo?.upsertSong(updatedSong)
                }
            } catch {
                logger.error("Failed to renew bookmark: \(error)")
            }
            return
        }
        activeSecurityScopedURLs.append(url)

        do {
            let audioPlayer = try AVAudioPlayer(contentsOf: url)
            player = audioPlayer
            player?.volume = volume
            currentSong = song
            player?.delegate = self
            updateTimeDisplay()
        } catch {
            logger.error("Player init error: \(error)")
            url.stopAccessingSecurityScopedResource()
            activeSecurityScopedURLs.removeAll { $0 == url }
        }
    }

    func playSong(_ song: Song) {
        stopAndPreloadSong(song)

        play()
        updateNowPlayingInfo()
    }

    func playPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    private func play() {
        player?.play()
        isPlaying = true
        startTimer()
        updateNowPlayingInfo()
    }

    private func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
        updateNowPlayingInfo()
    }
    private var activeSecurityScopedURLs = [URL]()
    func stop() {
        player?.stop()
        isPlaying = false
        playbackProgress = 0
        stopTimer()

        if let url = player?.url {
            url.stopAccessingSecurityScopedResource()
        }

        // Release all security scoped accesses
        activeSecurityScopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        activeSecurityScopedURLs.removeAll()
    }

    func previousSong() {
        guard !songs.isEmpty else { return }
        currentIndex = (currentIndex - 1 + songs.count) % songs.count
        playSong(songs[currentIndex])
        Task {
            await self.playerPersistenceService?.savePlaybackState(
                volume: self.volume, currentIndex: self.currentIndex, songs: self.songs)
        }
    }

    func nextSong() {
        guard !songs.isEmpty else { return }
        if currentIndex + 1 < songs.count {
            currentIndex += 1
            playSong(songs[currentIndex])
        } else {
            if isRepeatEnabled {
                currentIndex = 0
                playSong(songs[currentIndex])
            } else {
                stop()
            }
        }
        Task {
            await self.playerPersistenceService?.savePlaybackState(
                volume: self.volume, currentIndex: self.currentIndex, songs: self.songs)
        }
    }

    func seek(to progress: Double) {
        guard let player = player else { return }

        player.currentTime = progress
        updateTimeDisplay()
    }

    func setShuffle(_ enabled: Bool) {
        if enabled {
            if !isShuffleEnabled {
                originalQueue = songs  // preserve original order
                if let current = currentSong {
                    var remainingSongs = songs.filter { $0.id != current.id }
                    remainingSongs.shuffle()
                    songs = [current] + remainingSongs  // keep current song at index 0
                    currentIndex = 0
                } else {
                    songs.shuffle()
                    currentIndex = 0
                }
                updateNowPlayingInfo()
            }
        } else {
            if isShuffleEnabled {
                if let current = currentSong, !originalQueue.isEmpty {
                    songs = originalQueue
                    if let index = songs.firstIndex(where: { $0.id == current.id }) {
                        currentIndex = index
                    } else {
                        currentIndex = 0
                        currentSong = songs.first
                    }
                }
                originalQueue = []
                updateNowPlayingInfo()
            }
        }
        isShuffleEnabled = enabled
    }

    func setRepeat(_ enabled: Bool) {
        isRepeatEnabled = enabled
    }

    func seekByFraction(_ fraction: Double) {
        guard let player = player else { return }
        // Multiply the fraction (0...1) by the total duration to get the desired time.
        player.currentTime = fraction * player.duration
        updateTimeDisplay()
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(
            withTimeInterval: 0.1,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateTimeDisplay()
            }
        }

        // Ensure timer runs on main run loop
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func updateTimeDisplay() {
        guard let player = player else { return }

        playbackProgress = player.currentTime / player.duration
        currentTime = formatTime(player.currentTime)
        duration = formatTime(player.duration)
        updateNowPlayingInfo()
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func resolveSongURL(_ song: Song) -> URL? {
        guard let bookmarkData = song.bookmark else { return nil }

        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withoutUI,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale)

            if isStale {
                let newBookmark = try url.bookmarkData(options: [])
                logger.warning("Bookmark was stale - consider reimporting this file")

                // Update the song in repository
                var updatedSong = song
                updatedSong.bookmark = newBookmark
                Task {
                    _ = try await songRepo?.upsertSong(updatedSong)
                }
            }

            return url
        } catch {
            logger.error("Bookmark error: \(error)")
            return nil
        }
    }
}

struct PlayerView: View {
    @EnvironmentObject private var playerVM: PlayerViewModel
    @State private var showingQueue = false
    @State private var shuffleEnabled: Bool = false
    @State private var repeatEnabled: Bool = false
    @Environment(\.dismiss) private var dismiss

    // State for playlist creation
    @State private var showingPlaylistAlert = false
    @State private var playlistName = ""
    @State private var editMode = EditMode.inactive

    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [Color.purple.opacity(0.8), Color.blue.opacity(0.8)]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .edgesIgnoringSafeArea(.all)
            VStack {
                // Top Bar
                HStack {
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.largeTitle)
                            .foregroundColor(.white)
                    }
                }
                .padding(.top)
                // Artwork and Song Info Section
                if let song = playerVM.currentSong {
                    VStack {
                        if let cover = coverArt(of: song) {
                            Image(uiImage: cover)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 300, maxHeight: 300)
                                .cornerRadius(8)
                                .shadow(radius: 10)
                        } else {
                            Image(systemName: "music.note")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 200, height: 200)
                                .foregroundColor(.white)
                        }

                        Text(song.title)
                            .font(.title)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .padding(.top, 8)
                        Text(song.artist)
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .padding()
                }

                // Playback Progress Slider
                VStack {
                    Slider(
                        value: Binding(
                            get: { playerVM.playbackProgress },
                            set: { newValue in
                                playerVM.seekByFraction(newValue)
                            }
                        ),
                        in: 0...1
                    )
                    .accentColor(.yellow)
                    .padding(.horizontal)

                    HStack {
                        Text(playerVM.currentTime)
                        Spacer()
                        Text(playerVM.duration)
                    }
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(.horizontal)
                }
                .padding(.vertical)

                // Playback Control Buttons
                HStack(spacing: 30) {
                    Button(action: {
                        shuffleEnabled.toggle()
                        playerVM.setShuffle(shuffleEnabled)
                    }) {
                        Image(systemName: shuffleEnabled ? "shuffle.circle.fill" : "shuffle.circle")
                            .font(.system(size: 30))
                            .foregroundColor(shuffleEnabled ? .yellow : .white)
                    }

                    Button(action: { playerVM.previousSong() }) {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.white)
                    }

                    Button(action: { playerVM.playPause() }) {
                        Image(
                            systemName: playerVM.isPlaying
                                ? "pause.circle.fill" : "play.circle.fill"
                        )
                        .font(.system(size: 60))
                        .foregroundColor(.white)
                    }

                    Button(action: { playerVM.nextSong() }) {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.white)
                    }

                    Button(action: {
                        repeatEnabled.toggle()
                        playerVM.setRepeat(repeatEnabled)
                    }) {
                        Image(systemName: repeatEnabled ? "repeat.circle.fill" : "repeat.circle")
                            .font(.system(size: 30))
                            .foregroundColor(repeatEnabled ? .yellow : .white)
                    }
                }
                .padding()

                // Volume Control - NEW: Updated slider range and styling
                HStack {
                    Image(systemName: "speaker.fill")
                        .foregroundColor(.white)
                    Slider(value: $playerVM.volume, in: 0...1)
                        .accentColor(.yellow)
                    Image(systemName: "speaker.wave.3.fill")
                        .foregroundColor(.white)
                }
                .padding(.horizontal)

                // Queue Toggle Button
                Button(action: {
                    showingQueue.toggle()
                }) {
                    HStack {
                        Image(systemName: "list.bullet")
                        Text("Queue (\(playerVM.queue.count))")
                    }
                    .foregroundColor(.white)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    .background(Color.black.opacity(0.3))
                    .cornerRadius(10)
                }
                .padding(.top)

                // Currently Played Queue - NEW: Added current song icon and tap gesture to play new song
                if showingQueue {
                    ScrollView {
                        VStack(alignment: .leading) {
                            ForEach(playerVM.queue.indices, id: \.self) { index in
                                let song = playerVM.queue[index]
                                HStack {
                                    Text("\(index + 1).")
                                        .foregroundColor(.white)
                                    VStack(alignment: .leading) {
                                        Text(song.title)
                                            .font(.headline)
                                            .foregroundColor(.white)
                                        Text(song.artist)
                                            .font(.subheadline)
                                            .foregroundColor(.white.opacity(0.8))
                                    }
                                    Spacer()
                                    if song.id == playerVM.currentSong?.id {
                                        Image(systemName: "speaker.wave.2.fill")
                                            .foregroundColor(.green)
                                    }
                                }
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    playerVM.playSong(song)
                                }
                            }
                            .onMove { indices, newOffset in
                                playerVM.reorderQueue(from: indices, to: newOffset)
                            }
                        }
                        .environment(\.editMode, $editMode)
                        .padding()
                    }
                    .frame(maxHeight: 200)
                    .background(Color.black.opacity(0.2))
                    .cornerRadius(8)
                    .padding(.horizontal)
                    .toolbar {
                        ToolbarItemGroup(placement: .navigationBarTrailing) {
                            Button("Save as Playlist") {
                                showingPlaylistAlert = true
                            }
                            EditButton()
                        }
                    }
                    .alert("New Playlist", isPresented: $showingPlaylistAlert) {
                        TextField("Playlist Name", text: $playlistName)
                        Button("Create") {
                            Task {
                                try await playerVM.createPlaylist(name: playlistName)
                                playlistName = ""
                            }
                        }
                        Button("Cancel", role: .cancel) {}
                    }
                }

                Spacer()
            }
            .padding()
        }
        .onAppear {
            playerVM.updateNowPlayingInfo()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
        ) { _ in
            playerVM.updateNowPlayingInfo()
        }
    }
}

extension Collection {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
@MainActor
class ArtistListViewModel: ObservableObject {
    @Published var artists: [String] = []
    @Published var searchQuery = ""
    private let songRepo: SongRepository

    init(songRepo: SongRepository) {
        self.songRepo = songRepo
    }

    func loadArtists() async throws {
        artists = try await songRepo.getAllArtists()
    }

    var filteredArtists: [String] {
        guard !searchQuery.isEmpty else { return artists }
        return artists.filter { $0.localizedCaseInsensitiveContains(searchQuery) }
    }
}

struct ArtistListView: View {
    @ObservedObject var viewModel: ArtistListViewModel
    private let songRepo: SongRepository

    init(dependencies: DependencyContainer, viewModel: ArtistListViewModel) {
        self.songRepo = dependencies.songRepository
        self.viewModel = viewModel
    }

    var body: some View {
        VStack {
            if viewModel.filteredArtists.isEmpty {
                emptyStateView
            } else {
                SearchBar(
                    text: $viewModel.searchQuery,
                    onChange: { _ in },
                    placeholder: "Search artists...",
                    debounceSeconds: 0.3)

                List(viewModel.filteredArtists, id: \.self) { artist in
                    NavigationLink {
                        ArtistSongListView(artist: artist, songRepo: songRepo)
                    } label: {
                        Text(artist)
                            .font(.headline)
                            .padding(.vertical, 8)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No Artists Found")
                .font(.title2)

            Text("Add a music source with audio files to populate artists")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxHeight: .infinity)
    }
}

struct ArtistSongListView: View {
    let artist: String
    @StateObject private var viewModel: SongListViewModel
    private var songRepo: SongRepository

    init(artist: String, songRepo: SongRepository) {
        self.artist = artist
        self.songRepo = songRepo
        _viewModel = StateObject(
            wrappedValue: SongListViewModel(
                songRepo: songRepo,
                filter: .artist(artist))
        )
    }

    var body: some View {
        SongListView(viewModel: viewModel)
            .navigationTitle(artist)
            .onAppear {
                Task { await viewModel.loadInitialSongs() }
            }
    }
}
@MainActor
class AlbumListViewModel: ObservableObject {
    @Published var albums: [Album] = []
    @Published var searchQuery = ""
    private let songRepo: SongRepository

    init(songRepo: SongRepository) {
        self.songRepo = songRepo
    }

    func loadAlbums() async throws {
        albums = try await songRepo.getAllAlbums()
    }

    var filteredAlbums: [Album] {
        guard !searchQuery.isEmpty else { return albums }
        return albums.filter {
            $0.name.localizedCaseInsensitiveContains(searchQuery)
                || $0.artist?.localizedCaseInsensitiveContains(searchQuery) ?? false
        }
    }
}

struct AlbumGridView: View {
    @ObservedObject var viewModel: AlbumListViewModel
    private let columns = [GridItem(.adaptive(minimum: 160))]
    private let songRepo: SongRepository

    init(dependencies: DependencyContainer, viewModel: AlbumListViewModel) {
        self.viewModel = viewModel
        self.songRepo = dependencies.songRepository
    }
    var body: some View {
        ScrollView {
            SearchBar(
                text: $viewModel.searchQuery,
                onChange: { _ in },
                placeholder: "Search albums...",
                debounceSeconds: 0.3)
            if viewModel.filteredAlbums.isEmpty {
                emptyStateView
            } else {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(viewModel.filteredAlbums) { album in
                        NavigationLink {
                            AlbumSongListView(album: album, songRepo: songRepo)
                        } label: {
                            AlbumCell(album: album)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("AlbumListRefresh")))
        { _ in
            Task { try? await viewModel.loadAlbums() }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "square.stack.slash")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No Albums Found")
                .font(.title2)

            Text("Add a music source with audio files to populate albums")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxHeight: .infinity)
    }
}

struct AlbumCell: View {
    let album: Album
    @State private var artwork: UIImage?
    @EnvironmentObject private var dependencies: DependencyContainer

    var body: some View {
        VStack(alignment: .leading) {
            ZStack {
                if let artwork = artwork {
                    Image(uiImage: artwork)
                        .resizable()
                        .aspectRatio(1, contentMode: .fill)
                } else {
                    Image(systemName: "music.note")
                        .resizable()
                        .aspectRatio(1, contentMode: .fit)
                        .padding()
                        .background(Color.gray.opacity(0.3))
                }
            }
            .frame(width: 160, height: 160)
            .cornerRadius(8)
            .clipped()

            VStack(alignment: .leading) {
                Text(album.name)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(album.artist ?? "Unknown Artist")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 160)
        }
        .onAppear {
            loadArtwork()
        }
        .contextMenu {
            Button("Delete Album", role: .destructive) {
                Task {
                    try? await dependencies.songRepository.deleteAlbum(
                        album: album.name, artist: album.artist)
                    NotificationCenter.default.post(
                        name: Notification.Name("AlbumListRefresh"), object: nil)
                }
            }
        }
    }

    private func loadArtwork() {
        guard let path = album.coverArtPath else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = docs.appendingPathComponent(path)

        DispatchQueue.global(qos: .userInitiated).async {
            if let image = UIImage(contentsOfFile: url.path) {
                DispatchQueue.main.async {
                    self.artwork = image
                }
            }
        }
    }
}

struct AlbumSongListView: View {
    let album: Album
    @StateObject private var viewModel: SongListViewModel

    init(album: Album, songRepo: SongRepository) {
        self.album = album
        _viewModel = StateObject(
            wrappedValue: SongListViewModel(
                songRepo: songRepo,
                filter: .album(album.name, artist: album.artist))
        )
    }

    var body: some View {
        SongListView(viewModel: viewModel)
            .navigationTitle(album.name)
            .onAppear {
                Task { await viewModel.loadInitialSongs() }
            }
    }
}

class LibraryNavigation: ObservableObject {
    @Published var path = NavigationPath()
}

struct LibraryView: View {
    let logger = Logger(subsystem: subsystem, category: "LibraryView")

    @EnvironmentObject private var dependencies: DependencyContainer
    @EnvironmentObject private var libraryNavigation: LibraryNavigation
    @StateObject private var artistVM: ArtistListViewModel
    @StateObject private var albumVM: AlbumListViewModel
    @StateObject private var songListVM: SongListViewModel
    @EnvironmentObject private var tabState: TabState  // already exists

    init(dependencies: DependencyContainer) {
        let dc = dependencies
        _artistVM = StateObject(wrappedValue: dc.makeArtistListViewModel())
        _albumVM = StateObject(wrappedValue: dc.makeAlbumListViewModel())
        _songListVM = StateObject(wrappedValue: dc.makeSongListViewModel(filter: .all))
    }

    var body: some View {
        NavigationStack(path: $libraryNavigation.path) {
            List {
                NavigationLink(
                    "Playlists",
                    destination: PlaylistListView(
                        viewModel: dependencies.makePlaylistListViewModel()))
                NavigationLink(
                    "Artists",
                    destination: ArtistListView(dependencies: dependencies, viewModel: artistVM))
                NavigationLink(
                    "Albums",
                    destination: AlbumGridView(dependencies: dependencies, viewModel: albumVM))
                NavigationLink("Songs", destination: SongListView(viewModel: songListVM))
            }
            .navigationTitle("Library")
        }
        .onAppear {
            Task {
                try? await artistVM.loadArtists()
                try? await albumVM.loadAlbums()
            }
        }

        .onChange(of: tabState.selectedTab) { newTab, _ in
            if newTab == 0 {  // library tab
                Task {
                    do {
                        try await artistVM.loadArtists()
                        try await albumVM.loadAlbums()
                    } catch {
                        logger.error("failed to resync view \(error)")
                    }
                }
            }
        }

        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("LibraryRefresh"))) {
            _ in
            Task {
                do {
                    try await artistVM.loadArtists()
                    try await albumVM.loadAlbums()
                } catch {

                    logger.error("failed to resync view \(error)")
                }
            }
        }
    }
}

@MainActor
class SourceBrowseViewModel: ObservableObject {
    private let service: SourceImportService
    private let sourceId: Int64
    @Published var isImporting = false
    /// A stack of visited parentPathIds; the last element is the "current folder."
    @Published private var pathStack: [Int64?] = [nil]

    @Published var items: [SourcePath] = []
    @Published var searchTerm: String = ""

    /// For checkboxes on any item (folders or files).
    @Published var selectedPathIds = Set<Int64>()

    /// The current parent path we’re displaying.
    var parentPathId: Int64? {
        pathStack.last ?? nil
    }

    /// Whether we can go back one level.
    var canGoBack: Bool {
        pathStack.count > 1
    }

    init(service: SourceImportService, sourceId: Int64, initialParentPathId: Int64? = nil) {
        self.service = service
        self.sourceId = sourceId
        if let initialParent = initialParentPathId {
            pathStack = [nil, initialParent]
        }
    }

    func loadItems() async {
        do {
            if searchTerm.isEmpty {
                items = try await service.listItems(
                    sourceId: sourceId, parentPathId: parentPathId)
            } else {
                items = try await service.search(sourceId: sourceId, query: searchTerm)
            }
        } catch {
            logger.error("Load items error: \(error)")
        }
    }

    let logger = Logger(subsystem: subsystem, category: "SourceBrowseViewModel")

    /// Navigate into a subfolder (push on stack).
    func goIntoFolder(with pathId: Int64) {
        pathStack.append(pathId)
        searchTerm = ""
        Task { await loadItems() }
    }

    /// Go up one level (pop from stack).
    func goBack() {
        guard canGoBack else { return }
        pathStack.removeLast()
        searchTerm = ""
        Task { await loadItems() }
    }

    /// Toggle selection for a path (folder or file).
    func toggleSelection(_ pathId: Int64) {
        if selectedPathIds.contains(pathId) {
            selectedPathIds.remove(pathId)
        } else {
            selectedPathIds.insert(pathId)
        }
    }
}

struct SourceBrowseView: View {
    let sourceId: Int64
    let parentPathId: Int64?
    let sourceImportService: SourceImportService?
    let songImportService: SongImportService?
    @StateObject var viewModel: SourceBrowseViewModel

    init(
        sourceId: Int64,
        parentPathId: Int64?,
        sourceImportService: SourceImportService?,
        songImportService: SongImportService?,
        viewModel: SourceBrowseViewModel? = nil

    ) {
        self.sourceId = sourceId
        self.parentPathId = parentPathId
        self.sourceImportService = sourceImportService
        self.songImportService = songImportService
        if let vm = viewModel {
            _viewModel = StateObject(wrappedValue: vm)
        } else {
            _viewModel = StateObject(
                wrappedValue: SourceBrowseViewModel(
                    service: sourceImportService!,
                    sourceId: sourceId,
                    initialParentPathId: parentPathId
                ))
        }
    }

    var body: some View {
        if let service: any SourceImportService = sourceImportService,
            let importService = songImportService
        {
            NavigationStack {
                // The SourceBrowseViewInternal (which lists files/folders) remains unchanged.
                SourceBrowseViewInternal(
                    sourceId: sourceId,
                    parentPathId: parentPathId,
                    sourceImportService: service,
                    songImportService: importService
                )
            }
        } else {
            Text("Services not available")
                .foregroundColor(.red)
        }
    }
}

struct SourceBrowseViewInternal: View {
    @StateObject var viewModel: SourceBrowseViewModel
    @State private var showImportProgress = false
    @State private var importProgress: Double = 0
    @State private var currentFileName: String = ""
    let songImportService: SongImportService

    init(
        sourceId: Int64,
        parentPathId: Int64? = nil,
        sourceImportService: SourceImportService,
        songImportService: SongImportService
    ) {
        _viewModel = StateObject(
            wrappedValue: SourceBrowseViewModel(
                service: sourceImportService,
                sourceId: sourceId,
                initialParentPathId: parentPathId
            )
        )
        self.songImportService = songImportService
    }

    private var logger = Logger(subsystem: subsystem, category: "SourceBrowsViewInternal")
    var body: some View {
        VStack {
            VStack {
                // Top bar with optional "Back" button
                HStack {
                    if viewModel.canGoBack {
                        Button("Back") {
                            viewModel.goBack()
                        }
                        .padding(.leading)
                    }
                    Spacer()
                    if viewModel.selectedPathIds.count > 0 {
                        Button(
                            viewModel.isImporting
                                ? "Importing..." : "Import \(viewModel.selectedPathIds.count) items"
                        ) {
                            guard !viewModel.isImporting else { return }

                            Task {
                                viewModel.isImporting = true
                                showImportProgress = true
                                defer {
                                    viewModel.isImporting = false
                                    showImportProgress = false
                                    NotificationCenter.default.post(
                                        name: Notification.Name("LibraryRefresh"), object: nil)
                                }

                                do {
                                    let selectedPaths = viewModel.items.filter {
                                        viewModel.selectedPathIds.contains($0.pathId)
                                    }

                                    try await songImportService.importPaths(
                                        paths: selectedPaths,
                                        onProgress: { pct, fileURL in
                                            await MainActor.run {
                                                importProgress = pct
                                                currentFileName = fileURL.lastPathComponent
                                            }
                                        }
                                    )

                                    // Clear selection only if completed successfully
                                    viewModel.selectedPathIds = []
                                } catch {
                                    logger.error("Import error: \(error)")
                                    // Don't clear selection if cancelled
                                    if !(error is CancellationError) {
                                        viewModel.selectedPathIds = []
                                    }
                                }
                            }
                        }
                        .disabled(viewModel.selectedPathIds.isEmpty || viewModel.isImporting)
                    }
                }
                if showImportProgress {
                    VStack {
                        if viewModel.isImporting {
                            Text("Importing \(currentFileName) ...")
                            ProgressView(value: importProgress, total: 100)
                            Button("Cancel Import") {
                                Task {
                                    await songImportService.cancelImport()
                                    showImportProgress = false
                                }
                            }
                            .padding()
                        } else {
                            Text(importProgress >= 100 ? "Complete!" : "Cancelled")
                        }
                    }
                    .padding()
                }

                SearchBar(
                    text: $viewModel.searchTerm,
                    onChange: { value in
                        Task { await viewModel.loadItems() }
                    }, placeholder: "Search paths...", debounceSeconds: 0.1
                )
                .padding(.horizontal)
                // File/Folder list
                List(viewModel.items, id: \.pathId) { item in
                    HStack {
                        // Icon: folder or doc
                        Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                            .foregroundColor(.gray)

                        // Name + relative path
                        VStack(alignment: .leading) {
                            Text(item.name)
                                .fontWeight(.medium)
                            Text(item.relativePath)
                                .font(.caption)
                                .foregroundColor(.gray)
                                .lineLimit(1)
                        }

                        Spacer()

                        // Checkboxes on everything (folder or file)
                        Button {
                            viewModel.toggleSelection(item.pathId)
                        } label: {
                            Image(
                                systemName: viewModel.selectedPathIds.contains(item.pathId)
                                    ? "checkmark.square"
                                    : "square")
                        }
                        .buttonStyle(BorderlessButtonStyle())
                    }
                    .contentShape(Rectangle())  // Entire row is tappable
                    .onTapGesture {
                        if item.isDirectory {
                            viewModel.goIntoFolder(with: item.pathId)
                        }
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("Source Browser")
        }
        .onAppear {
            Task { await viewModel.loadItems() }
        }
    }
}
struct SelectFolderView: View {
    var onAction: (() -> Void)?
    var title: String = "Load your directory"
    var message: String = "Get your iCloud directory and play music"
    var backgroundColor: Color = Color.purple
    var iconName: String = "cloud.fill"

    var body: some View {
        VStack {
            HStack(alignment: .center) {
                Spacer()
                Image(systemName: iconName)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 200)
                    .foregroundColor(backgroundColor)
                Spacer()
            }.frame(maxHeight: .infinity)
            VStack {
                VStack(alignment: .center) {
                    Text(title).font(.title).padding(.bottom, 30).foregroundColor(
                        Color.white)
                    Text(message)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.white)  // Align text to center
                    HStack {
                        Spacer()
                    }

                    Spacer()
                    if let onButtonTap = onAction {
                        Button(action: {
                            onButtonTap()
                        }) {
                            Text("Load")
                                .font(.title)
                                .padding()
                                .frame(maxWidth: .infinity)  // Makes the button take full width
                                .background(Color.white)  // White background
                                .foregroundColor(backgroundColor)  // Blue text for contrast
                                .cornerRadius(10)
                        }
                    }
                }
                .padding(50)
                .background(backgroundColor)
                .cornerRadius(25)
                .shadow(radius: 4)
            }.padding(20)
        }
    }
}

struct SyncView: View {
    @State private var showingFolderPicker = false
    private let logger = Logger(subsystem: subsystem, category: "SyncView")
    @StateObject private var syncViewModel: SyncViewModel
    private var dependencies: DependencyContainer

    @State private var showGrid: Bool = false

    init(dependencies: DependencyContainer) {
        _syncViewModel = StateObject(wrappedValue: dependencies.makeSyncViewModel())
        self.dependencies = dependencies
    }

    var body: some View {
        NavigationStack {
            contentView
                .navigationTitle("Music Sources")
                .toolbar {
                    // Always allow adding a source.
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            showingFolderPicker = true
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
                .fileImporter(
                    isPresented: $showingFolderPicker,
                    allowedContentTypes: [.folder],
                    allowsMultipleSelection: false
                ) { result in
                    handleFolderSelection(result: result)
                }
                .onAppear {
                    syncViewModel.loadSources()
                }
        }
    }

    @ViewBuilder
    private var contentView: some View {
        if syncViewModel.sources.isEmpty {
            emptyStateView
        }
        // If there is only one source and we are not forcing grid view...
        else if syncViewModel.sources.count == 1 && !showGrid {
            if let singleSource = syncViewModel.sources.first,
                let sourceId = singleSource.id
            {

                let browseVM =
                    dependencies.sourceBrowseViewModels[sourceId]
                    ?? SourceBrowseViewModel(
                        service: syncViewModel.sourceService!.importService(),
                        sourceId: sourceId,
                        initialParentPathId: singleSource.pathId
                    )
                SourceBrowseView(
                    sourceId: sourceId,
                    parentPathId: singleSource.pathId,
                    sourceImportService: syncViewModel.sourceService?.importService(),
                    songImportService: syncViewModel.songImportService,
                    viewModel: browseVM
                )
                .onAppear {
                    DispatchQueue.main.async {
                        dependencies.sourceBrowseViewModels[sourceId] = browseVM
                    }
                }
                .toolbar {

                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Grid") {
                            showGrid = true
                        }
                    }
                }
            }
        } else {

            sourceGridView
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Back to Grid") {
                            showGrid = true
                        }
                    }
                }
        }
    }

    private var sourceGridView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 20)], spacing: 20) {
                ForEach(syncViewModel.sources, id: \.stableId) { (source: Source) in
                    NavigationLink {
                        if let sourceId = source.id {
                            let browseVM =
                                dependencies.sourceBrowseViewModels[sourceId]
                                ?? SourceBrowseViewModel(
                                    service: syncViewModel.sourceService!.importService(),
                                    sourceId: sourceId,
                                    initialParentPathId: source.pathId
                                )
                            SourceBrowseView(
                                sourceId: sourceId,
                                parentPathId: source.pathId,
                                sourceImportService: syncViewModel.sourceService?.importService(),
                                songImportService: syncViewModel.songImportService,
                                viewModel: browseVM
                            )
                            .onAppear {
                                DispatchQueue.main.async {
                                    dependencies.sourceBrowseViewModels[sourceId] = browseVM
                                }
                            }
                        }
                    } label: {
                        SourceGridCell(
                            source: source,
                            isSyncing: syncViewModel.currentSyncSourceId == source.id,
                            onResync: {
                                logger.debug(
                                    "resyncing source: \(source.id ?? -1), path: \(source.dirPath)"
                                )
                                syncViewModel.resyncSource(source)
                            },
                            onDelete: {

                                syncViewModel.deleteSource(source)
                            }
                        )
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding()
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 60))
                .foregroundColor(.blue)
            Text("No Sources Added")
                .font(.title2)
            Text("Get started by adding your first music source from iCloud")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            Button("Add iCloud Source") {
                showingFolderPicker = true
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxHeight: .infinity)
    }

    private func handleFolderSelection(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                logger.debug("new path is getting synced: \(url)")
                try syncViewModel.registerBookmark(url)
                syncViewModel.createSource(path: url.path)

                showGrid = true
            } catch {
                logger.error("Folder selection error: \(error.localizedDescription)")
            }
        case .failure(let error):
            logger.error("Folder picker error: \(error.localizedDescription)")
        }
    }
}

struct SourceGridCell: View {
    let source: Source
    let isSyncing: Bool
    let onResync: () -> Void
    let onDelete: () -> Void

    private var lastSyncText: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        guard let date = source.lastSyncedAt else { return "Never synced" }
        return "Last sync: \(formatter.string(from: date))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: sourceTypeIcon)
                    .font(.title)
                    .foregroundColor(sourceTypeColor)

                VStack(alignment: .leading) {
                    Text(dirName)
                        .font(.headline)
                        .lineLimit(1)
                    Text(source.dirPath)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if isSyncing {
                    ProgressView()
                } else {
                    Button(action: onResync) {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }

            Text(lastSyncText)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(.tertiarySystemBackground))
        .cornerRadius(8)
        .contextMenu {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete Source", systemImage: "trash")
            }
        }
    }

    private var dirName: String {
        return makeURLFromString(source.dirPath).lastPathComponent
    }

    private var sourceTypeIcon: String {
        switch source.type {
        case .iCloud: return "icloud.fill"
        default: return "folder.fill"
        }
    }

    private var sourceTypeColor: Color {
        .gray
    }
}

enum SyncViewState {
    case noICloud, isInitialising,
        noSourceDirSet, notSyncedYet,
        showTreeView, syncInProgress, unboundView
}

@MainActor
class SyncViewModel: ObservableObject {
    @Published var sources: [Source] = []
    @Published var createdUser: User?
    @Published var errorMessage: String?
    @Published var currentSyncSourceId: Int64?

    @Published var selectedFolderName: String? = nil
    @Published var currentSource: Source?
    @Published var isSyncing = false
    @Published var currentSyncedDir: String? = nil

    private let userCloudService: UserCloudService?
    private let icloudProvider: ICloudProvider?
    let sourceService: SourceService?
    let songImportService: SongImportService?

    init(
        userCloudService: UserCloudService?,
        icloudProvider: ICloudProvider?,
        sourceService: SourceService?,
        songImportService: SongImportService?
    ) {
        self.userCloudService = userCloudService
        self.icloudProvider = icloudProvider
        self.sourceService = sourceService
        self.songImportService = songImportService
    }

    func loadSources() {
        Task {
            do {
                guard let currentUser = try await userCloudService?.resolveCurrentICloudUser()
                else {
                    errorMessage = "User not logged in"
                    return
                }

                sources =
                    try await sourceService?.repository()
                    .findOneByUserId(userId: currentUser.id ?? -1, path: nil) ?? []
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
    func deleteSource(_ source: Source) {
        Task {
            if let id = source.id {
                do {
                    try await sourceService?.repository().deleteSource(sourceId: id)
                    // Also, remove the source from the local list.
                    sources.removeAll { $0.id == id }
                } catch {
                    logger.error("Failed to delete source: \(error)")
                }
            }
        }
    }
    func createSource(path: String) {
        Task {
            do {
                guard let currentUser = try await userCloudService?.resolveCurrentICloudUser(),
                    let service = sourceService
                else {
                    errorMessage = "User is not available"
                    logger.error("failed to create source: user is not available")
                    return
                }

                let source = try await service.registerSourcePath(
                    userId: currentUser.id ?? -1,
                    path: path,
                    type: .iCloud
                )
                logger.debug("source path \(path) is registered, now syncing...")

                sources.append(source)
                try await syncSource(source)
            } catch CustomError.genericError(let msg) {
                errorMessage = msg
                logger.error("failed to register or sync source: \(msg)")
            } catch {
                errorMessage = error.localizedDescription
                logger.error("failed to register or sync source: \(error.localizedDescription)")
            }
        }
    }

    func resyncSource(_ source: Source) {
        Task {
            do {
                try await syncSource(source)
                loadSources()  // Refresh list
            } catch CustomError.genericError(let msg) {
                // TODO: Need to inform user to remove this source and re-add it
                logger.error("loaded error: \(msg)")
                errorMessage = msg
            } catch {
                logger.error("loaded error: \(error.localizedDescription)")
                errorMessage = error.localizedDescription
            }
        }
    }

    private func syncSource(_ source: Source) async throws {
        currentSyncSourceId = source.id
        defer {
            currentSyncSourceId = nil
            NotificationCenter.default.post(name: Notification.Name("LibraryRefresh"), object: nil)
        }

        guard let sourceId = source.id else {
            throw CustomError.genericError("Invalid source ID")
        }

        let folderURL = try resolveSourceURL(source)
        let updatedSource = try await sourceService?.syncService().syncDir(
            sourceId: sourceId,
            folderURL: folderURL,
            onCurrentURL: { _ in },
            onSetLoading: { _ in }
        )

        if let updated = updatedSource {
            if let index = sources.firstIndex(where: { $0.id == source.id }) {
                sources[index] = updated
            }
        }
    }

    private func resolveSourceURL(_ source: Source) throws -> URL {
        let folderURL = makeURLFromString(source.dirPath)
        let bookmarkKey = makeBookmarkKey(folderURL)
        logger.debug("Loading bookmark key \(bookmarkKey) of \(folderURL.absoluteString)")
        guard let bookmarkData = UserDefaults.standard.data(forKey: bookmarkKey) else {
            throw CustomError.genericError("Missing bookmark data")
        }

        var isStale = false
        return try URL(
            resolvingBookmarkData: bookmarkData,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    var state: SyncViewState {
        if !hasICloud() {
            return .noICloud
        } else if hasICloud() && (createdUser == nil && errorMessage == nil) {
            return .isInitialising
        } else if createdUser != nil && currentSource == nil {
            return .noSourceDirSet
        } else if createdUser != nil && currentSource != nil && currentSource?.lastSyncedAt == nil
            && !isSyncing
        {
            return .notSyncedYet
        } else if createdUser != nil && currentSource != nil && currentSource?.lastSyncedAt != nil
            && !isSyncing
        {
            return .showTreeView
        } else if isSyncing {
            return .syncInProgress
        }

        return .unboundView
    }
    let logger = Logger(subsystem: subsystem, category: "SyncViewModel")

    func registerPath(_ path: String) {
        Task {
            logger.debug("registering \(path)")
            do {
                if let currentUser = self.createdUser {
                    let lib = try await sourceService?.registerSourcePath(
                        userId: currentUser.id!, path: path, type: .iCloud)
                    let libId = lib?.id ?? -1
                    logger.debug("created source \(libId)")
                    self.currentSource = lib
                }
            } catch {
                logger.debug("failed to register lib \(error.localizedDescription)")
            }

            logger.debug("source is set...")
        }
    }

    func registerBookmark(_ folderURL: URL) throws {
        guard folderURL.startAccessingSecurityScopedResource() else {
            logger.error("Unable to access security scoped resource.")
            return
        }
        defer { folderURL.stopAccessingSecurityScopedResource() }
        let bookmarkKey = makeBookmarkKey(folderURL)

        let bookmarkData = try folderURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
        logger.debug("Setting bookmark key \(bookmarkKey) of \(folderURL.absoluteString)")

        UserDefaults.standard.set(bookmarkData, forKey: bookmarkKey)
    }

    func sync() {
        Task {
            self.isSyncing = true
            var currentSrc = self.currentSource
            do {
                // Start syncing with updates
                let folderPath = currentSource?.dirPath
                let sourceId = currentSource?.id
                logger.debug("started syncing...")
                if folderPath != nil && sourceId != nil {
                    let result = try await sourceService?.syncService().syncDir(
                        sourceId: sourceId!, folderURL: makeURLFromString(folderPath!),
                        onCurrentURL: { url in
                            DispatchQueue.main.async {
                                self.currentSyncedDir = url?.absoluteString
                            }
                        },
                        onSetLoading: { loading in
                            DispatchQueue.main.async {

                                self.isSyncing = loading
                            }
                        })
                    currentSrc?.totalPaths = result?.totalPaths
                } else {
                    logger.error("failed to sync")
                }
                self.isSyncing = false
                currentSrc?.lastSyncedAt = Date()
                currentSrc = try await sourceService?.repository().updateSource(
                    source: currentSrc!)
                logger.debug("finished syncing...")
                self.currentSource = currentSrc
            } catch {
                self.isSyncing = false
                currentSrc?.lastSyncedAt = Date()
                currentSrc?.syncError = error.localizedDescription
                currentSrc = try await sourceService?.repository().updateSource(
                    source: currentSrc!)
                logger.debug("finished with error")
                self.currentSource = currentSrc
            }
        }
    }

    func hasICloud() -> Bool {
        return icloudProvider?.isICloudAvailable() ?? false
    }

    func initialise() {
        if userCloudService == nil {
            self.errorMessage = "service is not available"
        }

        Task { @MainActor in
            do {
                let user = try await userCloudService?.resolveCurrentICloudUser()
                self.createdUser = user
                if let user = user {
                    self.currentSource = try await sourceService?.getCurrentSource(
                        userId: user.id!)
                    self.selectedFolderName = self.currentSource?.dirPath
                    let id = self.currentSource?.id ?? -1
                    let path = self.currentSource?.dirPath ?? ""
                    logger.debug("source \(id), path: \(path)")
                }
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    let logger = Logger(subsystem: subsystem, category: "AppDelegate")
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            logger.error("Audio session setup error: \(error)")
        }
        return true
    }
}

struct ErrorView: View {
    let error: String

    var body: some View {
        VStack {
            Text("Initialization Error")
                .font(.title)
            Text(error)
                .foregroundColor(.red)
                .padding()
        }
    }
}

func Oxanium(_ size: CGFloat = 16) -> Font {
    return Font.custom("Oxanium", size: size)
}

struct ThemeProvider: ViewModifier {
    func body(content: Content) -> some View {
        content
            // .environment(\.font, .system(size: 18, weight: .medium))  // Global font
            .font(Oxanium())
            .accentColor(.purple)
            .environment(\.colorScheme, .dark)

            .preferredColorScheme(.dark)  // Force dark mode
    }
}

extension View {
    func applyTheme() -> some View {
        self.modifier(ThemeProvider())
    }
}

@MainActor
class PlaylistListViewModel: ObservableObject {
    @Published var playlists: [Playlist] = []
    @Published var showingCreateDialog = false
    @Published var newPlaylistName = ""

    let playlistRepo: PlaylistRepository
    let playlistSongRepo: PlaylistSongRepository
    let songRepo: SongRepository

    private let logger = Logger(subsystem: subsystem, category: "PlaylistListViewModel")

    init(
        playlistRepo: PlaylistRepository,
        playlistSongRepo: PlaylistSongRepository,
        songRepo: SongRepository
    ) {
        self.playlistRepo = playlistRepo
        self.playlistSongRepo = playlistSongRepo
        self.songRepo = songRepo
    }

    func loadPlaylists() async {
        playlists = (try? await playlistRepo.getAll()) ?? []
    }

    func deletePlaylist(at offsets: IndexSet) async {
        for index in offsets {
            let playlist = playlists[index]
            if let id = playlist.id {
                do {
                    try await playlistRepo.delete(playlistId: id)
                } catch {
                    // Log or handle error as needed.
                    logger.debug("failed to delete song with id: \(id)")
                }
            }
        }
        await loadPlaylists()
    }

    func createPlaylist() async {
        guard !newPlaylistName.isEmpty else { return }
        let playlist = Playlist(id: nil, name: newPlaylistName, createdAt: Date(), updatedAt: nil)
        if let created = try? await playlistRepo.create(playlist: playlist) {
            playlists.append(created)
            newPlaylistName = ""
            showingCreateDialog = false
        }
    }
}

@MainActor
class PlaylistDetailViewModel: ObservableObject {
    @Published var songs: [Song] = []
    @Published var showAddSongs = false
    @Published var selectedSongs = Set<Int64>()

    let playlist: Playlist
    let playlistSongRepo: PlaylistSongRepository
    let songRepo: SongRepository

    init(playlist: Playlist, playlistSongRepo: PlaylistSongRepository, songRepo: SongRepository) {
        self.playlist = playlist
        self.playlistSongRepo = playlistSongRepo
        self.songRepo = songRepo
    }

    func loadSongs() async {
        songs = (try? await playlistSongRepo.getSongs(playlistId: playlist.id!)) ?? []
    }

    func deleteSong(at offsets: IndexSet) async {
        guard let playlistId = playlist.id else { return }
        for index in offsets {
            let songId = songs[index].id!
            try? await playlistSongRepo.removeSong(playlistId: playlistId, songId: songId)
        }
        await loadSongs()
    }

    func reorderSongs(from source: IndexSet, to destination: Int) async {
        var updatedSongs = songs
        updatedSongs.move(fromOffsets: source, toOffset: destination)

        let newOrder = updatedSongs.map { $0.id! }
        try? await playlistSongRepo.reorderSongs(playlistId: playlist.id!, newOrder: newOrder)
        await loadSongs()
    }
}

// New Views
struct PlaylistListView: View {
    @ObservedObject var viewModel: PlaylistListViewModel

    var body: some View {
        NavigationStack {
            if viewModel.playlists.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 60))
                        .foregroundColor(.gray)
                    Text("No Playlists Found")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("Create a playlist to get started.")
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                    Button("Create Playlist") {
                        viewModel.showingCreateDialog = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .navigationTitle("Playlists")
            } else {  // OLD: Existing list view for playlists
                List {
                    ForEach(viewModel.playlists) { playlist in
                        NavigationLink {
                            PlaylistDetailView(
                                playlist: playlist,
                                viewModel: PlaylistDetailViewModel(
                                    playlist: playlist,
                                    playlistSongRepo: viewModel.playlistSongRepo,
                                    songRepo: viewModel.songRepo
                                )
                            )
                        } label: {
                            Text(playlist.name)
                                .font(.headline)
                        }
                    }
                    .onDelete { offsets in
                        Task { await viewModel.deletePlaylist(at: offsets) }
                    }
                }
                .toolbar {
                    Button {
                        viewModel.showingCreateDialog = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                .navigationTitle("Playlists")
            }
        }
        .alert("New Playlist", isPresented: $viewModel.showingCreateDialog) {
            TextField("Name", text: $viewModel.newPlaylistName)
            Button("Create") {
                Task { await viewModel.createPlaylist() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear {
            Task { await viewModel.loadPlaylists() }
        }
    }
}

struct PlaylistDetailView: View {
    let playlist: Playlist
    @ObservedObject var viewModel: PlaylistDetailViewModel
    @EnvironmentObject var playerVM: PlayerViewModel

    var body: some View {
        VStack {
            if viewModel.songs.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "music.note")
                        .font(.system(size: 60))
                        .foregroundColor(.gray)
                    Text("No Songs in this Playlist")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("Tap 'Add Songs' to add your favorite tracks.")
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(viewModel.songs) { song in
                        SongRow(song: song) {
                            if let index = viewModel.songs.firstIndex(of: song) {
                                playerVM.configureQueue(songs: viewModel.songs, startIndex: index)
                                playerVM.playSong(song)
                            }
                        }
                    }
                    .onDelete { offsets in
                        Task { await viewModel.deleteSong(at: offsets) }
                    }
                    .onMove { from, to in
                        Task { await viewModel.reorderSongs(from: from, to: to) }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button("Add Songs") {
                    viewModel.showAddSongs = true
                }
                EditButton()
            }
        }
        .sheet(isPresented: $viewModel.showAddSongs) {
            SongSelectionView(
                songRepo: viewModel.songRepo,
                onSongsSelected: { selected in
                    Task {
                        guard let playlistId = playlist.id else { return }
                        for song in selected {
                            try? await viewModel.playlistSongRepo.addSong(
                                playlistId: playlistId,
                                songId: song.id!
                            )
                        }
                        await viewModel.loadSongs()
                    }
                })
        }
        .navigationTitle(playlist.name)
        .onAppear {
            Task { await viewModel.loadSongs() }
        }
    }
}

struct SongSelectionView: View {
    let songRepo: SongRepository
    let onSongsSelected: ([Song]) -> Void
    @State private var selectedSongs = Set<Int64>()
    @StateObject private var songListVM: SongListViewModel

    init(songRepo: SongRepository, onSongsSelected: @escaping ([Song]) -> Void) {
        self.songRepo = songRepo
        self.onSongsSelected = onSongsSelected
        _songListVM = StateObject(
            wrappedValue: SongListViewModel(
                songRepo: songRepo,
                filter: .all
            )
        )
    }

    var body: some View {
        NavigationStack {
            List(songListVM.songs, id: \.uniqueId) { song in
                SelectableSongRow(
                    song: song,
                    isSelected: selectedSongs.contains(song.id ?? -1)
                ) {
                    if selectedSongs.contains(song.id ?? -1) {
                        selectedSongs.remove(song.id ?? -1)
                    } else {
                        selectedSongs.insert(song.id ?? -1)
                    }
                }
            }
            .toolbar {
                Button("Add") {
                    let songsToAdd = songListVM.songs.filter { selectedSongs.contains($0.id ?? -1) }
                    onSongsSelected(songsToAdd)
                }
            }
            .onAppear {
                Task { await songListVM.loadInitialSongs() }
            }
        }
    }
}

@main
struct musicappApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var dependencies: DependencyContainer
    @StateObject private var playerVM: PlayerViewModel
    @StateObject private var tabState = TabState()

    init() {

        let c = try! DependencyContainer()
        _dependencies = StateObject(wrappedValue: c)

        _playerVM = StateObject(
            wrappedValue: PlayerViewModel(
                playerPersistenceService: c.playerPersistenceService, songRepo: c.songRepository,
                playlistRepo: c.playlistRepo, playlistSongRepo: c.playlistSongRepo))

    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(tabState)
                .environmentObject(dependencies)
                .environmentObject(playerVM)
                .applyTheme()
        }
    }
}
