# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

LocalWave is an offline-first iOS music player built with SwiftUI that allows users to manage personal MP3 libraries without relying on Apple Music or iTunes Match. The app uses a layered MVVM architecture with Swift Actors for concurrency-safe operations and SQLite with FTS5 for fast full-text search capabilities.

## Build & Development Commands

### Building and Running
```bash
# Open project in Xcode
open localwave.xcodeproj

# Build and run the project
# Use Xcode's build (⌘R) or build action (⌘B)
```

### Testing
```bash
# Run tests via Xcode Test Navigator or:
# Use Xcode's test action (⌘U)
# Test plan configuration is in localwave.xctestplan
```

The project has two test targets:
- `musicappTests` - Unit tests (parallelizable: false)  
- `musicappUITests` - UI tests (parallelizable: true)

## Architecture Overview

LocalWave follows a clean layered architecture with clear separation of concerns:

### Layer Structure
- **App Layer** (`Sources/App/`): Dependency injection and app initialization
- **Features Layer** (`Sources/Features/`): SwiftUI views and view models organized by feature
- **Domain Layer** (`Sources/Domain/`): Core models and protocol definitions
- **Data Layer** (`Sources/Data/`): Repositories, services, and data providers

### Key Architectural Patterns

**Dependency Injection**: `DependencyContainer` manages all service dependencies and provides factory methods for view models. Services are injected through initializers following explicit dependency patterns.

**Repository Pattern**: All data access goes through repository protocols (`SongRepository`, `PlaylistRepository`, etc.) with SQLite implementations. Repositories handle async operations and use raw SQL for performance.

**Swift Actors**: Business logic actors ensure thread-safe operations for concurrent tasks like file import, search indexing, and background sync.

**MVVM with Combine**: View models use `@Published` properties and async/await patterns. Views bind to view model state through SwiftUI's observation system.

### SQLite Database Architecture

The app uses SQLite with FTS5 (Full-Text Search) tables for fast searching:

- **Primary Tables**: Users, Sources, Songs, Playlists, etc.
- **FTS Tables**: 
  - `songs_fts` - Indexes artist, title, album, albumArtist
  - `source_paths_fts` - Indexes fullPath, fileName
- **Search**: Uses BM25 ranking with async upserts and transaction handling

### File Management System

**Security-Scoped Bookmarks**: Uses persistent file access via security-scoped bookmarks stored in SQLite for accessing user's iCloud files.

**Background Services**: `BackgroundFileService` handles file copying and bookmark verification using Task-based concurrency.

**Import Pipeline**: Multi-stage import process from source discovery → path indexing → metadata extraction → library integration.

## Key Services and Components

### Core Services
- `DefaultSongImportService`: Handles MP3 metadata parsing and library integration
- `DefaultSourceSyncService`: Manages folder scanning and file discovery
- `DefaultPlayerPersistenceService`: Handles playback state restoration
- `BackgroundFileService`: Manages file copying and bookmark validation

### View Model Factories
The `DependencyContainer` provides factory methods for creating view models with proper dependency injection:
- `makeSongListViewModel(filter:)` - For filtered song lists
- `makeArtistListViewModel()` - For artist browsing
- `makeAlbumListViewModel()` - For album browsing  
- `makePlaylistListViewModel()` - For playlist management

### Feature Organization
- **Library**: Artist/Album/Song browsing with metadata editing
- **Player**: Audio playback with mini and full player UIs
- **Playlists**: Custom playlist creation and management
- **Sync**: iCloud folder import and source management
- **Shared**: Reusable UI components and navigation

## Development Guidelines

### Database Schema
Current schema version is defined by `schemaVersion` constant. Database file: `musicApp{schemaVersion}.sqlite`

### Concurrency Patterns
- Use Swift Actors for shared state management
- Repository methods are async and handle SQLite operations safely
- Background tasks use `Task(priority: .utility)` for non-critical operations

### Search Implementation
All search functionality uses FTS5 tables with BM25 ranking. Search queries are processed through dedicated search repositories that handle tokenization and ranking.

### File Access Security
Always use security-scoped bookmarks for file access. The app handles bookmark expiration gracefully with fallback file copying mechanisms.