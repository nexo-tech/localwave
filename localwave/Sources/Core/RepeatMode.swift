//
//  RepeatMode.swift
//  localwave
//
//  Created by Claude Code on 04.10.2025.
//

import Foundation

/// Platform-agnostic repeat mode enumeration
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
