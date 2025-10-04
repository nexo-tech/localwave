//
//  TUIDependencyContainer.swift
//  localwave-tui
//
//  Created by Claude Code on 04.10.2025.
//

import Foundation
import os
import SQLite

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
    let songRepository: SongRepository
    let songImportService: SongImportService
    let playerPersistenceService: PlayerPersistenceService
    let playlistRepo: PlaylistRepository
    let playlistSongRepo: PlaylistSongRepository

    private var backgroundFileService: BackgroundFileService?

    let logger = Logger(subsystem: subsystem, category: "TUIDependencyContainer")

    // MARK: - Initialization

    init() throws {
        logger.info("Initializing TUI DependencyContainer...")

        // Setup SQLite connection (same as iOS)
        guard let db = setupSQLiteConnection(dbName: "musicApp\(schemaVersion).sqlite") else {
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
