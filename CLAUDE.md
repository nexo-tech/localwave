# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

LocalWave is an offline-first iOS music player built with SwiftUI that enables users to manage their personal MP3 libraries without relying on Apple Music or iTunes Match. The app uses SQLite with FTS5 for full-text search and follows a clean MVVM + Actor-based architecture.

## Development Commands

### Building and Running
- **Build and run**: Open `localwave.xcodeproj` in Xcode and press ⌘R
- **Run tests**: Use Xcode's test navigator or ⌘U to run the test plan (`localwave.xctestplan`)
- **Test targets**: `musicappTests` (unit tests) and `musicappUITests` (UI tests)

### Xcode Project Structure
- Main target: `localwave` (builds `localwave.app`)
- Test scheme: `musicapp.xcscheme` 
- Uses Swift Testing framework (not XCTest)

## Architecture

The codebase follows a layered MVVM architecture with backend-style separation:

### Core Layers
- **Domain**: Models (`Models.swift`) and protocols (`Protocols.swift`) - pure Swift types
- **Data**: SQLite repositories and services for data access
- **Features**: UI organized by feature with ViewModels and Views
- **App**: Dependency injection container and app entry point

### Key Architectural Patterns
- **Swift Actors**: Used for state-safe business logic (marked with `@MainActor` for UI components)
- **Repository Pattern**: All data access goes through protocol-based repositories
- **Dependency Injection**: Centralized in `DependencyContainer.swift`
- **SQLite with FTS5**: Raw SQL queries via SQLite.swift, no CoreData

### Directory Structure
```
localwave/Sources/
├── App/                    # DependencyContainer, MusicApp entry point
├── Core/                   # Utils.swift - shared utilities and constants
├── Domain/                 # Models.swift, Protocols.swift
├── Data/
│   ├── Repositories/       # SQLite*Repository classes
│   ├── Services/           # Default*Service implementations  
│   └── Providers/          # DefaultICloudProvider
└── Features/
    ├── Common/             # Shared UI components (ThemeProvider, ErrorView)
    ├── Library/            # Artist/Album/Song views and ViewModels
    ├── Player/             # Audio playback UI and logic
    ├── Playlists/          # Playlist management
    ├── Shared/             # Tab system (CustomTabView, MainTabView)
    └── Sync/               # iCloud sync and source browsing
```

## Key Technical Details

### Database Schema
- **Schema version**: Tracked in `Utils.swift` as `schemaVersion = 29`
- **FTS5 tables**: `songs_fts` (artist/title/album search) and `source_paths_fts` (file path search)
- **Core entities**: User, Source, SourcePath, Song, Playlist, PlaylistSong

### Important Constants
- **Subsystem**: `"com.snowbear.localwave"` for logging
- **Database**: `"musicApp{schemaVersion}.sqlite"`

### Testing
- Uses Swift Testing framework (import Testing)
- Test structure: `@Test func testName() async throws`
- Example tests in `Tests.swift` cover FileHelper utilities

### Dependencies
- **SQLite.swift**: Database access layer
- **AVFoundation**: Audio playback
- **CryptoKit**: For hashing and security
- **SwiftUI/Combine**: UI framework

## Development Notes

- All ViewModels are marked `@MainActor` for thread safety
- Repository protocols define async interfaces for data operations
- Services layer implements business logic between repositories and ViewModels
- Full-text search uses BM25 ranking with SQLite FTS5
- File access uses security-scoped bookmarks for persistent iCloud access
