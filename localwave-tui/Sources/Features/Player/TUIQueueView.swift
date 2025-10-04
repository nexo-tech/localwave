//
//  TUIQueueView.swift
//  localwave-tui
//
//  Created by Claude Code on 05.10.2025.
//

import SwiftTUI
import LocalWaveDomain
import LocalWaveCore
import LocalWaveData
import LocalWavePlayer

/// TUI queue management view
///
/// Features:
/// - Display current playback queue
/// - Highlight currently playing song
/// - Navigate with j/k
/// - Remove songs with Delete/Backspace
/// - Clear entire queue with 'c'
/// - Move songs up/down with Ctrl+k/Ctrl+j
@MainActor
struct TUIQueueView: View {
    @ObservedObject var playerViewModel: BasePlayerViewModel
    @Binding var navigationState: NavigationState

    @State private var selectedIndex = 0
    @State private var pageOffset = 0
    private let pageSize = 10

    var body: some View {
        let queue = playerViewModel.queue
        let currentSong = playerViewModel.currentSong
        let currentIndex = getCurrentSongIndex(queue: queue, currentSong: currentSong)

        return VStack(spacing: 1) {
            headerView(queueCount: queue.count, totalDuration: calculateTotalDuration(queue: queue))
            Text("")

            if queue.isEmpty {
                emptyQueueView
            } else {
                queueListView(queue: queue, currentIndex: currentIndex)
            }

            Spacer()
            helpBar
        }
        .onAppear {
            // Center on currently playing song
            if let currentIndex = currentIndex {
                selectedIndex = currentIndex
                centerOnCurrentSong(queueSize: queue.count, currentIndex: currentIndex)
            }
        }
        // Navigation
        .onKeyPress("j") { selectNext(queueSize: queue.count) }
        .onKeyPress("k") { selectPrevious() }
        .onKeyPress("g") { selectFirst() }
        .onKeyPress("G") { selectLast(queueSize: queue.count) }
        // Page navigation
        .onKeyPress("u") { pageUp() }
        .onKeyPress("d") { pageDown(queueSize: queue.count) }
        // Actions
        .onKeyPress("\u{7F}") { removeSelected() } // Backspace
        .onKeyPress("x") { removeSelected() }
        .onKeyPress("c") { clearQueue() }
        .onKeyPress("C") { clearQueue() }
        // Move
        .onKeyPress("K") { moveUp() } // Shift+K
        .onKeyPress("J") { moveDown(queueSize: queue.count) } // Shift+J
        // Back
        .onKeyPress("\u{1B}") { navigationState.pop() } // Esc
    }

    // MARK: - View Components

    private func headerView(queueCount: Int, totalDuration: String) -> some View {
        VStack(spacing: 1) {
            HStack {
                Text(TUIColors.Indicators.info("♫ Queue"))
                Text(" (\(queueCount) songs - \(totalDuration))")
                Spacer()
            }
            HStack {
                Text(TUITheme.divider(width: 80))
                Spacer()
            }
        }
    }

    private var emptyQueueView: some View {
        VStack {
            Text("")
            HStack {
                Text("Queue is empty")
                Spacer()
            }
            Text("")
            HStack {
                Text("Add songs to the queue from the library")
                Spacer()
            }
        }
    }

    private func queueListView(queue: [Song], currentIndex: Int?) -> some View {
        let paginatedQueue = getPaginatedQueue(queue: queue)

        return VStack(spacing: 0) {
            // Page indicator
            if queue.count > pageSize {
                HStack {
                    Text("Showing \(pageOffset + 1)-\(min(pageOffset + pageSize, queue.count)) of \(queue.count)")
                    Text(" [u/d for pages]")
                    Spacer()
                }
                Text("")
            }

            // Queue items
            ForEach(Array(paginatedQueue.enumerated()), id: \.element.id) { index, song in
                let globalIndex = pageOffset + index
                let isSelected = globalIndex == selectedIndex
                let isPlaying = currentIndex == globalIndex
                queueRow(song: song, index: globalIndex + 1, isSelected: isSelected, isPlaying: isPlaying)
            }
        }
    }

    private func queueRow(song: Song, index: Int, isSelected: Bool, isPlaying: Bool) -> some View {
        HStack {
            if isPlaying {
                Text(" ♫ ")
            } else if isSelected {
                Text(" > ")
            } else {
                Text("   ")
            }
            Text(String(format: "%2d.", index))
            Text(" ")
            Text(TUITheme.truncate("\(song.artist) - \(song.title)", width: 55))
            Spacer()
            // Show duration if available (placeholder for now)
            Text("--:--")
        }
    }

    private var helpBar: some View {
        VStack(spacing: 0) {
            Text(TUITheme.divider(width: 80))
            HStack {
                Text("[j/k] Navigate")
                Text("  ")
                Text("[K/J] Move Up/Down")
                Text("  ")
                Text("[x] Remove")
                Text("  ")
                Text("[c] Clear")
                Spacer()
            }
            HStack {
                Text("[Esc] Back")
                Spacer()
            }
        }
    }

    // MARK: - Helper Methods

    private func getCurrentSongIndex(queue: [Song], currentSong: Song?) -> Int? {
        guard let currentSong = currentSong else { return nil }
        return queue.firstIndex { $0.id == currentSong.id }
    }

    private func calculateTotalDuration(queue: [Song]) -> String {
        // Placeholder - would need duration from song metadata
        // For now, estimate 3 minutes per song
        let totalMinutes = queue.count * 3
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return "\(hours):\(String(format: "%02d", minutes)):00"
        } else {
            return "\(minutes):00"
        }
    }

    private func getPaginatedQueue(queue: [Song]) -> ArraySlice<Song> {
        let start = pageOffset
        let end = min(start + pageSize, queue.count)
        guard start < queue.count else { return [] }
        return queue[start..<end]
    }

    private func centerOnCurrentSong(queueSize: Int, currentIndex: Int) {
        // Center the page on the current song
        pageOffset = max(0, currentIndex - pageSize / 2)
        pageOffset = min(pageOffset, max(0, queueSize - pageSize))
    }

    // MARK: - Navigation Actions

    private func selectNext(queueSize: Int) {
        guard queueSize > 0 else { return }
        if selectedIndex < queueSize - 1 {
            selectedIndex += 1
            // Auto-scroll to next page if needed
            if selectedIndex >= pageOffset + pageSize {
                pageOffset = min(selectedIndex, queueSize - pageSize)
            }
        }
    }

    private func selectPrevious() {
        if selectedIndex > 0 {
            selectedIndex -= 1
            // Auto-scroll to previous page if needed
            if selectedIndex < pageOffset {
                pageOffset = max(0, selectedIndex)
            }
        }
    }

    private func selectFirst() {
        selectedIndex = 0
        pageOffset = 0
    }

    private func selectLast(queueSize: Int) {
        guard queueSize > 0 else { return }
        selectedIndex = queueSize - 1
        pageOffset = max(0, queueSize - pageSize)
    }

    private func pageUp() {
        pageOffset = max(0, pageOffset - pageSize)
        selectedIndex = max(0, min(selectedIndex, pageOffset + pageSize - 1))
    }

    private func pageDown(queueSize: Int) {
        let maxOffset = max(0, queueSize - pageSize)
        pageOffset = min(maxOffset, pageOffset + pageSize)
        selectedIndex = min(queueSize - 1, pageOffset)
    }

    // MARK: - Queue Actions

    private func removeSelected() {
        let queue = playerViewModel.queue
        guard selectedIndex >= 0 && selectedIndex < queue.count else { return }

        // Can't remove currently playing song
        let currentSong = playerViewModel.currentSong
        if let currentIndex = getCurrentSongIndex(queue: queue, currentSong: currentSong),
           selectedIndex == currentIndex {
            return
        }

        playerViewModel.removeFromQueue(at: selectedIndex)

        // Adjust selection
        let newQueueSize = queue.count - 1
        if selectedIndex >= newQueueSize && newQueueSize > 0 {
            selectedIndex = newQueueSize - 1
        }

        // Adjust page offset
        if pageOffset > 0 && pageOffset >= newQueueSize {
            pageOffset = max(0, newQueueSize - pageSize)
        }
    }

    private func clearQueue() {
        playerViewModel.clearQueue()
        selectedIndex = 0
        pageOffset = 0
    }

    private func moveUp() {
        guard selectedIndex > 0 else { return }
        let queue = playerViewModel.queue
        guard selectedIndex < queue.count else { return }

        // Can't move currently playing song
        let currentSong = playerViewModel.currentSong
        if let currentIndex = getCurrentSongIndex(queue: queue, currentSong: currentSong),
           selectedIndex == currentIndex {
            return
        }

        // Move song up in queue
        playerViewModel.moveSong(from: selectedIndex, to: selectedIndex - 1)

        // Update selection to follow the moved song
        selectedIndex -= 1

        // Adjust page if needed
        if selectedIndex < pageOffset {
            pageOffset = max(0, selectedIndex)
        }
    }

    private func moveDown(queueSize: Int) {
        guard selectedIndex < queueSize - 1 else { return }
        let queue = playerViewModel.queue
        guard selectedIndex < queue.count else { return }

        // Can't move currently playing song
        let currentSong = playerViewModel.currentSong
        if let currentIndex = getCurrentSongIndex(queue: queue, currentSong: currentSong),
           selectedIndex == currentIndex {
            return
        }

        // Move song down in queue
        playerViewModel.moveSong(from: selectedIndex, to: selectedIndex + 1)

        // Update selection to follow the moved song
        selectedIndex += 1

        // Adjust page if needed
        if selectedIndex >= pageOffset + pageSize {
            pageOffset = min(selectedIndex, queueSize - pageSize)
        }
    }
}
