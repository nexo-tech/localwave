### TL;DR

Break **App.swift** into _Domain_, _Data_, _Services_, and _Bootstrap_ pieces; slice **View\.swift** into per-feature folders (**Library**, **Player**, **Sync**, **Playlists**, plus **Shared** UI components).
Name folders after the layer they belong to (Domain, Data, Presentation, etc.) and after the feature they implement. Each file should hold one type (or a very small, obviously-related group).

---

## 1. Suggested top-level folders

```
Sources/
├─ App                 // entry point & DI
├─ Core                // stateless helpers, logging, constants
├─ Domain              // pure business logic
│  ├─ Models
│  ├─ Protocols        // repo & service interfaces
│  └─ UseCases         // if you want explicit interactor layer
├─ Data                // concrete persistence / network
│  ├─ Repositories     // SQLite* files
│  └─ Services         // FileImporter, iCloudProvider…
└─ Features            // UI + feature-specific VMs
   ├─ Library
   ├─ Player
   ├─ Sync
   ├─ Playlists
   └─ Shared           // SearchBar, CustomTabView, MiniPlayer…
```

_(If the project starts feeling heavy, turn **Core**, **Domain** and **Data** into Swift Packages and make **Features** the app target.)_

---

## 2. Where the big things go

| Code you have now                                                        | Move to                              | Why                                  |
| ------------------------------------------------------------------------ | ------------------------------------ | ------------------------------------ |
| **Models** (`Song`, `Album`, `Playlist`…)                                | `Domain/Models`                      | Pure data, no UIKit / SwiftUI        |
| **Protocols** (`SongRepository`, `SourceSyncService`…)                   | `Domain/Protocols`                   | Define behaviour without deps        |
| \*_SQLite_ repos*\*, `Default*Service`, `BackgroundFileService`          | `Data/Repositories`, `Data/Services` | Implementation detail of Domain      |
| **Utility fns** (`hashStringToInt64`, `makeURLHash`…)                    | `Core/Utils`                         | Stateless helpers, reused everywhere |
| **DependencyContainer**, `musicappApp`, `AppDelegate`                    | `App`                                | App bootstrap & DI only              |
| **ViewModels**                                                           | `Features/<Feature>/ViewModels`      | Each VM lives next to its Views      |
| **View structs**                                                         | `Features/<Feature>/Views`           | Keep feature files < \~300 LOC       |
| **Reusable UI widgets** (`SearchBar`, `SongRow`, `MiniPlayerViewInner`…) | `Features/Shared`                    | Importable by any feature            |

---

## 3. Splitting _App.swift_

1. **Move every `struct`/`actor`/`enum` into its own file** under the folder above.
2. Keep just:

```swift
@main
struct MusicApp: App {
    @StateObject private var container = DependencyContainer()

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(container)
                .applyTheme()
        }
    }
}
```

3. Put `DependencyContainer` in **App/DependencyContainer.swift** (it wires Core/Domain/Data together, nothing else).

---

## 4. Splitting _View\.swift_

_Rule of thumb: one SwiftUI file \~= one screen or one reusable component._

```
Features/
├─ Library/
│  ├─ Views/
│  │   ├─ LibraryView.swift          // entry
│  │   ├─ AlbumGridView.swift
│  │   └─ ...
│  └─ ViewModels/
│      └─ LibraryNavigation.swift
├─ Player/
│  ├─ Views/
│  │   ├─ PlayerView.swift
│  │   └─ MiniPlayerView.swift
│  └─ ViewModels/
│      └─ PlayerViewModel.swift
├─ Sync/
│  ├─ Views/ …
│  └─ ViewModels/ …
├─ Playlists/
│  ├─ Views/ …
│  └─ ViewModels/ …
└─ Shared/
   ├─ SearchBar.swift
   ├─ CustomTabView.swift
   ├─ SongRow.swift
   └─ Fonts.swift
```

(When a component is used by more than one feature, migrate it to **Shared**.)

---

## 5. Why this works

- **Understandability** – you jump straight to `Features/Player` when a bug is reported in the player UI.
- **Build times** – splitting into Swift Packages lets Xcode cache more.
- **Testability** – Domain and Data compile without SwiftUI, so pure-logic tests run fast.

---

### Next step?

Create the folders, do a **type-at-a-time** move (Xcode will fix imports), and add a small README in each layer explaining its boundaries – future-you (and teammates) will thank you!
