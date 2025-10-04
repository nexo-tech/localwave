//
//  TUIMainView.swift
//  localwave-tui
//
//  Created by Claude Code on 04.10.2025.
//

import SwiftTUI

/// Main view for the TUI application with tab bar and navigation
struct TUIMainView: View {
    let dependencies: TUIDependencyContainer

    @State var tabState = TabBarState()
    @State var navigationState = NavigationState()

    var body: some View {
        TUITabView(tabState: $tabState) { selectedTab in
            NavigationContainer(navigationState: $navigationState) { navState in
                contentView(for: selectedTab, navigationState: navState)
            }
        }
    }

    @ViewBuilder
    private func contentView(for tab: Tab, navigationState: Binding<NavigationState>) -> some View {
        switch tab {
        case .artists:
            ArtistsPlaceholder()
        case .albums:
            AlbumsPlaceholder()
        case .songs:
            SongsPlaceholder()
        case .playlists:
            PlaylistsPlaceholder()
        case .player:
            PlayerPlaceholder()
        }
    }
}

// MARK: - Placeholder Views

struct ArtistsPlaceholder: View {
    var body: some View {
        VStack {
            Text("Artists View - Coming Soon")
            Spacer()
        }
    }
}

struct AlbumsPlaceholder: View {
    var body: some View {
        VStack {
            Text("Albums View - Coming Soon")
            Spacer()
        }
    }
}

struct SongsPlaceholder: View {
    var body: some View {
        VStack {
            Text("Songs View - Coming Soon")
            Spacer()
        }
    }
}

struct PlaylistsPlaceholder: View {
    var body: some View {
        VStack {
            Text("Playlists View - Coming Soon")
            Spacer()
        }
    }
}

struct PlayerPlaceholder: View {
    var body: some View {
        VStack {
            Text("Player View - Coming Soon")
            Spacer()
        }
    }
}
