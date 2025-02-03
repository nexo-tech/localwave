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

struct MainTabView: View {
    @StateObject private var tabState = TabState()
    @State private var isPlayerPresented = false

    private let app: AppDependencies?
    init(app: AppDependencies?) {
        self.app = app
    }
    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $tabState.selectedTab) {
                if let songRepo = app?.songRepository {
                    LibraryView(songRepo: songRepo).tabItem {
                        Label("Library", systemImage: "books.vertical")
                    }.tag(0)
                }

                PlayerView()
                    .tabItem {
                        Label("Player", systemImage: "play.circle")
                    }.tag(1)

                VStack {
                    SyncView(
                        userCloudService: app?.userCloudService,
                        icloudProvider: app?.icloudProvider,
                        libraryService: app?.libraryService,
                        songImportService: app?.songImportService)
                }.tabItem {
                    Label("Sync", systemImage: "icloud.and.arrow.down")
                }.tag(2)
            }
            .environmentObject(tabState)
            .accentColor(.orange)

            MiniPlayerView {
                isPlayerPresented = true
            }
            .padding(.bottom, 60)  // Adjust based on your tab bar height
        }
        .fullScreenCover(isPresented: $isPlayerPresented) {
            PlayerView()
        }
    }
}

// MARK: - SongRow View
struct SongRow: View {
    @ObservedObject private var playerVM = PlayerViewModel.shared

    let song: Song
    let onPlay: () -> Void

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

    private func reset() {
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
        defer { isLoadingPage = false }  // NEW: Ensure we always reset loading state

        do {
            let newSongs = try await loadFilteredSongs()
            let received = newSongs.count

            // NEW: More accurate hasMorePages calculation
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
        reset()  // NEW: Use reset instead of manual reset
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
    @ObservedObject private var viewModel: SongListViewModel
    @State private var searchText: String = ""
    @State private var isPlayerPresented: Bool = false

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
                                PlayerViewModel.shared.configureQueue(
                                    songs: viewModel.songs, startIndex: index)
                                PlayerViewModel.shared.playSong(song)
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
                    ? "Add a music library to get started"
                    : "No matches found for '\(searchText)'"
            )
            .multilineTextAlignment(.center)
            .foregroundColor(.secondary)

            if searchText.isEmpty {
                Button("Add Library") {
                    tabState.selectedTab = 2
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(maxHeight: .infinity)
    }
}

struct MiniPlayerView: View {
    @ObservedObject var playerVM: PlayerViewModel = PlayerViewModel.shared
    var onTap: () -> Void

    var body: some View {
        if playerVM.currentSong != nil {
            Button(action: {
                onTap()
            }) {
                HStack {
                    if let song = playerVM.currentSong, let cover = coverArt(of: song) {
                        Image(uiImage: cover)
                            .resizable()
                            .frame(width: 50, height: 50)
                            .cornerRadius(5)
                    } else {
                        Image(systemName: "music.note")
                            .resizable()
                            .frame(width: 50, height: 50)
                            .cornerRadius(5)
                    }

                    VStack(alignment: .leading) {
                        Text(playerVM.currentSong?.title ?? "No Song")
                            .font(.headline)
                        Text(
                            "\(playerVM.currentSong?.artist ?? "Unknown") - \(playerVM.currentSong?.album ?? "")"
                        )
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: {
                        playerVM.playPause()
                    }) {
                        Image(systemName: playerVM.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding()
                .background(Color(UIColor.secondarySystemBackground))
            }
            .buttonStyle(PlainButtonStyle())
        }
    }
}

func coverArt(of song: Song) -> UIImage? {
    guard let coverArtPath = song.coverArtPath else { return nil }
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    let coverURL = docs.appendingPathComponent(coverArtPath)
    return UIImage(contentsOfFile: coverURL.path)
}

@MainActor
class PlayerViewModel: NSObject, ObservableObject, @preconcurrency AVAudioPlayerDelegate {
    static var shared = PlayerViewModel()

    @Published var currentSong: Song?
    @Published var isPlaying = false
    @Published var playbackProgress: Double = 0
    @Published var currentTime: String = "0:00"
    @Published var duration: String = "0:00"

    private let playerPersistenceService: PlayerPersistenceService?

    @Published var volume: Float = 1.0 {
        didSet {
            player?.volume = volume
            Task {
                await playerPersistenceService?.savePlaybackState(
                    volume: volume, currentIndex: currentIndex, songs: songs)
            }
        }
    }

    init(playerPersistenceService: PlayerPersistenceService? = nil) {
        self.playerPersistenceService = playerPersistenceService
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

            if let volume = await self.playerPersistenceService?.getVolume() {
                self.volume = volume
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

        guard let url = resolveSongURL(song),
            let audioPlayer = try? AVAudioPlayer(contentsOf: url)
        else {
            logger.error("Can't load song URL.")
            return
        }

        player = audioPlayer
        currentSong = song
        player?.delegate = self
        updateTimeDisplay()
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

    func stop() {
        player?.stop()
        isPlaying = false
        playbackProgress = 0
        stopTimer()
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
        currentIndex = (currentIndex + 1) % songs.count
        playSong(songs[currentIndex])
        Task {
            await self.playerPersistenceService?.savePlaybackState(
                volume: self.volume, currentIndex: self.currentIndex, songs: self.songs)
        }
    }

    func seek(to progress: Double) {
        guard let player = player else { return }
        player.currentTime = Double(progress) * player.duration
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
            return try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withoutUI,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale)
        } catch {
            logger.error("Bookmark error: \(error)")
            return nil
        }
    }
}

struct PlayerView: View {
    @StateObject private var vm = PlayerViewModel.shared

    @State private var editingProgress: Double?

    var body: some View {
        VStack(spacing: 20) {
            if let song = vm.currentSong {
                songInfoView(song: song)
                progressView()
                controlsView()
            } else {
                emptyStateView()
            }
        }
        .padding()
        .onAppear {
            vm.updateNowPlayingInfo()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
        ) { _ in
            vm.updateNowPlayingInfo()
        }
    }

    private func songInfoView(song: Song) -> some View {
        VStack {
            Text(song.title)
                .font(.title2)
                .fontWeight(.semibold)

            Text(song.artist)
                .font(.subheadline)
                .foregroundColor(.secondary)

            if let cover = coverArt(of: song) {
                Image(uiImage: cover)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 200, height: 200)
                    .cornerRadius(8)
                    .padding(.vertical)
            }
        }
    }

    private func controlsView() -> some View {
        VStack {
            // NEW: Volume control
            HStack {
                Image(systemName: "speaker.fill")
                Slider(value: $vm.volume, in: 0...1)
                Image(systemName: "speaker.wave.3.fill")
            }
            .padding(.horizontal)

            HStack(spacing: 40) {
                Button(action: vm.previousSong) {
                    Image(systemName: "backward.fill")
                        .font(.title)
                }

                Button(action: vm.playPause) {
                    Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 40))
                        .frame(width: 60, height: 60)
                }

                Button(action: vm.nextSong) {
                    Image(systemName: "forward.fill")
                        .font(.title)
                }
            }
            .foregroundColor(.primary)
        }
    }

    private func progressView() -> some View {
        VStack {
            Slider(
                value: Binding(
                    get: { editingProgress ?? vm.playbackProgress },
                    set: { newValue in
                        editingProgress = newValue
                    }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    if !editing, let progress = editingProgress {
                        vm.seek(to: progress)
                    }
                    editingProgress = nil  // Clear temporary value
                }
            )
            .accentColor(.purple)

            HStack {
                Text(vm.currentTime)
                Spacer()
                Text(vm.duration)
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
    }

    // private func controlsView() -> some View {
    // }

    private func emptyStateView() -> some View {
        VStack {
            Text("No song playing")
                .font(.headline)
                .padding()

            Image(systemName: "music.note")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
                .padding()
        }
    }

    private func coverArt(of song: Song) -> UIImage? {
        guard let coverArtPath = song.coverArtPath else { return nil }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let coverURL = docs.appendingPathComponent(coverArtPath)
        return UIImage(contentsOfFile: coverURL.path)
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

    init(songRepo: SongRepository, viewModel: ArtistListViewModel) {
        self.songRepo = songRepo
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

    // NEW: Empty state view
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No Artists Found")
                .font(.title2)

            Text("Add a music library with audio files to populate artists")
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

    init(songRepo: SongRepository, viewModel: AlbumListViewModel) {
        self.songRepo = songRepo
        self.viewModel = viewModel
    }
    var body: some View {
        ScrollView {
            if viewModel.filteredAlbums.isEmpty {
                emptyStateView
            } else {
                SearchBar(
                    text: $viewModel.searchQuery,
                    onChange: { _ in },
                    placeholder: "Search albums...",
                    debounceSeconds: 0.3)

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
    }

    // NEW: Empty state view
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "square.stack.slash")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No Albums Found")
                .font(.title2)

            Text("Add a music library with audio files to populate albums")
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

struct LibraryView: View {
    enum ViewMode: String, CaseIterable {
        case artists, albums, songs
    }

    @State private var selectedMode: ViewMode = .songs
    @StateObject private var songListVM: SongListViewModel
    @StateObject private var artistVM: ArtistListViewModel
    @StateObject private var albumVM: AlbumListViewModel

    let songRepo: SongRepository

    init(songRepo: SongRepository) {
        self.songRepo = songRepo
        _artistVM = StateObject(wrappedValue: ArtistListViewModel(songRepo: songRepo))
        _songListVM = StateObject(wrappedValue: SongListViewModel(songRepo: songRepo, filter: .all))
        _albumVM = StateObject(wrappedValue: AlbumListViewModel(songRepo: songRepo))
    }

    var body: some View {
        NavigationStack {

            VStack {
                Picker("View Mode", selection: $selectedMode) {
                    ForEach(ViewMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue.capitalized)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding()

                switch selectedMode {
                case .artists:
                    ArtistListView(songRepo: songRepo, viewModel: artistVM)
                case .albums:
                    AlbumGridView(songRepo: songRepo, viewModel: albumVM)
                case .songs:
                    SongListView(viewModel: songListVM)
                }
            }
            .onAppear {
                Task {
                    try? await artistVM.loadArtists()
                    try? await albumVM.loadAlbums()
                }
            }
        }
    }
}

@MainActor
class LibraryBrowseViewModel: ObservableObject {
    private let service: LibraryImportService
    private let libraryId: Int64
    @Published var isImporting = false
    /// A stack of visited parentPathIds; the last element is the "current folder."
    @Published private var pathStack: [Int64?] = [nil]

    @Published var items: [LibraryPath] = []
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

    init(service: LibraryImportService, libraryId: Int64, initialParentPathId: Int64? = nil) {
        self.service = service
        self.libraryId = libraryId
        if let initialParent = initialParentPathId {
            pathStack = [nil, initialParent]
        }
    }

    func loadItems() async {
        do {
            if searchTerm.isEmpty {
                items = try await service.listItems(
                    libraryId: libraryId, parentPathId: parentPathId)
            } else {
                items = try await service.search(libraryId: libraryId, query: searchTerm)
            }
        } catch {
            logger.error("Load items error: \(error)")
        }
    }

    let logger = Logger(subsystem: subsystem, category: "LibraryBrowseViewModel")

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

struct LibraryBrowseView: View {
    let libraryId: Int64
    let parentPathId: Int64?
    let libraryImportService: LibraryImportService?
    let songImportService: SongImportService?

    init(
        libraryId: Int64,
        parentPathId: Int64?,
        libraryImportService: LibraryImportService?,
        songImportService: SongImportService?
    ) {
        self.libraryId = libraryId
        self.parentPathId = parentPathId
        self.libraryImportService = libraryImportService
        self.songImportService = songImportService
    }

    var body: some View {
        if let service = libraryImportService, let importService = songImportService {
            LibraryBrowseViewInternal(
                libraryId: libraryId,
                parentPathId: parentPathId,
                libraryImportService: service,
                songImportService: importService
            )
        } else {
            Text("Services not available")
                .foregroundColor(.red)
        }
    }
}

struct LibraryBrowseViewInternal: View {
    @StateObject var viewModel: LibraryBrowseViewModel
    @State private var showImportProgress = false
    @State private var importProgress: Double = 0
    @State private var currentFileName: String = ""
    let songImportService: SongImportService

    init(
        libraryId: Int64,
        parentPathId: Int64? = nil,
        libraryImportService: LibraryImportService,
        songImportService: SongImportService
    ) {
        _viewModel = StateObject(
            wrappedValue: LibraryBrowseViewModel(
                service: libraryImportService,
                libraryId: libraryId,
                initialParentPathId: parentPathId
            )
        )
        self.songImportService = songImportService
    }

    private var logger = Logger(subsystem: subsystem, category: "LibraryBrowseView")
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
                            .foregroundColor(item.isDirectory ? .blue : .gray)

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
            .navigationTitle("Library Browser")
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
    @StateObject private var syncViewModel: SyncViewModel
    @State private var showingFolderPicker = false
    private let logger = Logger(subsystem: subsystem, category: "SyncView")

    init(
        userCloudService: UserCloudService?,
        icloudProvider: ICloudProvider?,
        libraryService: LibraryService?,
        songImportService: SongImportService?
    ) {
        _syncViewModel = StateObject(
            wrappedValue: SyncViewModel(
                userCloudService: userCloudService,
                icloudProvider: icloudProvider,
                libraryService: libraryService,
                songImportService: songImportService
            )
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if syncViewModel.libraries.isEmpty {
                    emptyStateView
                } else {
                    libraryGridView
                }
            }
            .navigationTitle("Music Libraries")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingFolderPicker = true
                    } label: {
                        Image(systemName: "plus")
                    }
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
            syncViewModel.loadLibraries()
        }
    }

    private var libraryGridView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 20)], spacing: 20) {
                ForEach(syncViewModel.libraries, id: \.stableId) { (library: Library) in
                    NavigationLink {
                        if let libraryId = library.id {
                            LibraryBrowseView(
                                libraryId: libraryId,
                                parentPathId: library.pathId,
                                libraryImportService: syncViewModel.libraryService?.importService(),
                                songImportService: syncViewModel.songImportService
                            )
                        }
                    } label: {
                        LibraryGridCell(
                            library: library,
                            isSyncing: syncViewModel.currentSyncLibraryId == library.id,
                            onResync: {
                                logger.debug(
                                    "resyncing library: \(library.id ?? -1), path: \(library.dirPath)"
                                )
                                syncViewModel.resyncLibrary(library)
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
            Text("No Libraries Added")
                .font(.title2)
            Text("Get started by adding your first music library from iCloud")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            Button("Add iCloud Library") {
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
                syncViewModel.createLibrary(path: url.path)
            } catch {
                logger.error("Folder selection error: \(error.localizedDescription)")
            }
        case .failure(let error):
            logger.error("Folder picker error: \(error.localizedDescription)")
        }
    }
}

struct LibraryGridCell: View {
    let library: Library
    let isSyncing: Bool
    let onResync: () -> Void
    private var lastSyncText: String {
        // NEW: Handle potential time zone issues
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        guard let date = library.lastSyncedAt else { return "Never synced" }
        return "Last sync: \(formatter.string(from: date))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: libraryTypeIcon)
                    .font(.title)
                    .foregroundColor(libraryTypeColor)

                VStack(alignment: .leading) {
                    Text(dirName)
                        .font(.headline)
                        .lineLimit(1)
                    Text(library.dirPath)
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
    }

    private var dirName: String {
        return URL(fileURLWithPath: library.dirPath).lastPathComponent
    }

    private var libraryTypeIcon: String {
        switch library.type {
        case .iCloud: return "icloud.fill"
        default: return "folder.fill"
        }
    }

    private var libraryTypeColor: Color {
        switch library.type {
        case .iCloud: return .blue
        default: return .gray
        }
    }
}

enum SyncViewState {
    case noICloud, isInitialising,
        noLibraryDirSet, notSyncedYet,
        showTreeView, syncInProgress, unboundView
}

@MainActor
class SyncViewModel: ObservableObject {
    @Published var libraries: [Library] = []
    @Published var createdUser: User?
    @Published var errorMessage: String?
    @Published var currentSyncLibraryId: Int64?

    @Published var selectedFolderName: String? = nil
    @Published var currentLibrary: Library?
    @Published var isSyncing = false
    @Published var currentSyncedDir: String? = nil

    private let userCloudService: UserCloudService?
    private let icloudProvider: ICloudProvider?
    let libraryService: LibraryService?
    let songImportService: SongImportService?

    init(
        userCloudService: UserCloudService?,
        icloudProvider: ICloudProvider?,
        libraryService: LibraryService?,
        songImportService: SongImportService?
    ) {
        self.userCloudService = userCloudService
        self.icloudProvider = icloudProvider
        self.libraryService = libraryService
        self.songImportService = songImportService
    }

    func loadLibraries() {
        Task {
            do {
                guard let currentUser = try await userCloudService?.resolveCurrentICloudUser()
                else {
                    errorMessage = "User not logged in"
                    return
                }

                libraries =
                    try await libraryService?.repository()
                    .findOneByUserId(userId: currentUser.id ?? -1, path: nil) ?? []
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func createLibrary(path: String) {
        Task {
            do {
                guard let currentUser = try await userCloudService?.resolveCurrentICloudUser(),
                    let service = libraryService
                else {
                    errorMessage = "User is not available"
                    logger.error("failed to create library: user is not available")
                    return
                }

                let library = try await service.registerLibraryPath(
                    userId: currentUser.id ?? -1,
                    path: path,
                    type: .iCloud
                )
                logger.debug("library path \(path) is registered, now syncing...")

                libraries.append(library)
                try await syncLibrary(library)
            } catch CustomError.genericError(let msg) {
                errorMessage = msg
                logger.error("failed to register or sync library: \(msg)")
            } catch {
                errorMessage = error.localizedDescription
                logger.error("failed to register or sync library: \(error.localizedDescription)")
            }
        }
    }

    func resyncLibrary(_ library: Library) {
        Task {
            do {
                try await syncLibrary(library)
                loadLibraries()  // Refresh list
            } catch CustomError.genericError(let msg) {
                // TODO: Need to inform user to remove this library and re-add it
                logger.error("loaded error: \(msg)")
                errorMessage = msg
            } catch {
                logger.error("loaded error: \(error.localizedDescription)")
                errorMessage = error.localizedDescription
            }
        }
    }

    private func syncLibrary(_ library: Library) async throws {
        currentSyncLibraryId = library.id
        defer { currentSyncLibraryId = nil }

        guard let libraryId = library.id else {
            throw CustomError.genericError("Invalid library ID")
        }

        let folderURL = try resolveLibraryURL(library)
        let updatedLibrary = try await libraryService?.syncService().syncDir(
            libraryId: libraryId,
            folderURL: folderURL,
            onCurrentURL: { _ in },
            onSetLoading: { _ in }
        )

        // NEW: Update the library in our local state
        if let updated = updatedLibrary {
            if let index = libraries.firstIndex(where: { $0.id == library.id }) {
                libraries[index] = updated
            }
        }
    }

    private func resolveLibraryURL(_ library: Library) throws -> URL {
        let bookmarkKey = String(hashStringToInt64(library.dirPath))
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
        } else if createdUser != nil && currentLibrary == nil {
            return .noLibraryDirSet
        } else if createdUser != nil && currentLibrary != nil && currentLibrary?.lastSyncedAt == nil
            && !isSyncing
        {
            return .notSyncedYet
        } else if createdUser != nil && currentLibrary != nil && currentLibrary?.lastSyncedAt != nil
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
                    let lib = try await libraryService?.registerLibraryPath(
                        userId: currentUser.id!, path: path, type: .iCloud)
                    let libId = lib?.id ?? -1
                    logger.debug("created library \(libId)")
                    self.currentLibrary = lib
                }
            } catch {
                logger.debug("failed to register lib \(error.localizedDescription)")
            }

            logger.debug("library is set...")
        }
    }

    func registerBookmark(_ folderURL: URL) throws {
        guard folderURL.startAccessingSecurityScopedResource() else {
            logger.error("Unable to access security scoped resource.")
            return
        }
        defer { folderURL.stopAccessingSecurityScopedResource() }
        let bookmarkKey = String(hashStringToInt64(folderURL.path))
        let bookmarkData = try folderURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
        UserDefaults.standard.set(bookmarkData, forKey: bookmarkKey)
    }

    func sync() {
        Task {
            self.isSyncing = true
            var currentLib = self.currentLibrary
            do {
                // Start syncing with updates
                let folderPath = currentLibrary?.dirPath
                let libraryId = currentLibrary?.id
                logger.debug("started syncing...")
                if folderPath != nil && libraryId != nil {
                    let result = try await libraryService?.syncService().syncDir(
                        libraryId: libraryId!, folderURL: URL(string: folderPath!)!,
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
                    currentLib?.totalPaths = result?.totalPaths
                } else {
                    logger.error("failed to sync")
                }
                self.isSyncing = false
                currentLib?.lastSyncedAt = Date()
                currentLib = try await libraryService?.repository().updateLibrary(
                    library: currentLib!)
                logger.debug("finished syncing...")
                self.currentLibrary = currentLib
            } catch {
                self.isSyncing = false
                currentLib?.lastSyncedAt = Date()
                currentLib?.syncError = error.localizedDescription
                currentLib = try await libraryService?.repository().updateLibrary(
                    library: currentLib!)
                logger.debug("finished with error")
                self.currentLibrary = currentLib
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
                    self.currentLibrary = try await libraryService?.getCurrentLibrary(
                        userId: user.id!)
                    self.selectedFolderName = self.currentLibrary?.dirPath
                    let id = self.currentLibrary?.id ?? -1
                    let path = self.currentLibrary?.dirPath ?? ""
                    logger.debug("library \(id), path: \(path)")
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

@main
struct musicappApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        let app = setupApp()
        WindowGroup {
            switch app {
            case .success(let app):
                MainTabView(app: app)
                    .environmentObject(TabState())
            case .failure(let err):
                Text("Failed to initialize the app: \(err.localizedDescription)")
                    .foregroundColor(.red)
                    .padding()
            }

        }
    }

    private func setupApp() -> Swift.Result<AppDependencies, CustomError> {
        do {
            let schemaVersion = 20
            let db = setupSQLiteConnection(dbName: "musicapp\(schemaVersion).sqlite")
            let userRepo = try SQLiteUserRepository(db: db!)
            let userService = DefaultUserService(userRepository: userRepo)
            let icloudProvider = DefaultICloudProvider()
            let userCloudService = DefaultUserCloudService(
                userService: userService, iCloudProvider: icloudProvider)
            let libraryRepo = try SQLiteLibraryRepository(db: db!)
            let libraryPathRepository = try SQLiteLibraryPathRepository(db: db!)
            let libraryPathSearchRepository = try SQLiteLibraryPathSearchRepository(db: db!)
            let librarySyncService = DefaultLibrarySyncService(
                libraryRepository: libraryRepo,
                libraryPathSearchRepository: libraryPathSearchRepository,
                libraryPathRepository: libraryPathRepository)
            let songRepository = try SQLiteSongRepository(db: db!)
            let songImportService = DefaultSongImportService(
                songRepo: songRepository,
                libraryPathRepo: libraryPathRepository, libraryRepo: libraryRepo)
            let libraryImportService = DefaultLibraryImportService(
                libraryPathRepository: libraryPathRepository,
                libraryPathSearchRepository: libraryPathSearchRepository)
            let libraryService = DefaultLibraryService(
                libraryRepo: libraryRepo, librarySyncService: librarySyncService,
                libraryImportService: libraryImportService)
            let playerPersistenceService: PlayerPersistenceService =
                DefaultPlayerPersistenceService(
                    songRepo: songRepository)

            PlayerViewModel.shared = PlayerViewModel(
                playerPersistenceService: playerPersistenceService)
            let app = AppDependencies(
                userService: userService,
                userCloudService: userCloudService,
                icloudProvider: icloudProvider,
                libraryService: libraryService,
                songRepository: songRepository,
                songImportService: songImportService,
                playerPersistenceService: playerPersistenceService)

            return .success(app)
        } catch {
            return .failure(.genericError(error.localizedDescription))
        }
    }
}
