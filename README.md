# LocalWave

LocalWave is a modern, feature-rich music player for iOS that focuses on local music library management and playback. Built with SwiftUI and following MVVM architecture, it provides a seamless and intuitive experience for managing and enjoying your music collection.

## Features

### 🎵 Music Library Management
- **Artists View**: Browse your music collection by artists with cover art and album counts
- **Albums View**: Grid view of albums with beautiful artwork display
- **Songs View**: Complete list of all songs with search and quick playback
- **Playlists**: Create and manage custom playlists with drag-and-drop reordering

### 🎧 Advanced Playback
- **Full Player**: Beautiful full-screen player with artwork display and playback controls
- **Mini Player**: Compact player that stays accessible while browsing
- **Queue Management**: View and modify the current playback queue
- **Playback Modes**: Support for shuffle and repeat modes
- **Background Playback**: Continue playing music while using other apps
- **Lock Screen Controls**: Control playback from the lock screen

### 🔄 Library Sync
- **Multiple Sources**: Add multiple music directories as sources
- **File Browser**: Intuitive file browser for selecting music directories
- **Auto-Sync**: Automatic synchronization of music library changes
- **Background Sync**: Sync continues even when the app is in the background

### 🎨 Modern UI/UX
- **Dark Mode**: Beautiful dark theme optimized for music playback
- **Custom Navigation**: Smooth and intuitive navigation between views
- **Search**: Powerful search functionality across all views
- **Responsive Design**: Optimized for all iOS devices

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

LocalWave follows the MVVM (Model-View-ViewModel) architecture pattern:

- **Models**: Core data structures and business logic
- **Views**: SwiftUI views for the user interface
- **ViewModels**: State management and business logic for views
- **Repositories**: Data access layer for models
- **Services**: Core services like audio playback and file management

### Directory Structure

```
localwave/
├── Sources/
│   ├── Features/
│   │   ├── Common/
│   │   │   ├── SearchBar.swift
│   │   │   ├── CustomTabView.swift
│   │   │   └── Theme.swift
│   │   ├── Library/
│   │   │   ├── LibraryView.swift
│   │   │   ├── ArtistListView.swift
│   │   │   ├── AlbumGridView.swift
│   │   │   └── ...
│   │   ├── Player/
│   │   │   ├── PlayerViewModel.swift
│   │   │   ├── PlayerView.swift
│   │   │   └── MiniPlayerView.swift
│   │   └── Sync/
│   │       ├── SourceManagementView.swift
│   │       └── FileBrowserView.swift
│   ├── Models/
│   ├── Repositories/
│   └── Services/
└── Tests/
```

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- [SwiftUI](https://developer.apple.com/xcode/swiftui/) - The UI framework
- [AVFoundation](https://developer.apple.com/av-foundation/) - Audio playback
- [Combine](https://developer.apple.com/documentation/combine) - Reactive programming

## Contact

Your Name - [@nexo_v1](https://twitter.com/nexo_v1)

Project Link: [https://github.com/nexo-tech/localwave](https://github.com/nexo-tech/localwave)
