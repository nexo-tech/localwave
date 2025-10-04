# LocalWave TUI Implementation Plan

## Master Checklist

### Phase 1: Foundation & Setup
- [ ] 1.1 Create TUI target and basic structure
- [ ] 1.2 Add SwiftTUI dependency and shared code infrastructure
- [ ] 1.3 Create TUI-specific dependency injection
- [ ] 1.4 Build platform abstraction layer

### Phase 2: Core TUI Components
- [ ] 2.1 Implement base TUI navigation system
- [ ] 2.2 Create reusable TUI component library
- [ ] 2.3 Build TUI theme and styling system
- [ ] 2.4 Implement keyboard input handling

### Phase 3: Library Features
- [ ] 3.1 Build artist list TUI view
- [ ] 3.2 Build album list TUI view
- [ ] 3.3 Build song list TUI view
- [ ] 3.4 Implement search functionality

### Phase 4: Player Features
- [ ] 4.1 Create player status display
- [ ] 4.2 Implement playback controls
- [ ] 4.3 Build queue management view
- [ ] 4.4 Add progress bar and time display

### Phase 5: Playlist Management
- [ ] 5.1 Build playlist list view
- [ ] 5.2 Implement playlist detail view
- [ ] 5.3 Add playlist creation/editing
- [ ] 5.4 Build song selection for playlists

### Phase 6: Integration & Polish
- [ ] 6.1 Connect all TUI views with navigation
- [ ] 6.2 Add help system and keyboard shortcuts
- [ ] 6.3 Implement status bar and notifications
- [ ] 6.4 Add error handling and recovery

---

## Phase 1: Foundation & Setup

### Task 1.1: Create TUI Target and Basic Structure
**Files to create:**
- `localwave-tui/Sources/main.swift` (50 lines)
- `localwave-tui/Sources/App/TUIApp.swift` (80 lines)

**Description:**
- Create new executable target `localwave-tui` in Xcode project
- Set up basic SwiftTUI application entry point
- Configure target to use macOS platform
- Create initial directory structure mirroring main app architecture

**Key code structure:**
```swift
// main.swift
import SwiftTUI

@main
struct LocalWaveTUI {
    static func main() async {
        do {
            let app = try TUIApp()
            try await app.start()
        } catch {
            print("Error: \(error)")
        }
    }
}
```

---

### Task 1.2: Add SwiftTUI Dependency and Shared Code Infrastructure
**Files to modify:**
- `localwave.xcodeproj/project.pbxproj` (configure)
- Create `Package.swift` if not exists (50 lines)

**Files to create:**
- `localwave-tui/Sources/Core/SharedTypes.swift` (100 lines)

**Description:**
- Add SwiftTUI package dependency to project
- Configure build settings for TUI target
- Create type aliases and protocol extensions to bridge SwiftUI/SwiftTUI differences
- Set up shared model types accessible from both targets

**Key dependencies:**
```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/rensbreur/SwiftTUI.git", from: "1.0.0"),
    .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.14.1")
]
```

---

### Task 1.3: Create TUI-Specific Dependency Injection
**Files to create:**
- `localwave-tui/Sources/App/TUIDependencyContainer.swift` (150 lines)

**Description:**
- Create TUI version of DependencyContainer
- Reuse all Data layer repositories and services
- Initialize SQLite connection for CLI context
- Create factory methods for TUI ViewModels
- Remove AVFoundation dependencies, use CLI-compatible audio if needed

**Key patterns:**
```swift
@MainActor
class TUIDependencyContainer {
    let songRepository: SongRepository
    let playlistRepo: PlaylistRepository
    let sourceService: SourceService

    // Reuse ViewModels from main app
    func makeSongListViewModel(filter: SongListViewModel.Filter) -> SongListViewModel {
        SongListViewModel(songRepo: songRepository, filter: filter)
    }
}
```

---

### Task 1.4: Build Platform Abstraction Layer
**Files to create:**
- `localwave/Sources/Core/Platform/PlatformTypes.swift` (120 lines)
- `localwave/Sources/Core/Platform/AudioPlayer.swift` (150 lines)

**Description:**
- Create protocol-based abstraction for platform-specific features
- Abstract audio playback (AVAudioPlayer for iOS, CLI stub for TUI)
- Abstract image loading (UIImage vs terminal color blocks)
- Create shared logging that works in both contexts
- Make existing ViewModels platform-agnostic

**Key abstractions:**
```swift
protocol AudioPlayerProtocol {
    var isPlaying: Bool { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }

    func play() async
    func pause()
    func seek(to: TimeInterval)
}

// iOS implementation uses AVAudioPlayer
// TUI implementation uses mpg123/afplay CLI tools or stubs
```

---

## Phase 2: Core TUI Components

### Task 2.1: Implement Base TUI Navigation System
**Files to create:**
- `localwave-tui/Sources/TUIComponents/Navigation/NavigationStack.swift` (180 lines)
- `localwave-tui/Sources/TUIComponents/Navigation/TabBar.swift` (120 lines)

**Description:**
- Create stack-based navigation similar to iOS NavigationStack
- Implement tab bar with keyboard shortcuts (1-5 for tabs)
- Track navigation state and breadcrumbs
- Handle back navigation with Esc or Backspace

**Key features:**
- Tab switching: `1` Artists, `2` Albums, `3` Songs, `4` Playlists, `5` Player
- Stack navigation for drilling into details
- Breadcrumb display at top of screen

---

### Task 2.2: Create Reusable TUI Component Library
**Files to create:**
- `localwave-tui/Sources/TUIComponents/UI/List.swift` (200 lines)
- `localwave-tui/Sources/TUIComponents/UI/Table.swift` (180 lines)
- `localwave-tui/Sources/TUIComponents/UI/ProgressBar.swift` (100 lines)
- `localwave-tui/Sources/TUIComponents/UI/InputField.swift` (120 lines)

**Description:**
- Build scrollable list component with selection
- Create table view for multi-column data
- Implement progress bar for playback
- Create input field for search
- All components support keyboard navigation (arrows, enter, tab)

**Key patterns:**
```swift
struct TUIList<Item, Content: View>: View {
    let items: [Item]
    @Binding var selection: Item?
    let content: (Item) -> Content
    @State private var focusedIndex: Int = 0
}
```

---

### Task 2.3: Build TUI Theme and Styling System
**Files to create:**
- `localwave-tui/Sources/TUIComponents/Theme/TUITheme.swift` (150 lines)
- `localwave-tui/Sources/TUIComponents/Theme/ColorScheme.swift` (80 lines)

**Description:**
- Define color scheme using ANSI/xterm colors
- Create text styles (title, subtitle, body, highlight)
- Define layout constants (padding, spacing)
- Build theme provider similar to main app's ThemeProvider

**Key elements:**
- Primary color: Blue for selections
- Secondary color: Gray for inactive
- Accent color: Green for playing status
- Background: Terminal default
- Borders: Box-drawing characters

---

### Task 2.4: Implement Keyboard Input Handling
**Files to create:**
- `localwave-tui/Sources/TUIComponents/Input/KeyboardHandler.swift` (200 lines)
- `localwave-tui/Sources/TUIComponents/Input/Shortcuts.swift` (100 lines)

**Description:**
- Create centralized keyboard event handling
- Define global shortcuts (space = play/pause, q = quit)
- Support context-specific shortcuts
- Build help overlay showing available shortcuts

**Key shortcuts:**
- Global: `Space` play/pause, `Q` quit, `?` help, `/` search
- Navigation: `↑↓` select, `Enter` open, `Esc` back, `1-5` tabs
- Player: `→` next, `←` previous, `+/-` volume

---

## Phase 3: Library Features

### Task 3.1: Build Artist List TUI View
**Files to create:**
- `localwave-tui/Sources/Features/Library/TUIArtistListView.swift` (180 lines)

**Description:**
- Display scrollable list of artists
- Show song count per artist
- Support keyboard selection and navigation
- Reuse ArtistListViewModel from main app
- Navigate to artist detail on Enter

**UI mockup:**
```
┌─ Artists ─────────────────────────────────┐
│ > The Beatles                     (142)   │
│   Pink Floyd                       (98)   │
│   Led Zeppelin                     (87)   │
│   ...                                     │
└───────────────────────────────────────────┘
[↑↓] Navigate [Enter] Select [/] Search [Tab] Next
```

---

### Task 3.2: Build Album List TUI View
**Files to create:**
- `localwave-tui/Sources/Features/Library/TUIAlbumListView.swift` (200 lines)

**Description:**
- Display albums in table format (Album | Artist | Year | Songs)
- Support sorting by different columns
- Use AlbumListViewModel from main app
- Show basic cover art using colored blocks/ASCII if available

**UI mockup:**
```
┌─ Albums ──────────────────────────────────────────┐
│ Album              Artist          Year   Songs   │
├───────────────────────────────────────────────────┤
│ > Abbey Road      The Beatles     1969     17    │
│   Dark Side...    Pink Floyd      1973     10    │
│   ...                                            │
└───────────────────────────────────────────────────┘
```

---

### Task 3.3: Build Song List TUI View
**Files to create:**
- `localwave-tui/Sources/Features/Library/TUISongListView.swift` (220 lines)

**Description:**
- Display songs in table (Title | Artist | Album | Duration)
- Support multi-select for queue management
- Reuse SongListViewModel
- Show playing indicator (♫) next to current song
- Support filtering by artist/album

**UI mockup:**
```
┌─ Songs ──────────────────────────────────────────────┐
│ Title           Artist         Album         Time    │
├──────────────────────────────────────────────────────┤
│ ♫ Come Together The Beatles   Abbey Road    4:20    │
│   Something     The Beatles    Abbey Road    3:03    │
│   ...                                                │
└──────────────────────────────────────────────────────┘
```

---

### Task 3.4: Implement Search Functionality
**Files to create:**
- `localwave-tui/Sources/Features/Library/TUISearchView.swift` (180 lines)

**Description:**
- Create search overlay activated by `/` key
- Use FTS5 search via SongRepository
- Display results in real-time as user types
- Support navigating to search results
- Esc to close search

**Key features:**
- Live search with debouncing
- Show match count
- Highlight matching terms
- Quick play from search results

---

## Phase 4: Player Features

### Task 4.1: Create Player Status Display
**Files to create:**
- `localwave-tui/Sources/Features/Player/TUIPlayerStatusBar.swift` (150 lines)

**Description:**
- Create compact player status bar (always visible at bottom)
- Show: Now Playing | Artist - Title | [Progress] | Time | Status
- Update in real-time using PlayerViewModel
- Display play/pause state, shuffle, repeat indicators

**UI mockup:**
```
┌──────────────────────────────────────────────────────┐
│ ▶ The Beatles - Come Together                       │
│ [████████──────────] 2:30 / 4:20  🔀 🔁            │
└──────────────────────────────────────────────────────┘
```

---

### Task 4.2: Implement Playback Controls
**Files to create:**
- `localwave-tui/Sources/Features/Player/TUIPlayerControlsView.swift` (200 lines)

**Description:**
- Create dedicated player view (Tab 5)
- Large now-playing display with metadata
- Interactive controls: play/pause, prev, next, seek
- Volume control
- Shuffle/repeat toggles
- Reuse PlayerViewModel

**UI layout:**
```
┌─ Now Playing ──────────────────────────────────────┐
│                                                     │
│          🎵  Come Together                         │
│              The Beatles                           │
│              Abbey Road (1969)                     │
│                                                     │
│     [████████████████──────────────]              │
│            2:30 / 4:20                            │
│                                                     │
│     [◀◀]  [⏸]  [▶▶]     Vol: [████──]           │
│                                                     │
│     Shuffle: ON   Repeat: All                      │
└─────────────────────────────────────────────────────┘
```

---

### Task 4.3: Build Queue Management View
**Files to create:**
- `localwave-tui/Sources/Features/Player/TUIQueueView.swift` (220 lines)

**Description:**
- Display current playback queue
- Show current song highlighted
- Support reordering (move up/down with shortcuts)
- Remove songs from queue
- Clear queue option
- Access via `Q` shortcut from anywhere

**Key features:**
- Current song always visible (centered)
- Show queue position (3/15)
- Drag-free reordering with keyboard

---

### Task 4.4: Add Progress Bar and Time Display
**Files to create:**
- `localwave-tui/Sources/Features/Player/TUIProgressView.swift` (120 lines)

**Description:**
- Create high-fidelity progress bar
- Support seeking by typing time or percentage
- Show elapsed/remaining time
- Update smoothly (1-second intervals)
- Visual feedback during seeking

**Technical details:**
- Use Unicode block characters for smooth bar: `▏▎▍▌▋▊▉█`
- Support click-to-seek if terminal supports mouse
- Keyboard seek: `[` -10s, `]` +10s

---

## Phase 5: Playlist Management

### Task 5.1: Build Playlist List View
**Files to create:**
- `localwave-tui/Sources/Features/Playlists/TUIPlaylistListView.swift` (180 lines)

**Description:**
- Display all playlists with song counts
- Reuse PlaylistListViewModel
- Support creating new playlist
- Delete playlist with confirmation
- Navigate to playlist detail

**UI mockup:**
```
┌─ Playlists ────────────────────────────────────────┐
│ > Favorites                              (45)      │
│   Workout Mix                            (23)      │
│   Chill Vibes                            (67)      │
│   ...                                              │
│                                                     │
│ [N] New Playlist  [Del] Delete  [Enter] Open       │
└─────────────────────────────────────────────────────┘
```

---

### Task 5.2: Implement Playlist Detail View
**Files to create:**
- `localwave-tui/Sources/Features/Playlists/TUIPlaylistDetailView.swift` (200 lines)

**Description:**
- Show playlist name and metadata
- List songs in playlist with positions
- Reuse PlaylistDetailViewModel
- Support playing playlist
- Remove songs from playlist
- Reorder songs

**Features:**
- Play entire playlist
- Play from selected song
- Shuffle playlist
- Edit playlist name

---

### Task 5.3: Add Playlist Creation/Editing
**Files to create:**
- `localwave-tui/Sources/Features/Playlists/TUIPlaylistEditorView.swift` (150 lines)

**Description:**
- Modal form for playlist name
- Validation (non-empty name)
- Create new or rename existing
- Cancel/confirm actions
- Focus management for text input

**UI mockup:**
```
┌─ Create Playlist ──────────────────┐
│                                     │
│ Name: [Favorites____________]      │
│                                     │
│    [Enter] Create  [Esc] Cancel    │
└─────────────────────────────────────┘
```

---

### Task 5.4: Build Song Selection for Playlists
**Files to create:**
- `localwave-tui/Sources/Features/Playlists/TUISongSelectionView.swift` (220 lines)

**Description:**
- Multi-select song list
- Search/filter songs
- Add selected songs to playlist
- Show checkboxes for selection state
- Support select all/none

**Features:**
- Visual selection indicators `[✓]` / `[ ]`
- Toggle selection with Space
- Batch add to playlist

---

## Phase 6: Integration & Polish

### Task 6.1: Connect All TUI Views with Navigation
**Files to create:**
- `localwave-tui/Sources/App/TUIRootView.swift` (250 lines)

**Description:**
- Build main container view
- Integrate tab bar navigation
- Wire up all feature views
- Manage navigation state
- Connect player status bar to all screens

**Architecture:**
```swift
struct TUIRootView: View {
    @StateObject var container: TUIDependencyContainer
    @State var selectedTab: Tab = .artists
    @State var navigationPath: [Route] = []

    var body: some View {
        VStack {
            NavigationContainer(path: $navigationPath) {
                TabView(selection: $selectedTab) {
                    // All feature views
                }
            }
            TUIPlayerStatusBar(player: container.playerViewModel)
        }
    }
}
```

---

### Task 6.2: Add Help System and Keyboard Shortcuts
**Files to create:**
- `localwave-tui/Sources/Features/Help/TUIHelpView.swift` (180 lines)
- `localwave-tui/Sources/Features/Help/ShortcutRegistry.swift` (150 lines)

**Description:**
- Create comprehensive help overlay (activated with `?`)
- Document all keyboard shortcuts by context
- Show current context shortcuts
- Build searchable command palette

**Help categories:**
- Global shortcuts
- Navigation shortcuts
- Player shortcuts
- List navigation shortcuts
- Context-specific shortcuts

---

### Task 6.3: Implement Status Bar and Notifications
**Files to create:**
- `localwave-tui/Sources/TUIComponents/UI/StatusBar.swift` (120 lines)
- `localwave-tui/Sources/TUIComponents/UI/ToastNotification.swift` (100 lines)

**Description:**
- Create top status bar showing app state
- Display breadcrumb navigation
- Show notifications (song added to queue, playlist created, etc.)
- Implement toast messages with auto-dismiss

**Status bar content:**
- Left: Breadcrumb (Artists > The Beatles > Abbey Road)
- Center: Current time
- Right: Song count, queue length

---

### Task 6.4: Add Error Handling and Recovery
**Files to create:**
- `localwave-tui/Sources/Core/TUIErrorHandler.swift` (180 lines)
- `localwave-tui/Sources/TUIComponents/UI/ErrorView.swift` (120 lines)

**Description:**
- Create centralized error handling
- Display user-friendly error messages
- Support retry actions
- Log errors for debugging
- Graceful degradation for missing features

**Error scenarios:**
- Database connection failures
- Audio file access errors
- Invalid input handling
- Network/iCloud errors (if applicable)

---

## Implementation Guidelines

### Code Reusability Strategy
1. **Shared Domain Layer**: All Models, Protocols unchanged
2. **Shared Data Layer**: All Repositories, Services reused 100%
3. **Shared ViewModels**: Reuse existing ViewModels by making them platform-agnostic
4. **Platform-Specific Views**: Create TUI versions of all SwiftUI views
5. **Platform Abstraction**: Abstract AVFoundation, UIKit dependencies

### File Size Targets
- Each task creates files of **50-250 lines**
- Break down larger components into sub-components
- Use composition over large monolithic files
- Prefer multiple small files over fewer large ones

### Testing Strategy
- Unit test shared business logic (ViewModels, Services)
- Integration test database operations
- Manual TUI testing for UI/navigation
- Use existing test infrastructure

### Dependencies
- **Shared**: SQLite.swift, CryptoKit
- **TUI-only**: SwiftTUI
- **iOS-only**: AVFoundation, SwiftUI, MediaPlayer

### Build Configuration
- Create separate schemes for iOS and TUI targets
- Share code via proper target membership
- Use conditional compilation (`#if os(macOS)`) sparingly
- Prefer protocol abstraction over preprocessor

### Development Order
Follow phases 1-6 in sequence. Each phase builds on previous phases. Can parallelize tasks within same phase if dependencies allow.

---

## Success Criteria

### Phase 1 Complete When:
- TUI target builds and runs
- Can connect to SQLite database
- Basic app structure in place

### Phase 2 Complete When:
- Can navigate between tabs
- Lists display and scroll
- Keyboard input works reliably

### Phase 3 Complete When:
- Can browse artists, albums, songs
- Search returns results
- Can select items and navigate

### Phase 4 Complete When:
- Can play songs (even if stubbed initially)
- Player controls respond
- Queue displays correctly

### Phase 5 Complete When:
- Can create/delete playlists
- Can add/remove songs from playlists
- Playlists persist across restarts

### Phase 6 Complete When:
- All features work together seamlessly
- Help system documents all features
- Errors handled gracefully
- User can accomplish all core workflows via TUI

---

## Technical Notes

### Platform Abstraction Example
```swift
// Shared ViewModel - no platform dependencies
@MainActor
class PlayerViewModel: ObservableObject {
    @Published var currentSong: Song?
    @Published var isPlaying = false

    private let audioPlayer: AudioPlayerProtocol

    init(audioPlayer: AudioPlayerProtocol) {
        self.audioPlayer = audioPlayer
    }
}

// iOS implementation
class AVAudioPlayerAdapter: AudioPlayerProtocol {
    private var player: AVAudioPlayer?
    // Implementation using AVFoundation
}

// TUI implementation
class CLIAudioPlayerAdapter: AudioPlayerProtocol {
    // Implementation using afplay or stub
}
```

### SwiftTUI Differences from SwiftUI
- No images (use colored blocks or ASCII art)
- Limited animations (not needed for TUI)
- Different layout system (character-based grid)
- Keyboard-first interaction model
- No gestures, touch, or mouse (initially)

### Performance Considerations
- TUI redraws entire screen frequently
- Keep view hierarchies shallow
- Minimize state changes
- Debounce user input for search
- Lazy load large lists

### Accessibility
- Clear visual hierarchy with borders
- High contrast text
- Keyboard-only navigation
- Screen reader friendly text output
- Consistent shortcuts

---

## Estimated Effort

| Phase | Tasks | Approx Lines | Time Estimate |
|-------|-------|--------------|---------------|
| 1 | 4 | ~500 | 4-6 hours |
| 2 | 4 | ~800 | 6-8 hours |
| 3 | 4 | ~800 | 6-8 hours |
| 4 | 4 | ~700 | 6-8 hours |
| 5 | 4 | ~750 | 5-7 hours |
| 6 | 4 | ~750 | 6-8 hours |
| **Total** | **24** | **~4300** | **33-45 hours** |

Each task is designed to be completable in 1-2 hours of focused work.

---

## Future Enhancements (Post-MVP)
- Mouse support for terminals that support it
- Theme customization (light/dark, color schemes)
- Visualizer using ASCII art
- Lyrics display
- Advanced search with filters
- Batch operations on songs/playlists
- Statistics and listening history
- Export/import playlists
- Integration with system media keys
- Remote control via network
