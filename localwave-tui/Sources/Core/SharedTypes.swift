//
//  SharedTypes.swift
//  localwave-tui
//
//  Created by Claude Code on 04.10.2025.
//

import Foundation

// MARK: - Platform Bridging Types

/// This file provides type aliases and protocol extensions to bridge the gap
/// between SwiftUI (iOS) and SwiftTUI (Terminal) platforms.
/// It allows ViewModels to work across both platforms without modification.

#if canImport(SwiftUI) && !os(macOS)
// iOS Platform - use SwiftUI
import SwiftUI
public typealias PlatformColor = Color
public typealias PlatformImage = UIImage

#elseif canImport(SwiftTUI)
// TUI Platform - use SwiftTUI
import SwiftTUI
public typealias PlatformColor = SwiftTUI.Color
// TUI doesn't have images, so we'll provide a stub
public struct PlatformImage {
    let data: Data?
    init?(contentsOfFile path: String) {
        self.data = try? Data(contentsOf: URL(fileURLWithPath: path))
    }
}

#else
// Fallback for other platforms (macOS development)
import Foundation
public struct PlatformColor {
    let rawValue: String
}
public struct PlatformImage {
    let data: Data?
    init?(contentsOfFile path: String) {
        self.data = try? Data(contentsOf: URL(fileURLWithPath: path))
    }
}
#endif

// MARK: - RepeatMode (platform-independent)

/// Repeat mode for playback - shared between iOS and TUI
/// TUI version without SwiftUI dependencies
public enum RepeatMode: Int, CaseIterable, Sendable {
    case none, all, one

    public mutating func toggle() {
        self = Self(rawValue: (rawValue + 1) % Self.allCases.count)!
    }

    public var displayName: String {
        switch self {
        case .none: return "Off"
        case .all:  return "All"
        case .one:  return "One"
        }
    }

    public var symbol: String {
        switch self {
        case .none: return "○"
        case .all:  return "↻"
        case .one:  return "1↻"
        }
    }
}

// MARK: - Shared Constants

// Note: subsystem is defined in Shared_Core/Utils.swift
// No need to redefine it here

// MARK: - Future Extensions

// Note: Cover art helpers and Song/Album extensions will be added once
// LocalWaveCore module includes the Domain models (Task 1.3+).
// For now, SharedTypes focuses on platform bridging types only.
