//
//  TUIList.swift
//  localwave-tui
//
//  Created by Claude Code on 04.10.2025.
//

import SwiftTUI
import Combine

/// State management for TUI list selection and navigation
public struct TUIListState {
    public var selectedIndex: Int
    public var scrollOffset: Int
    public var visibleHeight: Int

    public init(selectedIndex: Int = 0, scrollOffset: Int = 0, visibleHeight: Int = 10) {
        self.selectedIndex = selectedIndex
        self.scrollOffset = scrollOffset
        self.visibleHeight = visibleHeight
    }

    /// Move selection down, updating scroll offset if needed
    public mutating func selectNext(itemCount: Int) {
        guard itemCount > 0 else { return }
        selectedIndex = min(selectedIndex + 1, itemCount - 1)

        // Auto-scroll if selection goes below visible area
        if selectedIndex >= scrollOffset + visibleHeight {
            scrollOffset = selectedIndex - visibleHeight + 1
        }
    }

    /// Move selection up, updating scroll offset if needed
    public mutating func selectPrevious() {
        selectedIndex = max(selectedIndex - 1, 0)

        // Auto-scroll if selection goes above visible area
        if selectedIndex < scrollOffset {
            scrollOffset = selectedIndex
        }
    }

    /// Jump to first item
    public mutating func selectFirst() {
        selectedIndex = 0
        scrollOffset = 0
    }

    /// Jump to last item
    public mutating func selectLast(itemCount: Int) {
        guard itemCount > 0 else { return }
        selectedIndex = itemCount - 1
        scrollOffset = max(0, itemCount - visibleHeight)
    }

    /// Reset state
    public mutating func reset() {
        selectedIndex = 0
        scrollOffset = 0
    }
}

/// Reusable scrollable list component with keyboard navigation
///
/// Features:
/// - j/k navigation (vim-style)
/// - g/G for first/last
/// - Auto-scrolling viewport
/// - Customizable row rendering
/// - Selection indicator
///
/// Example usage:
/// ```swift
/// TUIList(
///     items: songs,
///     state: listState,
///     rowContent: { song, isSelected in
///         HStack {
///             Text(isSelected ? " > " : "   ")
///             Text(song.title)
///             Spacer()
///         }
///     }
/// )
/// .onKeyPress("j") { listState.selectNext(itemCount: songs.count) }
/// .onKeyPress("k") { listState.selectPrevious() }
/// ```
public struct TUIList<Item, RowContent: View>: View {
    let items: [Item]
    @Binding var state: TUIListState
    let rowContent: (Item, Bool) -> RowContent

    public init(
        items: [Item],
        state: Binding<TUIListState>,
        @ViewBuilder rowContent: @escaping (Item, Bool) -> RowContent
    ) {
        self.items = items
        self._state = state
        self.rowContent = rowContent
    }

    public var body: some View {
        VStack(spacing: 0) {
            if items.isEmpty {
                Text("(empty)")
                Spacer()
            } else {
                // Calculate visible range
                let visibleStart = state.scrollOffset
                let visibleEnd = min(state.scrollOffset + state.visibleHeight, items.count)

                ForEach(visibleStart..<visibleEnd, id: \.self) { index in
                    let item = items[index]
                    let isSelected = index == state.selectedIndex
                    rowContent(item, isSelected)
                }

                Spacer()
            }
        }
    }
}

/// List with ID-based items (Identifiable)
public struct TUIIdentifiableList<Item: Identifiable, RowContent: View>: View {
    let items: [Item]
    @Binding var state: TUIListState
    let rowContent: (Item, Bool) -> RowContent

    public init(
        items: [Item],
        state: Binding<TUIListState>,
        @ViewBuilder rowContent: @escaping (Item, Bool) -> RowContent
    ) {
        self.items = items
        self._state = state
        self.rowContent = rowContent
    }

    public var body: some View {
        VStack(spacing: 0) {
            if items.isEmpty {
                Text("(empty)")
                Spacer()
            } else {
                // Calculate visible range
                let visibleStart = state.scrollOffset
                let visibleEnd = min(state.scrollOffset + state.visibleHeight, items.count)

                ForEach(Array(items[visibleStart..<visibleEnd].enumerated()), id: \.element.id) { offset, item in
                    let index = visibleStart + offset
                    let isSelected = index == state.selectedIndex
                    rowContent(item, isSelected)
                }

                Spacer()
            }
        }
    }
}

/// Simplified list for basic string arrays
public struct TUIStringList: View {
    let items: [String]
    @Binding var state: TUIListState
    let showIndicator: Bool

    public init(
        items: [String],
        state: Binding<TUIListState>,
        showIndicator: Bool = true
    ) {
        self.items = items
        self._state = state
        self.showIndicator = showIndicator
    }

    public var body: some View {
        TUIList(items: items, state: $state) { item, isSelected in
            HStack {
                if showIndicator {
                    Text(isSelected ? " > " : "   ")
                }
                Text(item)
                Spacer()
            }
        }
    }
}

/// Extension for common list keyboard bindings
public extension View {
    /// Add standard vim-style list navigation keybindings
    ///
    /// Adds:
    /// - j: select next
    /// - k: select previous
    /// - g: select first
    /// - G: select last
    func listNavigation(state: Binding<TUIListState>, itemCount: Int) -> some View {
        self
            .onKeyPress("j") { state.wrappedValue.selectNext(itemCount: itemCount) }
            .onKeyPress("k") { state.wrappedValue.selectPrevious() }
            .onKeyPress("g") { state.wrappedValue.selectFirst() }
            .onKeyPress("G") { state.wrappedValue.selectLast(itemCount: itemCount) }
    }
}
