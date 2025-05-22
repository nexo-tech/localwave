# LocalWave

![Screenshots](https://nexo.sh/posts/why-i-built-a-native-mp3-player-in-swiftui/frame_source.webp)

LocalWave is an **offline-first** music player for iOS that enables full control of your personal MP3 library without relying on Apple Music or iTunes Match. Built with SwiftUI and structured using a layered MVVM + Actor-based architecture, LocalWave prioritizes offline use and searchability. It was designed out of frustration with Apple's closed ecosystem and lack of decent support for self-hosted MP3 libraries. [Link to the article](https://nexo.sh/posts/why-i-built-a-native-mp3-player-in-swiftui/)

## Why LocalWave Exists

In 2025, Apple still restricts basic MP3 playback unless you pay for services like Apple Music or iTunes Match. LocalWave was built from scratch as a personal response to these limitations. It allows users to:

- Import MP3 files from iCloud or Files app using persistent bookmarks
- Build and search their own curated music libraries
- Avoid subscriptions or cloud lock-in
- Leverage native performance and Swift concurrency for a smooth user experience

## Features

### 🎵 Music Library Management

- **Artists / Albums / Songs Views**: Browse, sort, and search with artwork and metadata
- **Full-Text Search (FTS5)**: Search across title, artist, album, and path with SQLite-powered fuzzy matching
- **Playlists**: Create custom playlists with drag-and-drop reordering
- **Library Sync**: Import music folders recursively from iCloud using background sync services

### 🎧 Advanced Playback

- **AVFoundation-Based Audio Playback**: Full support for MP3s with lock screen controls
- **Mini and Full Player UI**: Seamless transitions and persistent playback
- **Queue Management**: Shuffle, repeat, and reorder tracks
- **Background Playback**: Continues playing while the app is backgrounded

### 📁 Filesystem and iCloud Sync

- **Persistent File Access via Security-Scoped Bookmarks**: Stores references safely in SQLite
- **Fallback File Copying**: Copies MP3s into app container while bookmarks are still valid
- **Multi-source Import**: Add and merge multiple folder trees into a unified library

### 🔍 Full-Text Search Engine

- **Powered by SQLite FTS5**: Fast and lightweight search without any cloud dependencies
- **BM25 Ranking**: Smart search results prioritization
- **Async Upserts and Transaction Handling**: Keeps search indexes reliable and performant

### 🧠 Architecture Highlights

- **Swift Actors**: State-safe, concurrency-friendly domain logic
- **MVVM Layering**: Clear separation between View, ViewModel, Repository, and Domain layers
- **SQLite with FTS5**: Used instead of CoreData for tighter schema and query control

## Requirements

- iOS 15.0+
- Xcode 13.0+
- Swift 5.5+

## Installation

1. Clone the repository:

```bash
git clone https://github.com/nexo-tech/localwave.git
```

2. Open the project in Xcode:

```bash
cd localwave
open localwave.xcodeproj
```

3. Build and run the project (⌘R)

## Architecture

LocalWave follows a clean-layered MVVM architecture with a backend-style separation of logic:

- **Models**: Core types for songs, albums, metadata, and state
- **Repositories**: Async interfaces over SQLite using raw SQL and SQLite.swift
- **Actors**: Swift actors encapsulate business rules (search, import, playback queue)
- **ViewModels**: Subscribe to actors and provide bindable UI state
- **Views**: SwiftUI-based UI rendering from ViewModel output
- **Services**: Playback, file access, metadata parsing, remote control handling

### Directory Structure

```
localwave/
├── Sources/
│   ├── Features/
│   │   ├── Common/
│   │   ├── Library/
│   │   ├── Player/
│   │   └── Sync/
│   ├── Models/
│   ├── Repositories/
│   └── Services/
└── Tests/
```

### Data Model and FTS Tables

| Domain            | Actor / Repo                       | FTS Table          | Indexed Columns                           |
| ----------------- | ---------------------------------- | ------------------ | ----------------------------------------- |
| Library Songs     | `SQLiteSongRepository`             | `songs_fts`        | `artist`, `title`, `album`, `albumArtist` |
| File Import Paths | `SQLiteSourcePathSearchRepository` | `source_paths_fts` | `fullPath`, `fileName`                    |

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Apple Developer Documentation (AVFoundation, SwiftUI, Combine)
- `SQLite` and [`SQLite.swift`](https://github.com/stephencelis/SQLite.swift)
- `AVAudioPlayer` and `MPRemoteCommandCenter`
- GitHub contributors for open-source ID3 parsing examples

## Contact

Oleg Pustovit - [@nexo_v1](https://twitter.com/nexo_v1)

Project Link: [https://github.com/nexo-tech/localwave](https://github.com/nexo-tech/localwave)
