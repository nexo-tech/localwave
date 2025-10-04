//
//  SharedTypes.swift
//  localwave-tui
//
//  Created by Claude Code on 04.10.2025.
//

import Foundation

// MARK: - Platform Bridging for TUI

/// This file provides TUI-specific type aliases for SwiftTUI.
/// Platform-agnostic types are now in Shared_Core/Platform/

#if canImport(SwiftTUI)
import SwiftTUI
public typealias TUIColor = SwiftTUI.Color
#endif

// Note: All other platform types (PlatformImage, RepeatMode, etc.) are now
// defined in the shared Core/Platform/ directory and accessed via symlink.
