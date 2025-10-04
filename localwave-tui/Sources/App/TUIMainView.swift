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
        // Tab switching with number keys (1-5)
        .onKeyPress("1") { tabState.selectTab(.artists) }
        .onKeyPress("2") { tabState.selectTab(.albums) }
        .onKeyPress("3") { tabState.selectTab(.songs) }
        .onKeyPress("4") { tabState.selectTab(.playlists) }
        .onKeyPress("5") { tabState.selectTab(.player) }
        // Vim-style tab navigation
        .onKeyPress("H") { selectPreviousTab() }
        .onKeyPress("L") { selectNextTab() }
        // Navigation
        .onKeyPress("q") { /* TODO: quit app */ }
        .onKeyPress("?") { /* TODO: show help */ }
        .onKeyPress("/") { /* TODO: show search */ }
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

    private func selectPreviousTab() {
        guard let currentIndex = Tab.allCases.firstIndex(of: tabState.selectedTab),
              currentIndex > 0 else { return }
        tabState.selectTab(Tab.allCases[currentIndex - 1])
    }

    private func selectNextTab() {
        guard let currentIndex = Tab.allCases.firstIndex(of: tabState.selectedTab),
              currentIndex < Tab.allCases.count - 1 else { return }
        tabState.selectTab(Tab.allCases[currentIndex + 1])
    }
}

// MARK: - Placeholder Views

struct ArtistsPlaceholder: View {
    var body: some View {
        VStack {
            Text("Artists View - Coming Soon")
            Text("")
            Text("Keyboard Shortcuts:")
            Text("  1-5: Switch tabs")
            Text("  H/L: Previous/Next tab (vim-style)")
            Text("  q: Quit")
            Text("  ?: Help")
            Text("  /: Search")
            Spacer()
        }
    }
}

struct AlbumsPlaceholder: View {
    var body: some View {
        VStack {
            Text("Albums View - Coming Soon")
            Text("")
            Text("Try pressing 1-5 to switch tabs!")
            Spacer()
        }
    }
}

struct SongsPlaceholder: View {
    var body: some View {
        VStack {
            Text("Songs View - Coming Soon")
            Text("")
            Text("Vim users: Use H/L to navigate tabs")
            Spacer()
        }
    }
}

struct PlaylistsPlaceholder: View {
    var body: some View {
        VStack {
            Text("Playlists View - Coming Soon")
            Text("")
            Text("Press numbers 1-5 or H/L for navigation")
            Spacer()
        }
    }
}

struct PlayerPlaceholder: View {
    var body: some View {
        VStack {
            Text("Player View - Coming Soon")
            Text("")
            Text("Keyboard shortcuts are now working!")
            Spacer()
        }
    }
}
