import Foundation
import SwiftUI
import os

// MARK: - Complete SQLitePlaylistSongRepository implementation
@MainActor
class DependencyContainer: ObservableObject {
    let userService: UserService
    let userCloudService: UserCloudService
    let icloudProvider: ICloudProvider
    let sourceService: SourceService
    let songRepository: SongRepository
    let songImportService: SongImportService
    let playerPersistenceService: PlayerPersistenceService
    let playlistRepo: PlaylistRepository
    let playlistSongRepo: PlaylistSongRepository

    private var backgroundFileService: BackgroundFileService?

    @Published var sourceBrowseViewModels: [Int64: SourceBrowseViewModel] = [:]

    let logger = Logger(subsystem: subsystem, category: "DependencyContainer")

    func handleAppLaunch() {
        logger.debug("Handling app launch...")
        startBackgroundServices()
        verifyPendingCopies()
        logger.debug("App launch handling complete")
    }

    private func verifyPendingCopies() {
        Task(priority: .utility) {
            let pending = await songRepository.getSongsNeedingCopy()
            logger.debug("Found \(pending.count) songs needing copy verification")
        }
    }

    init() throws {
        guard let db = setupSQLiteConnection(dbName: "musicApp\(schemaVersion).sqlite") else {
            throw CustomError.genericError("database initialisation failed")
        }

        let userRepo = try SQLiteUserRepository(db: db)
        let sourceRepo = try SQLiteSourceRepository(db: db)
        let sourcePathRepo = try SQLiteSourcePathRepository(db: db)
        let sourcePathSearchRepository = try SQLiteSourcePathSearchRepository(db: db)
        let songRepo = try SQLiteSongRepository(db: db)

        self.userService = DefaultUserService(userRepository: userRepo)
        self.icloudProvider = DefaultICloudProvider()
        self.userCloudService = DefaultUserCloudService(
            userService: userService,
            iCloudProvider: icloudProvider)

        let sourceSyncService = DefaultSourceSyncService(
            sourceRepository: sourceRepo,
            sourcePathSearchRepository: sourcePathSearchRepository,
            sourcePathRepository: sourcePathRepo)

        let sourceImportService = DefaultSourceImportService(
            sourceRepository: sourceRepo,
            sourcePathRepository: sourcePathRepo,
            sourcePathSearchRepository: sourcePathSearchRepository)
        self.sourceService = DefaultSourceService(
            sourceRepo: sourceRepo,
            sourceSyncService: sourceSyncService,
            sourceImportService: sourceImportService)
        self.songRepository = songRepo
        self.songImportService = DefaultSongImportService(
            songRepo: songRepo,
            sourcePathRepo: sourcePathRepo,
            sourceRepo: sourceRepo)
        self.playerPersistenceService = DefaultPlayerPersistenceService(songRepo: songRepo)
        self.playlistRepo = try SQLitePlaylistRepository(db: db)
        self.playlistSongRepo = try SQLitePlaylistSongRepository(db: db)
        self.backgroundFileService = BackgroundFileService(songRepo: songRepo)
    }

    func makeSongListViewModel(filter: SongListViewModel.Filter) -> SongListViewModel {
        SongListViewModel(songRepo: songRepository, filter: filter)
    }

    func makeArtistListViewModel() -> ArtistListViewModel {
        ArtistListViewModel(songRepo: songRepository)
    }

    func makeAlbumListViewModel() -> AlbumListViewModel {
        AlbumListViewModel(songRepo: songRepository)
    }

    func makePlaylistListViewModel() -> PlaylistListViewModel {
        PlaylistListViewModel(
            playlistRepo: playlistRepo,
            playlistSongRepo: playlistSongRepo,
            songRepo: songRepository
        )
    }

    func makeSyncViewModel() -> SyncViewModel {
        SyncViewModel(
            userCloudService: userCloudService,
            icloudProvider: icloudProvider,
            sourceService: sourceService,
            songImportService: songImportService
        )
    }

    private func startBackgroundServices() {
        logger.debug("starting background service...")
        guard let service = backgroundFileService else {
            logger.error("failed to initialise background file service")
            return
        }

        Task {
            await service.start()
            logger.debug("background file service startup triggered")
        }
    }
}
