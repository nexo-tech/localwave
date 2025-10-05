//
//  TUIDependencyContainer.swift
//  localwave-tui
//
//  Created by Claude Code on 04.10.2025.
//

import Foundation
import SQLite
import LocalWaveDomain
import LocalWaveCore
import LocalWaveData
import LocalWavePlayer

/// TUI-specific dependency injection container.
/// Reuses all Data layer repositories and services from the iOS app,
/// but excludes iOS-specific dependencies (SwiftUI, AVFoundation, MediaPlayer).
@MainActor
class TUIDependencyContainer {
    // MARK: - Core Services (Reused from iOS)

    let userService: UserService
    let userCloudService: UserCloudService
    let icloudProvider: ICloudProvider
    let sourceService: SourceService
    let sourcePathRepository: SourcePathRepository
    let songRepository: SongRepository
    let songImportService: SongImportService
    let playerPersistenceService: PlayerPersistenceService
    let playlistRepo: PlaylistRepository
    let playlistSongRepo: PlaylistSongRepository
    let playerViewModel: BasePlayerViewModel

    private var backgroundFileService: BackgroundFileService?

    let logger = TUILogger(subsystem: subsystem, category: "TUIDependencyContainer")

    // MARK: - Initialization

    init() throws {
        logger.info("Initializing TUI DependencyContainer...")

        // Setup SQLite connection with TUI-specific path
        guard let db = setupTUISQLiteConnection(dbName: "musicApp\(schemaVersion).sqlite") else {
            throw CustomError.genericError("database initialisation failed")
        }

        // Initialize repositories (100% code reuse)
        let userRepo = try SQLiteUserRepository(db: db)
        let sourceRepo = try SQLiteSourceRepository(db: db)
        let sourcePathRepo = try SQLiteSourcePathRepository(db: db)
        let sourcePathSearchRepository = try SQLiteSourcePathSearchRepository(db: db)
        let songRepo = try SQLiteSongRepository(db: db)

        // Initialize services (100% code reuse)
        userService = DefaultUserService(userRepository: userRepo)
        icloudProvider = DefaultICloudProvider()
        userCloudService = DefaultUserCloudService(
            userService: userService,
            iCloudProvider: icloudProvider
        )

        let sourceSyncService = DefaultSourceSyncService(
            sourceRepository: sourceRepo,
            sourcePathSearchRepository: sourcePathSearchRepository,
            sourcePathRepository: sourcePathRepo
        )

        let sourceImportService = DefaultSourceImportService(
            sourceRepository: sourceRepo,
            sourcePathRepository: sourcePathRepo,
            sourcePathSearchRepository: sourcePathSearchRepository
        )

        sourceService = DefaultSourceService(
            sourceRepo: sourceRepo,
            sourceSyncService: sourceSyncService,
            sourceImportService: sourceImportService
        )

        sourcePathRepository = sourcePathRepo
        songRepository = songRepo
        songImportService = DefaultSongImportService(
            songRepo: songRepo,
            sourcePathRepo: sourcePathRepo,
            sourceRepo: sourceRepo
        )

        playerPersistenceService = DefaultPlayerPersistenceService(songRepo: songRepo)
        playlistRepo = try SQLitePlaylistRepository(db: db)
        playlistSongRepo = try SQLitePlaylistSongRepository(db: db)
        backgroundFileService = BackgroundFileService(songRepo: songRepo)

        // Initialize player view model with AVAudioPlayer (proper macOS audio support)
        let audioPlayer = AVAudioPlayerAdapter()
        playerViewModel = BasePlayerViewModel(
            player: audioPlayer,
            playerPersistenceService: playerPersistenceService,
            songRepo: songRepo,
            playlistRepo: playlistRepo,
            playlistSongRepo: playlistSongRepo
        )

        logger.info("TUI DependencyContainer initialized successfully")
    }

    // MARK: - Lifecycle

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

    // MARK: - Factory Methods (Future ViewModels)

    // Note: ViewModel factory methods will be added in Phase 3+
    // when TUI views are implemented. For now, repositories can be
    // accessed directly for testing.
}

// MARK: - TUI-specific Database Setup

/// Setup SQLite connection with TUI-appropriate directory
/// Uses XDG Base Directory specification: ~/.local/share/localwave
/// Falls back to ~/Library/Application Support/localwave on macOS
private func setupTUISQLiteConnection(dbName: String) -> Connection? {
    let logger = TUILogger(subsystem: subsystem, category: "setupTUISQLiteConnection")
    logger.debug("Setting up TUI database connection...")

    // Get the appropriate data directory
    let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
    let dataDir: String

    #if os(macOS)
    // macOS: Use Application Support (preferred) or XDG (for compatibility)
    if let xdgDataHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"] {
        dataDir = "\(xdgDataHome)/localwave"
    } else {
        // Default to macOS standard location
        dataDir = "\(homeDir)/Library/Application Support/localwave"
    }
    #else
    // Linux/Unix: Use XDG Base Directory specification
    if let xdgDataHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"] {
        dataDir = "\(xdgDataHome)/localwave"
    } else {
        dataDir = "\(homeDir)/.local/share/localwave"
    }
    #endif

    // Create directory if it doesn't exist
    do {
        try FileManager.default.createDirectory(
            atPath: dataDir,
            withIntermediateDirectories: true,
            attributes: nil
        )
    } catch {
        logger.error("Failed to create data directory: \(error.localizedDescription)")
        return nil
    }

    let dbFullPath = "\(dataDir)/\(dbName)"
    logger.info("Database path: \(dbFullPath)")

    do {
        return try Connection(dbFullPath)
    } catch {
        logger.error("DB init error: \(error.localizedDescription)")
        fatalError("DB init error: \(error)")
    }
}
