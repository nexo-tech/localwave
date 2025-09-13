//
//  RepeatMode.swift
//  localwave
//
//  Created by vic on 2025-09-12.
//
import Foundation
import SwiftUICore

enum RepeatMode: Int, CaseIterable {
    case none, all, one

    mutating func toggle() {
        self = Self(rawValue: (rawValue + 1) % Self.allCases.count)!
    }

    var iconName: String {
        switch self {
        case .none: return "repeat.circle"
        case .all:  return "repeat.circle.fill"
        case .one:  return "repeat.1.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .none: return .white
        case .all:  return .yellow
        case .one:  return .yellow
        }
    }
}
