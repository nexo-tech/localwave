//
//  TUITheme.swift
//  localwave-tui
//
//  Created by Claude Code on 04.10.2025.
//

import SwiftTUI

/// Central theme and styling system for LocalWave TUI
///
/// Provides consistent styling across all TUI views including:
/// - Unicode icons for all features
/// - Layout constants (heights, widths, spacing)
/// - Box-drawing utilities for borders
/// - Text formatting helpers
public struct TUITheme {

    // MARK: - Icons (Unicode)

    /// Music and media icons
    public struct Icons {
        // Playback
        public static let play = "▶"
        public static let pause = "⏸"
        public static let stop = "⏹"
        public static let next = "⏭"
        public static let previous = "⏮"
        public static let fastForward = "⏩"
        public static let rewind = "⏪"

        // Music
        public static let music = "♫"
        public static let musicNote = "♪"
        public static let album = "◉"
        public static let artist = "♪"
        public static let song = "♫"

        // Library
        public static let playlist = "☰"
        public static let folder = "📁"
        public static let file = "🎵"
        public static let sync = "⟳"

        // Navigation
        public static let chevronRight = "›"
        public static let chevronLeft = "‹"
        public static let arrowUp = "↑"
        public static let arrowDown = "↓"
        public static let arrowLeft = "←"
        public static let arrowRight = "→"

        // Selection
        public static let selected = ">"
        public static let unselected = " "
        public static let bullet = "•"
        public static let checkmark = "✓"
        public static let cross = "✗"

        // Status
        public static let loading = "⠋" // Part of spinner sequence
        public static let success = "✓"
        public static let error = "✗"
        public static let warning = "⚠"
        public static let info = "ℹ"

        // Search and filters
        public static let search = "🔍"
        public static let filter = "⧉"
        public static let sort = "⇅"

        // Volume
        public static let volumeHigh = "🔊"
        public static let volumeMedium = "🔉"
        public static let volumeLow = "🔈"
        public static let volumeMute = "🔇"

        // Shuffle and repeat
        public static let shuffle = "🔀"
        public static let repeatAll = "🔁"
        public static let repeatOne = "🔂"
        public static let repeatOff = "—"
    }

    // MARK: - Layout Constants

    /// Standard layout dimensions
    public struct Layout {
        // Heights
        public static let tabBarHeight = 1
        public static let miniPlayerHeight = 3
        public static let helpBarHeight = 2
        public static let statusBarHeight = 1

        // Widths (for reference - terminal is typically 80-120 cols)
        public static let minTerminalWidth = 80
        public static let standardTerminalWidth = 100
        public static let wideTerminalWidth = 120

        // List and table
        public static let defaultVisibleRows = 20
        public static let listIndent = 3  // Spaces for " > " indicator

        // Spacing
        public static let sectionSpacing = 1
        public static let itemSpacing = 0
        public static let paddingHorizontal = 2

        // Progress bars
        public static let progressBarWidth = 40
        public static let progressBarWidthWide = 60

        // Text fields
        public static let textFieldWidth = 40
        public static let searchFieldWidth = 50
    }

    // MARK: - Box Drawing Characters

    /// Box-drawing characters for borders and frames
    public struct Box {
        // Single line
        public static let horizontal = "─"
        public static let vertical = "│"
        public static let topLeft = "╭"
        public static let topRight = "╮"
        public static let bottomLeft = "╰"
        public static let bottomRight = "╯"
        public static let teeLeft = "├"
        public static let teeRight = "┤"
        public static let teeTop = "┬"
        public static let teeBottom = "┴"
        public static let cross = "┼"

        // Double line
        public static let doubleHorizontal = "═"
        public static let doubleVertical = "║"
        public static let doubleTopLeft = "╔"
        public static let doubleTopRight = "╗"
        public static let doubleBottomLeft = "╚"
        public static let doubleBottomRight = "╝"

        // Heavy line
        public static let heavyHorizontal = "━"
        public static let heavyVertical = "┃"

        // Block characters
        public static let fullBlock = "█"
        public static let darkShade = "▓"
        public static let mediumShade = "▒"
        public static let lightShade = "░"
    }

    // MARK: - Text Formatting

    /// Create a horizontal divider line
    public static func divider(width: Int = Layout.standardTerminalWidth, char: String = Box.horizontal) -> String {
        String(repeating: char, count: width)
    }

    /// Create a thick horizontal divider
    public static func thickDivider(width: Int = Layout.standardTerminalWidth) -> String {
        String(repeating: Box.heavyHorizontal, count: width)
    }

    /// Create a double-line divider
    public static func doubleDivider(width: Int = Layout.standardTerminalWidth) -> String {
        String(repeating: Box.doubleHorizontal, count: width)
    }

    /// Format time duration (seconds) as MM:SS or HH:MM:SS
    public static func formatDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }

    /// Format time duration as a compact string (e.g., "3:45")
    public static func formatDurationCompact(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    /// Truncate text to fit width with ellipsis
    public static func truncate(_ text: String, width: Int) -> String {
        guard text.count > width else { return text }
        return String(text.prefix(width - 1)) + "…"
    }

    /// Pad text to right with spaces
    public static func padRight(_ text: String, width: Int) -> String {
        let count = max(0, width - text.count)
        return text + String(repeating: " ", count: count)
    }

    /// Pad text to left with spaces
    public static func padLeft(_ text: String, width: Int) -> String {
        let count = max(0, width - text.count)
        return String(repeating: " ", count: count) + text
    }

    /// Center text within width
    public static func center(_ text: String, width: Int) -> String {
        let padding = max(0, width - text.count)
        let leftPad = padding / 2
        let rightPad = padding - leftPad
        return String(repeating: " ", count: leftPad) + text + String(repeating: " ", count: rightPad)
    }

    // MARK: - Box Drawing Utilities

    /// Create a simple single-line box around content
    public static func box(content: [String], width: Int? = nil) -> [String] {
        let actualWidth = width ?? (content.map { $0.count }.max() ?? 40) + 2
        let contentWidth = actualWidth - 2

        var result: [String] = []

        // Top border
        result.append(Box.topLeft + String(repeating: Box.horizontal, count: actualWidth - 2) + Box.topRight)

        // Content lines
        for line in content {
            let paddedLine = padRight(line, width: contentWidth)
            result.append(Box.vertical + " " + paddedLine + " " + Box.vertical)
        }

        // Bottom border
        result.append(Box.bottomLeft + String(repeating: Box.horizontal, count: actualWidth - 2) + Box.bottomRight)

        return result
    }

    /// Create a double-line box around content
    public static func doubleBox(content: [String], width: Int? = nil) -> [String] {
        let actualWidth = width ?? (content.map { $0.count }.max() ?? 40) + 2
        let contentWidth = actualWidth - 2

        var result: [String] = []

        // Top border
        result.append(Box.doubleTopLeft + String(repeating: Box.doubleHorizontal, count: actualWidth - 2) + Box.doubleTopRight)

        // Content lines
        for line in content {
            let paddedLine = padRight(line, width: contentWidth)
            result.append(Box.doubleVertical + " " + paddedLine + " " + Box.doubleVertical)
        }

        // Bottom border
        result.append(Box.doubleBottomLeft + String(repeating: Box.doubleHorizontal, count: actualWidth - 2) + Box.doubleBottomRight)

        return result
    }

    /// Create a box with title
    public static func titleBox(title: String, content: [String], width: Int? = nil) -> [String] {
        let actualWidth = width ?? max((content.map { $0.count }.max() ?? 40) + 2, title.count + 4)
        let contentWidth = actualWidth - 2

        var result: [String] = []

        // Top border with title
        let titleLine = Box.topLeft + Box.horizontal + " " + title + " " + String(repeating: Box.horizontal, count: actualWidth - title.count - 5) + Box.topRight
        result.append(titleLine)

        // Content lines
        for line in content {
            let paddedLine = padRight(line, width: contentWidth)
            result.append(Box.vertical + " " + paddedLine + " " + Box.vertical)
        }

        // Bottom border
        result.append(Box.bottomLeft + String(repeating: Box.horizontal, count: actualWidth - 2) + Box.bottomRight)

        return result
    }
}
