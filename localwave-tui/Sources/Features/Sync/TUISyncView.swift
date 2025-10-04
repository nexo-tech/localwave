//
//  TUISyncView.swift
//  localwave-tui
//
//  Created by Claude Code on 04.10.2025.
//

import SwiftTUI
import LocalWaveDomain
import LocalWaveCore
import LocalWaveData

/// TUI view for browsing and selecting music source folders
struct TUISyncView: View {
    let dependencies: TUIDependencyContainer
    @Binding var navigationState: NavigationState

    @State private var sources: [Source] = []
    @State private var selectedSourceId: Int64?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 1) {
            if isLoading {
                loadingView
            } else if let error = errorMessage {
                errorView(error)
            } else if sources.isEmpty {
                emptyStateView
            } else {
                sourceListView
            }

            helpBar
        }
        .onAppear {
            Task { await loadSources() }
        }
        // Vim-style navigation
        .onKeyPress("j") { selectNext() }
        .onKeyPress("k") { selectPrevious() }
        .onKeyPress("g") { selectFirst() }
        .onKeyPress("G") { selectLast() }
        // Actions
        .onKeyPress("l") { openSelectedSource() }  // vim: go right/into
        .onKeyPress("\r") { openSelectedSource() }  // Enter key
        .onKeyPress("a") { /* TODO: add new source */ }
        .onKeyPress("d") { /* TODO: delete source */ }
        .onKeyPress("r") { Task { await loadSources() } }  // refresh
    }

    private var loadingView: some View {
        VStack {
            Text("Loading sources...")
            Spacer()
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack {
            Text("Error: \(message)")
            Text("")
            Text("Press 'r' to retry")
            Spacer()
        }
    }

    private var emptyStateView: some View {
        VStack {
            Text("No music sources found")
            Text("")
            Text("Press 'a' to add a new source")
            Text("Press 'q' to return")
            Spacer()
        }
    }

    private var sourceListView: some View {
        VStack(spacing: 0) {
            Text("Music Sources (\(sources.count))")
            Text("")

            ForEach(sources) { source in
                let isSelected = source.id == selectedSourceId
                HStack {
                    Text(isSelected ? " > " : "   ")
                    Text(source.dirPath)
                    Spacer()
                }
            }

            Spacer()
        }
    }

    private var helpBar: some View {
        VStack(spacing: 0) {
            Text(String(repeating: "─", count: 60))
            HStack {
                Text("[j/k] Navigate")
                Text(" ")
                Text("[Enter/l] Open")
                Text(" ")
                Text("[a] Add")
                Text(" ")
                Text("[d] Delete")
                Text(" ")
                Text("[r] Refresh")
                Spacer()
            }
        }
    }

    // MARK: - Actions

    private func loadSources() async {
        isLoading = true
        errorMessage = nil

        do {
            // Get current user's sources
            let userId: Int64 = 1  // TODO: Get from user cloud service
            let sourceRepo = dependencies.sourceService.repository()
            let loadedSources = try await sourceRepo.findOneByUserId(userId: userId, path: nil)
            sources = loadedSources
            if let first = sources.first {
                selectedSourceId = first.id
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func openSelectedSource() {
        guard let sourceId = selectedSourceId else { return }
        // Navigate to source browse view
        navigationState.push(.sourceBrowse(sourceId: sourceId, parentPathId: nil))
    }

    private func selectNext() {
        guard !sources.isEmpty,
              let currentId = selectedSourceId,
              let currentIndex = sources.firstIndex(where: { $0.id == currentId }),
              currentIndex < sources.count - 1 else { return }
        selectedSourceId = sources[currentIndex + 1].id
    }

    private func selectPrevious() {
        guard !sources.isEmpty,
              let currentId = selectedSourceId,
              let currentIndex = sources.firstIndex(where: { $0.id == currentId }),
              currentIndex > 0 else { return }
        selectedSourceId = sources[currentIndex - 1].id
    }

    private func selectFirst() {
        guard let first = sources.first else { return }
        selectedSourceId = first.id
    }

    private func selectLast() {
        guard let last = sources.last else { return }
        selectedSourceId = last.id
    }
}

/// Source browse view - navigates folder tree
struct TUISourceBrowseView: View {
    let dependencies: TUIDependencyContainer
    let sourceId: Int64
    let parentPathId: Int64?
    @Binding var navigationState: NavigationState

    @State private var items: [SourcePath] = []
    @State private var selectedIndex = 0
    @State private var expandedFolders = Set<Int64>()
    @State private var isLoading = false
    @State private var errorMessage: String?

    // Track navigation stack manually
    @State private var pathStack: [(pathId: Int64?, name: String)] = [(pathId: nil, name: "Root")]

    var currentPath: (pathId: Int64?, name: String) {
        pathStack.last ?? (pathId: nil, name: "Root")
    }

    var body: some View {
        VStack(spacing: 1) {
            // Breadcrumb
            HStack {
                Text("Browse: ")
                Text(pathStack.map { $0.name }.joined(separator: " > "))
                Spacer()
            }
            Text("")

            if isLoading {
                loadingView
            } else if let error = errorMessage {
                errorView(error)
            } else if items.isEmpty {
                emptyView
            } else {
                itemListView
            }

            helpBar
        }
        .onAppear {
            Task { await loadItems() }
        }
        // Vim-style navigation
        .onKeyPress("j") { selectNext() }
        .onKeyPress("k") { selectPrevious() }
        .onKeyPress("g") { selectFirst() }
        .onKeyPress("G") { selectLast() }
        // Folder navigation
        .onKeyPress("l") { openOrEnterSelected() }  // right/into
        .onKeyPress("\r") { openOrEnterSelected() }  // Enter
        .onKeyPress("h") { goBack() }  // left/back
        // Actions
        .onKeyPress("s") { selectForScanning() }  // scan this folder
        .onKeyPress("r") { Task { await loadItems() } }  // refresh
    }

    private var loadingView: some View {
        VStack {
            Text("Loading...")
            Spacer()
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack {
            Text("Error: \(message)")
            Text("")
            Text("Press 'r' to retry or 'h' to go back")
            Spacer()
        }
    }

    private var emptyView: some View {
        VStack {
            Text("No items in this folder")
            Text("")
            Text("Press 'h' to go back")
            Spacer()
        }
    }

    private var itemListView: some View {
        VStack(spacing: 0) {
            Text("Items (\(items.count))")
            Text("")

            ForEach(items, id: \.pathId) { item in
                let index = items.firstIndex(where: { $0.pathId == item.pathId }) ?? 0
                let isSelected = index == selectedIndex
                let icon = item.isDirectory ? "📁" : "🎵"

                HStack {
                    Text(isSelected ? " > " : "   ")
                    Text(icon)
                    Text(" ")
                    Text(item.name)
                    Spacer()
                }
            }

            Spacer()
        }
    }

    private var helpBar: some View {
        VStack(spacing: 0) {
            Text(String(repeating: "─", count: 60))
            HStack {
                Text("[j/k] Navigate")
                Text(" ")
                Text("[l/Enter] Open")
                Text(" ")
                Text("[h] Back")
                Text(" ")
                Text("[s] Scan")
                Text(" ")
                Text("[r] Refresh")
                Spacer()
            }
        }
    }

    // MARK: - Actions

    private func loadItems() async {
        isLoading = true
        errorMessage = nil

        do {
            let sourceImportService = dependencies.sourceService.importService()
            items = try await sourceImportService.listItems(
                sourceId: sourceId,
                parentPathId: currentPath.pathId
            )
            selectedIndex = 0
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func openOrEnterSelected() {
        guard selectedIndex < items.count else { return }
        let item = items[selectedIndex]

        if item.isDirectory {
            // Enter folder
            pathStack.append((pathId: item.pathId, name: item.name))
            Task { await loadItems() }
        } else {
            // It's a file - maybe show details or play it
            // For now, do nothing with files
        }
    }

    private func goBack() {
        guard pathStack.count > 1 else {
            // At root, go back to sync view
            navigationState.pop()
            return
        }

        pathStack.removeLast()
        Task { await loadItems() }
    }

    private func selectForScanning() {
        guard selectedIndex < items.count else { return }
        let item = items[selectedIndex]

        if item.isDirectory {
            // Navigate to scan view
            navigationState.push(.sourceScan(sourceId: sourceId, pathId: item.pathId, path: item.relativePath))
        }
    }

    private func selectNext() {
        guard !items.isEmpty else { return }
        selectedIndex = min(selectedIndex + 1, items.count - 1)
    }

    private func selectPrevious() {
        guard !items.isEmpty else { return }
        selectedIndex = max(selectedIndex - 1, 0)
    }

    private func selectFirst() {
        selectedIndex = 0
    }

    private func selectLast() {
        selectedIndex = max(items.count - 1, 0)
    }

    private func fileCount(_ item: SourcePath) -> String {
        // TODO: Get actual file count from repository
        // For now, return empty string
        ""
    }
}
