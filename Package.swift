// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "localwave-tui",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "localwave-tui",
            targets: ["localwave-tui"]
        )
    ],
    dependencies: [
        // SwiftTUI for terminal interface
        .package(url: "https://github.com/rensbreur/SwiftTUI.git", from: "0.1.0"),
        // SQLite.swift - shared with iOS app
        .package(url: "https://github.com/stephencelis/SQLite.swift", from: "0.15.3")
    ],
    targets: [
        // TUI executable target
        .executableTarget(
            name: "localwave-tui",
            dependencies: [
                "SwiftTUI",
                .product(name: "SQLite", package: "SQLite.swift")
            ],
            path: "localwave-tui/Sources",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        ),
        // Shared core library (Domain + Data layers)
        // This allows code sharing between iOS and TUI targets
        .target(
            name: "LocalWaveCore",
            dependencies: [
                .product(name: "SQLite", package: "SQLite.swift")
            ],
            path: "localwave/Sources",
            exclude: [
                // Exclude iOS-specific files
                "Features/Common/AppDelegate.swift",
                "Features/Shared/TabState.swift",
                "Features/Common/RepeatMode.swift",
                "Features/Common/coverArt.swift",
                // Exclude SwiftUI views (iOS only)
                "Features/Library/Views",
                "Features/Player/Views",
                "Features/Playlists/Views",
                "Features/Sync/Views",
                "Features/Shared",
                "Features/Common/ThemeProvider.swift",
                "Features/Common/ErrorView.swift",
                // Exclude AVFoundation-heavy ViewModels for now
                "Features/Player/ViewModels"
            ],
            sources: [
                "Core",
                "Domain",
                "Data"
                // Note: BackgroundFileService already in Data/Services
            ]
        )
    ]
)
