import Foundation

// models
public struct User: Sendable {
    public let id: Int64?
    public let icloudId: Int64
}

public enum SourceType: String, Codable, CaseIterable {
    case iCloud
}

public struct Playlist: Identifiable, Sendable {
    public let id: Int64?
    public let name: String
    public let createdAt: Date
    public let updatedAt: Date?
}

public struct PlaylistSong: Identifiable, Sendable {
    public let id: Int64?
    public let playlistId: Int64
    public let songId: Int64
    public let position: Int // New: For ordering
}

public struct Source: Sendable, Identifiable {
    public var id: Int64?
    public var dirPath: String
    public var pathId: Int64
    public var userId: Int64
    public var type: SourceType?
    public var totalPaths: Int?
    public var syncError: String?
    public var isCurrent: Bool
    public var createdAt: Date
    public var lastSyncedAt: Date?
    public var updatedAt: Date?

    public var stableId: Int64 {
        id ?? Int64(abs(dirPath.hashValue))
    }
}

public struct SourcePath: Sendable {
    public let id: Int64?
    public let sourceId: Int64

    public let pathId: Int64
    public let parentPathId: Int64?
    public let name: String
    public let relativePath: String
    public let isDirectory: Bool

    public let fileHashSHA256: Data?
    public let runId: Int64

    public let createdAt: Date
    public let updatedAt: Date?

    public func copyWith(id: Int64?) -> SourcePath {
        return SourcePath(
            id: id,
            sourceId: sourceId,
            pathId: pathId,
            parentPathId: parentPathId,
            name: name,
            relativePath: relativePath,
            isDirectory: isDirectory,
            fileHashSHA256: fileHashSHA256,
            runId: runId,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

public struct Album: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let artist: String?
    public let coverArtPath: String?

    public init(name: String, artist: String?, coverArtPath: String?) {
        let cleanedName = name.isEmpty ? "Unknown Album" : name
        let cleanedArtist = artist?.isEmpty ?? true ? nil : artist

        id = "\(cleanedArtist ?? "Unknown Artist")-\(cleanedName)"
        self.name = cleanedName
        self.artist = cleanedArtist
        self.coverArtPath = coverArtPath
    }
}

// 1. Add file state tracking to Song model
public enum FileState: Int, Codable {
    case bookmarkOnly
    case copyPending
    case copied
    case failed
}

/// Example song model, no sourceId. We store all metadata ourselves.
public struct Song: Sendable, Identifiable, Equatable {
    public let id: Int64?

    /// A unique-ish hash of (artist, title, album).
    public let songKey: Int64

    public let artist: String
    public let title: String
    public let album: String

    public let albumArtist: String
    public let releaseYear: Int?
    public let discNumber: Int?

    // trackNumber property for album order
    public let trackNumber: Int?
    public let coverArtPath: String?
    public var bookmark: Data?
    public var pathHash: Int64

    /// Timestamps
    public let createdAt: Date
    public let updatedAt: Date?

    public let localFilePath: String? // Path in app's Documents directory
    public var fileState: FileState

    public func copyWith(_ fp: String, _ st: FileState) -> Song {
        Song(
            id: id,
            songKey: songKey,
            artist: artist,
            title: title,
            album: album,
            albumArtist: albumArtist,
            releaseYear: releaseYear,
            discNumber: discNumber,
            trackNumber: trackNumber,
            coverArtPath: coverArtPath,
            bookmark: bookmark,
            pathHash: pathHash,
            createdAt: createdAt,
            updatedAt: updatedAt,
            localFilePath: fp,
            fileState: st
        )
    }

    public func copyWith(id: Int64?) -> Song {
        Song(
            id: id,
            songKey: songKey,
            artist: artist,
            title: title,
            album: album,
            albumArtist: albumArtist,
            releaseYear: releaseYear,
            discNumber: discNumber,
            trackNumber: trackNumber,
            coverArtPath: coverArtPath,
            bookmark: bookmark,
            pathHash: pathHash,
            createdAt: createdAt,
            updatedAt: updatedAt,
            localFilePath: localFilePath,
            fileState: fileState
        )
    }

    public var needsCopy: Bool {
        return fileState == .bookmarkOnly || fileState == .failed
    }

    public static func == (lhs: Song, rhs: Song) -> Bool {
        return lhs.id == rhs.id
    }

    public var uniqueId: Int64 {
        return id ?? songKey
    }
}
