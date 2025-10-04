//
//  TUIApp.swift
//  localwave-tui
//
//  Created by Claude Code on 04.10.2025.
//

import Foundation
import LocalWaveCore
import os

/// Main TUI application class that coordinates the terminal interface.
/// Follows the same architectural patterns as the iOS app but adapted for CLI.
@MainActor
class TUIApp {
    private let dependencies: TUIDependencyContainer
    private let logger: Logger

    init() throws {
        logger = Logger(subsystem: subsystem, category: "TUIApp")
        logger.info("Initializing LocalWave TUI...")

        // Initialize TUI-specific dependency container
        // Reuses all Data/Domain layer code from iOS app
        dependencies = try TUIDependencyContainer()

        logger.info("TUI initialization complete")
    }

    /// Start the TUI application.
    /// This will be the main entry point that sets up the terminal interface.
    func start() async throws {
        logger.info("Starting LocalWave TUI...")

        // Trigger app launch logic (same as iOS)
        dependencies.handleAppLaunch()

        // Print welcome message
        printWelcome()

        // Show database stats
        await showDatabaseStats()

        // TODO: Phase 2 - Initialize SwiftTUI application
        // For now, just show a placeholder message
        print("\n📻 LocalWave TUI v1.0")
        print("Terminal interface coming soon...")
        print("\nPress Ctrl+C to exit")

        // Keep app running
        try await Task.sleep(for: .seconds(3600))
    }

    private func showDatabaseStats() async {
        do {
            let artists = try await dependencies.songRepository.getAllArtists()
            let albums = try await dependencies.songRepository.getAllAlbums()
            let playlists = try await dependencies.playlistRepo.getAll()

            print("\n📊 Database Stats:")
            print("   Artists: \(artists.count)")
            print("   Albums: \(albums.count)")
            print("   Playlists: \(playlists.count)")
        } catch {
            logger.error("Failed to load database stats: \(error)")
        }
    }

    private func printWelcome() {
        print("""
        ╔════════════════════════════════════════════╗
        ║                                            ║
        ║           🎵 LocalWave TUI 🎵             ║
        ║                                            ║
        ║     Offline-First Music Player for CLI    ║
        ║                                            ║
        ╚════════════════════════════════════════════╝
        """)
    }

    // MARK: - Helper Methods for Future Phases

    /// Cleanup and shutdown
    func shutdown() {
        logger.info("Shutting down LocalWave TUI...")
        // Future: cleanup resources, save state, etc.
    }
}
