import AVFoundation
import Combine
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
                    print("Text changed: \(text)")
                    textSubject.send(text)
                }
        }
        .onReceive(textSubject.debounce(for: .seconds(debounceSeconds), scheduler: RunLoop.main)) {
            debouncedValue in
            print("Debounced change called: \(debouncedValue)")
            onChange(debouncedValue)
        }
    }
}

struct MainTabView: View {
    private let app: AppDependencies?
    init(app: AppDependencies?) {
        self.app = app
    }
    var body: some View {
        TabView {
            LibraryView().tabItem {
                Label("Library", systemImage: "books.vertical")
            }

            // 2) A SongListView with search + tapping => play
            if let songRepo = app?.songRepository {
                SongListView(songRepo: songRepo)
                    .tabItem {
                        Label("All Songs", systemImage: "music.note.list")
                    }
            }

            // 3) Simple player
            PlayerView()
                .tabItem {
                    Label("Player", systemImage: "play.circle")
                }

            VStack {
                SyncView(
                    userCloudService: app?.userCloudService,
                    icloudProvider: app?.icloudProvider,
                    libraryService: app?.libraryService,
                    songImportService: app?.songImportService)
            }.tabItem {
                Label("Sync", systemImage: "icloud.and.arrow.down")
            }
        }.accentColor(.orange)
    }
}

struct SongListView: View {
    @StateObject private var viewModel: SongListViewModel
    @State private var text: String = ""

    init(songRepo: SongRepository) {
        _viewModel = StateObject(wrappedValue: SongListViewModel(songRepo: songRepo))
    }

    var body: some View {
        VStack {
            SearchBar(
                text: $text,
                onChange: { value in
                    Task {
                        await self.viewModel.searchSongs(query: self.text)
                    }
                }, placeholder: "Search songs...", debounceSeconds: 0.1
            )
            .padding(.horizontal)

            List(viewModel.songs, id: \.id) { song in
                HStack {
                    Text("\(song.title) - \(song.artist)")
                    Spacer()
                    if let coverArt = song.coverArtPath {
                        // Show a small cover image if you like
                        Image(uiImage: viewModel.image(for: coverArt) ?? UIImage())
                            .resizable()
                            .frame(width: 40, height: 40)
                            .cornerRadius(4)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    // On tap => start playback
                    viewModel.play(song: song)
                }
            }
        }
        .onAppear {
            Task { await viewModel.loadAll() }
        }

    }
}

@MainActor
class SongListViewModel: ObservableObject {
    @Published var songs: [Song] = []
    private let songRepo: SongRepository
    private var playerVM = PlayerViewModel.shared

    init(songRepo: SongRepository) {
        self.songRepo = songRepo
    }

    func loadAll() async {
        do {
            // For a quick approach, if you have a method to get all songs from DB:
            let allSongs = try await songRepo.searchSongsFTS(query: "", limit: 9999)
            self.songs = allSongs
        } catch {
            print("Song loading error: \(error)")
        }
    }

    func searchSongs(query: String) async {
        // Add small delay even though we have debounce
        if query.isEmpty {
            await loadAll()
        } else {
            do {
                let found = try await songRepo.searchSongsFTS(query: query, limit: 100)

                self.songs = found
            } catch {
                print("Search error: \(error)")
            }
        }

    }

    func play(song: Song) {
        playerVM.configureQueue(
            songs: songs, startIndex: songs.firstIndex(where: { $0.id == song.id }) ?? 0)
        playerVM.playSong(song)
    }

    // Example local image loading for covers in Documents
    func image(for coverArtPath: String) -> UIImage? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let imageURL = docs.appendingPathComponent(coverArtPath)
        if let data = try? Data(contentsOf: imageURL),
            let image = UIImage(data: data)
        {
            return image
        }
        return nil
    }
}

@MainActor
class PlayerViewModel: NSObject, ObservableObject, @preconcurrency AVAudioPlayerDelegate {
    static let shared = PlayerViewModel()
    private override init() {
        super.init()
    }  // NSObject requires this

    @Published var currentSong: Song?
    @Published var isPlaying = false
    @Published var playbackProgress: Double = 0
    @Published var currentTime: String = "0:00"
    @Published var duration: String = "0:00"

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
    }

    func playSong(_ song: Song) {
        stop()

        guard let url = resolveSongURL(song),
            let audioPlayer = try? AVAudioPlayer(contentsOf: url)
        else {
            print("Can't load song URL.")
            return
        }

        player = audioPlayer
        currentSong = song
        player?.delegate = self
        updateTimeDisplay()

        play()
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
    }

    private func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
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
    }

    func nextSong() {
        guard !songs.isEmpty else { return }
        currentIndex = (currentIndex + 1) % songs.count
        playSong(songs[currentIndex])
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
            print("Bookmark error: \(error)")
            return nil
        }
    }
}

struct PlayerView: View {
    @StateObject private var vm = PlayerViewModel.shared

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
    @State private var editingProgress: Double?
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

    private func controlsView() -> some View {
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

struct LibraryView: View {
    var body: some View {
        // should list all songs with search
        // when song is selected, starts playing it
        Text("library").font(.largeTitle).foregroundColor(.purple)
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
            print("Load items error: \(error)")
        }
    }

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
    @StateObject var viewModel: LibraryBrowseViewModel
    @State private var showImportProgress = false
    @State private var importProgress: Double = 0
    @State private var currentFileName: String = ""

    // Add a reference to your SongImportService somehow
    // For example, you can pass it in or get it from AppDependencies
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
                                    print("Import error: \(error)")
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

                // Search bar
                // TextField("Search...", text: $viewModel.searchTerm)
                //     .textFieldStyle(.roundedBorder)
                //     .padding(.horizontal)
                //     .onSubmit {
                //         Task { await viewModel.loadItems() }
                //     }

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
    @State var isPickingFolder = false
    @State var pickedFolder: String? = nil

    private let logger = Logger(subsystem: subsystem, category: "SyncView")

    private let songImportService: SongImportService?
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
                libraryService: libraryService))
        self.songImportService = songImportService
    }

    var body: some View {
        VStack {
            switch syncViewModel.state {
            case .noICloud:
                SelectFolderView(
                    title: "No ICLOUD",
                    message: "this tab requires iCloud",
                    backgroundColor: Color.orange,
                    iconName: "xmark.circle.fill"
                )
            case .isInitialising:
                VStack {
                    Text("Loading...")
                }.onAppear {
                    logger.debug("running sync view model")
                    syncViewModel.initialise()
                }
            case .noLibraryDirSet:
                SelectFolderView(
                    onAction: {
                        logger.debug("attempting to click")
                        isPickingFolder = true
                    },
                    backgroundColor: Color.purple
                ).fileImporter(
                    isPresented: $isPickingFolder,
                    allowedContentTypes: [.folder],
                    allowsMultipleSelection: false
                ) { result in
                    switch result {
                    case .success(let urls) where urls.count != 0:
                        if let folderURL = urls.first {
                            do {
                                try self.syncViewModel.registerBookmark(folderURL)
                                self.pickedFolder = folderURL.absoluteString
                            } catch {
                                logger.debug("picker error \(error)")
                            }
                        } else {
                            logger.debug("couldn't get url")
                        }
                    default:
                        logger.debug("couldn't get url")
                    }
                }
            case .notSyncedYet:
                VStack {
                    let selectedFolderName = syncViewModel.selectedFolderName ?? ""
                    Text("not synced: \(selectedFolderName)")
                    Text("Plase start")
                    Button("Sync now") {
                        syncViewModel.sync()
                    }
                }
            case .showTreeView:
                VStack {
                    let totalFiles = syncViewModel.currentLibrary?.totalPaths ?? 0
                    Text("file select view! \(totalFiles)")
                    Button("Sync now") {
                        syncViewModel.sync()
                    }
                    Button("resync") {
                        logger.debug("attempting to click")
                        isPickingFolder = true
                    }
                    .padding(20)
                    .fileImporter(
                        isPresented: $isPickingFolder,
                        allowedContentTypes: [.folder],
                        allowsMultipleSelection: false
                    ) { result in
                        switch result {
                        case .success(let urls) where urls.count != 0:
                            if let folderURL = urls.first {
                                do {
                                    try self.syncViewModel.registerBookmark(folderURL)
                                    self.pickedFolder = folderURL.absoluteString
                                } catch {
                                    logger.debug("picker error \(error)")
                                }
                            } else {
                                logger.debug("couldn't get url")
                            }
                        default:
                            logger.debug("couldn't get url")
                        }
                    }
                    if let library = syncViewModel.currentLibrary,
                        let ls = syncViewModel.libraryService
                    {
                        let libraryId = library.id
                        let parentPathId = hashStringToInt64(library.dirPath)
                        if let songImportService = songImportService {
                            LibraryBrowseView(
                                libraryId: libraryId!,
                                parentPathId: parentPathId,
                                libraryImportService: ls.importService(),
                                songImportService: songImportService)
                        } else {
                            Text("song import service is not avaialabe")
                        }

                    }
                }
            case .syncInProgress:
                VStack {
                    Text("syncing")
                    if let currentDir = syncViewModel.currentSyncedDir {
                        Text("curr: \(currentDir)")
                    }
                }
            case .unboundView:
                VStack {
                    Text("unknown state")
                }
            }
        }.onChange(of: pickedFolder) {
            if let pickedFolder = pickedFolder {
                syncViewModel.registerPath(pickedFolder)
                logger.debug("updated path")
            } else {
                logger.debug("no path")
            }
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
    @Published var createdUser: User?
    @Published var errorMessage: String?

    @Published var selectedFolderName: String? = nil
    @Published var currentLibrary: Library?
    @Published var isSyncing = false
    @Published var currentSyncedDir: String? = nil

    private let userCloudService: UserCloudService?
    private let icloudProvider: ICloudProvider?
    let libraryService: LibraryService?

    init(
        userCloudService: UserCloudService?,
        icloudProvider: ICloudProvider?,
        libraryService: LibraryService?
    ) {
        self.userCloudService = userCloudService
        self.icloudProvider = icloudProvider
        self.libraryService = libraryService
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
            print("Unable to access security scoped resource.")
            return
        }
        defer { folderURL.stopAccessingSecurityScopedResource() }
        let bookmarkKey = String(hashStringToInt64(folderURL.absoluteString))
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
