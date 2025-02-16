import AVFoundation
import CryptoKit
import SQLite
import UIKit
import os

/// subsystem used in logs
let subsystem = "com.snowbear.musicapp"
let schemaVersion = 29

enum CustomError: Error {
    case genericError(_ message: String)
}

struct PathSearchResult {
    let pathId: Int64
    let rank: Double
    init(pathId: Int64, rank: Double) {
        self.pathId = pathId
        self.rank = rank
    }
}

// models
struct User: Sendable {
    let id: Int64?
    let icloudId: Int64
}

enum SourceType: String, Codable, CaseIterable {
    case iCloud
}

struct Playlist: Identifiable, Sendable {
    let id: Int64?
    let name: String
    let createdAt: Date
    let updatedAt: Date?
}

struct PlaylistSong: Identifiable, Sendable {
    let id: Int64?
    let playlistId: Int64
    let songId: Int64
    let position: Int  // New: For ordering
}

struct Source: Sendable, Identifiable {
    var id: Int64?
    var dirPath: String
    var pathId: Int64
    var userId: Int64
    var type: SourceType?
    var totalPaths: Int?
    var syncError: String?
    var isCurrent: Bool
    var createdAt: Date
    var lastSyncedAt: Date?
    var updatedAt: Date?

    var stableId: Int64 {
        id ?? Int64(abs(dirPath.hashValue))
    }
}

struct SourcePath: Sendable {
    let id: Int64?
    let sourceId: Int64

    let pathId: Int64
    let parentPathId: Int64?
    let name: String
    let relativePath: String
    let isDirectory: Bool

    let fileHashSHA256: Data?
    let runId: Int64

    let createdAt: Date
    let updatedAt: Date?
}

struct Album: Identifiable, Hashable {
    let id: String
    let name: String
    let artist: String?
    let coverArtPath: String?

    init(name: String, artist: String?, coverArtPath: String?) {
        let cleanedName = name.isEmpty ? "Unknown Album" : name
        let cleanedArtist = artist?.isEmpty ?? true ? nil : artist

        self.id = "\(cleanedArtist ?? "Unknown Artist")-\(cleanedName)"
        self.name = cleanedName
        self.artist = cleanedArtist
        self.coverArtPath = coverArtPath
    }
}

/// Example song model, no sourceId. We store all metadata ourselves.
struct Song: Sendable, Identifiable, Equatable {
    let id: Int64?

    /// A unique-ish hash of (artist, title, album).
    let songKey: Int64

    let artist: String
    let title: String
    let album: String

    let albumArtist: String
    let releaseYear: Int?
    let discNumber: Int?

    // trackNumber property for album order
    let trackNumber: Int?
    let coverArtPath: String?
    var bookmark: Data?
    var pathHash: Int64

    /// Timestamps
    let createdAt: Date
    let updatedAt: Date?

    func copyWith(id: Int64?) -> Song {
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
            updatedAt: updatedAt
        )
    }

    static func == (lhs: Song, rhs: Song) -> Bool {
        return lhs.id == rhs.id
    }

    var uniqueId: Int64 {
        return id ?? songKey
    }
}

func generateSongKey(artist: String, title: String, album: String) -> Int64 {
    // Normalize or lowercased if you like
    let combined = "\(artist.lowercased())__\(title.lowercased())__\(album.lowercased())"
    return hashStringToInt64(combined)  // Using your existing FNV approach
}

func setupSQLiteConnection(dbName: String) -> Connection? {
    let logger = Logger(subsystem: subsystem, category: "setupSQLiteConnection")
    logger.debug("setting up connection ...")
    let dbPath = NSSearchPathForDirectoriesInDomains(
        .documentDirectory,
        .userDomainMask,
        true
    ).first!
    let dbFullPath = "\(dbPath)/\(dbName)"
    logger.debug("db path: \(dbFullPath)")
    do {
        return try Connection(dbFullPath)
    } catch {
        fatalError("DB init error: \(error)")
    }
}

func hashStringToInt64(_ str: String) -> Int64 {
    let fnvOffsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    let fnvPrime: UInt64 = 0x100_0000_01b3
    var hash = fnvOffsetBasis

    for byte in str.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* fnvPrime
    }

    return Int64(bitPattern: hash & 0x7FFF_FFFF_FFFF_FFFF)
}

protocol PlayerPersistenceService {
    func getVolume() async -> Float
    func restore() async -> ([Song], Int, Song?)?
    func savePlaybackState(volume: Float, currentIndex: Int, songs: [Song]) async
}

protocol PlaylistRepository {
    func create(playlist: Playlist) async throws -> Playlist
    func update(playlist: Playlist) async throws -> Playlist
    func delete(playlistId: Int64) async throws
    func getAll() async throws -> [Playlist]
    func getOne(id: Int64) async throws -> Playlist?
}

protocol PlaylistSongRepository {
    func addSong(playlistId: Int64, songId: Int64) async throws
    func removeSong(playlistId: Int64, songId: Int64) async throws
    func getSongs(playlistId: Int64) async throws -> [Song]
    func reorderSongs(playlistId: Int64, newOrder: [Int64]) async throws  // New
}

actor DefaultPlayerPersistenceService: PlayerPersistenceService {
    private let queueKey = "currentQueue"
    private let currentIndexKey = "currentQueueIndex"
    private let volumeKey = "playerVolume"

    private let songRepo: SongRepository

    init(songRepo: SongRepository) {
        self.songRepo = songRepo
    }

    func getVolume() async -> Float {
        UserDefaults.standard.float(forKey: volumeKey)
    }

    let logger = Logger(subsystem: subsystem, category: "PlayerPersistenceService")

    func restore() async -> ([Song], Int, Song?)? {
        guard let songIds = UserDefaults.standard.array(forKey: queueKey) as? [Int64],
            let currentIndex = UserDefaults.standard.value(forKey: currentIndexKey) as? Int,
            !songIds.isEmpty
        else {
            logger.debug("no persisted data, skipping")
            return nil
        }

        // Need to inject song repository
        logger.debug("loading songs by ids: \(songIds)")
        let songs = await songRepo.getSongs(ids: songIds)
        let currentSong = songs[safe: currentIndex]

        return (songs, currentIndex, currentSong)
    }

    func savePlaybackState(volume: Float, currentIndex: Int, songs: [Song]) async {
        let songIds = songs.map { $0.id ?? -1 }
        UserDefaults.standard.set(songIds, forKey: queueKey)
        UserDefaults.standard.set(currentIndex, forKey: currentIndexKey)
        UserDefaults.standard.set(volume, forKey: volumeKey)
    }
}
struct SourceSyncResult {
    let allItems: [SourceSyncResultItem]
    let audioFiles: [SourceSyncResultItem]
    let totalAudioFiles: Int
}

struct SourceSyncResultItem {
    let relativePath: String
    let parentURL: URL?
    let url: URL
    let isDirectory: Bool
    let name: String

    init(rootURL: URL, current: URL, isDirectory: Bool) {
        let fh = FileHelper(fileURL: current)
        self.relativePath = fh.relativePath(from: rootURL) ?? ""
        self.parentURL = fh.parent().flatMap {
            $0
        }
        self.url = current
        self.isDirectory = isDirectory
        self.name = fh.name()
    }
}

protocol SongRepository {
    /// Upsert a song based on its songKey (hash of artist/title/album).
    /// If a row with the same key exists, update it; otherwise insert new.
    func upsertSong(_ song: Song) async throws -> Song

    /// Full-text search by artist/title/album, returning at most `limit` songs,
    /// ordered by `bm25(...)`.
    func searchSongsFTS(query: String, limit: Int, offset: Int) async throws -> [Song]
    func totalSongCount(query: String) async throws -> Int

    func getAllArtists() async throws -> [String]
    func getAllAlbums() async throws -> [Album]

    func getSongs(ids: [Int64]) async -> [Song]
    func getSongByURL(_ url: URL) async -> Song?
    func updateBookmark(songId: Int64, bookmark: Data) async throws
}

protocol SourceImportService {
    func listItems(sourceId: Int64, parentPathId: Int64?) async throws -> [SourcePath]
    func search(sourceId: Int64, query: String) async throws -> [SourcePath]
    func deleteOne(sourceId: Int64) async throws
}

protocol SourcePathSearchRepository {
    func batchUpsertIntoFTS(paths: [SourcePath]) async throws
    func search(sourceId: Int64, query: String, limit: Int) async throws -> [PathSearchResult]
    func batchDeleteFTS(sourceId: Int64, excludingRunId: Int64) async throws
    func deleteAllFTS(sourceId: Int64) async throws
}

protocol SourceSyncService {
    func syncDir(
        sourceId: Int64,
        folderURL: URL,
        onCurrentURL: ((_ url: URL?) -> Void)?,
        onSetLoading: ((_ loading: Bool) -> Void)?
    ) async throws
        -> Source?
}

struct FileHelper {
    let fileURL: URL
    func toString() -> String {
        return fileURL.absoluteString
    }

    func name() -> String {
        return fileURL.lastPathComponent
    }

    func parent() -> URL? {
        return fileURL.deletingLastPathComponent()
    }

    func relativePath(from baseURL: URL) -> String? {
        let basePath = baseURL.path
        let fullPath = fileURL.path
        guard fullPath.hasPrefix(basePath) else {
            return nil
        }
        return String(fullPath.dropFirst(basePath.count + 1))
    }

    static func createURL(baseURL: URL, relativePath: String) -> URL? {
        if relativePath.isEmpty {
            return baseURL.absoluteURL  // If the relative path is empty, return the base URL
        }
        return baseURL.appendingPathComponent(relativePath).absoluteURL
    }
}

protocol SongImportService {
    func importPaths(
        paths: [SourcePath],
        onProgress: ((Double, URL) async -> Void)?
    ) async throws

    func cancelImport() async
}

private enum ImageFormat {
    case png
    case jpeg

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        }
    }
}

actor DefaultSongImportService: SongImportService {
    private var currentImportTask: Task<Void, Error>?
    private var isImporting = false

    func cancelImport() {
        currentImportTask?.cancel()
        releaseSecurityAccess()
    }

    private let logger = Logger(subsystem: subsystem, category: "SongImporter")
    private let songRepo: SongRepository
    private let sourcePathRepo: SourcePathRepository
    private let sourceRepo: SourceRepository
    private var activeRootURLs: [Int64: URL] = [:]

    init(
        songRepo: SongRepository,
        sourcePathRepo: SourcePathRepository,
        sourceRepo: SourceRepository
    ) {
        self.songRepo = songRepo
        self.sourcePathRepo = sourcePathRepo
        self.sourceRepo = sourceRepo
    }

    private func prepareSecurityAccess(for paths: [SourcePath]) async throws {
        let sourceIds = Set(paths.map { $0.sourceId })

        for sourceId in sourceIds {
            guard let rootURL = try await resolveRootURL(for: sourceId) else {
                throw CustomError.genericError("Failed to access source \(sourceId)")
            }
            activeRootURLs[sourceId] = rootURL
        }
    }

    private func resolveRootURL(for sourceId: Int64) async throws -> URL? {
        // Check cache first
        if let cached = activeRootURLs[sourceId] {
            return cached
        }

        // Fetch source from repository
        guard let source = try await sourceRepo.getOne(id: sourceId) else {
            logger.error("Source not found: \(sourceId)")
            return nil
        }

        // Resolve bookmark
        let bookmarkKey = makeBookmarkKey(URL(filePath: source.dirPath))
        guard let bookmarkData = UserDefaults.standard.data(forKey: bookmarkKey) else {
            logger.error("Missing bookmark for source \(sourceId)")
            return nil
        }

        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale)

        // Refresh stale bookmark
        if isStale {
            let newBookmark = try url.bookmarkData(options: [])
            UserDefaults.standard.set(newBookmark, forKey: bookmarkKey)
        }

        // Start security access
        guard url.startAccessingSecurityScopedResource() else {
            logger.error("Security scope access failed for \(sourceId)")
            return nil
        }

        // Cache the resolved URL
        activeRootURLs[sourceId] = url
        return url
    }

    private func releaseSecurityAccess() {
        activeRootURLs.forEach { $1.stopAccessingSecurityScopedResource() }
        activeRootURLs.removeAll()
    }
    func importPaths(
        paths: [SourcePath],
        onProgress: ((Double, URL) async -> Void)? = nil
    ) async throws {
        // Cancel any existing task
        if let currentTask = currentImportTask {
            currentTask.cancel()
            try await currentTask.value
        }

        currentImportTask = Task {
            defer {
                currentImportTask = nil
                isImporting = false
                releaseSecurityAccess()
            }

            isImporting = true
            try await importImplementation(paths: paths, onProgress: onProgress)
        }

        try await currentImportTask!.value
    }

    // NEW: Bookmark validation check
    private func checkBookmarkValidity(song: Song) -> Bool {
        guard let bookmarkData = song.bookmark else { return false }

        var isStale = false
        do {
            _ = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withoutUI,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return !isStale
        } catch {
            return false
        }
    }

    /// Import all paths, recursively grabbing files from directories.
    /// - parameter onProgress: Called with (percentage from 0..100, currentFileURL).
    func importImplementation(
        paths: [SourcePath],
        onProgress: ((Double, URL) async -> Void)? = nil
    ) async throws {
        logger.debug("Gathering files from \(paths.count) paths")
        let filePaths = try await gatherAllFiles(paths: paths)
        logger.debug("Total files: \(filePaths.count)")
        try await prepareSecurityAccess(for: filePaths)
        defer { releaseSecurityAccess() }

        for (index, filePath) in filePaths.enumerated() {
            guard let fileURL = await resolveFileURL(for: filePath) else {
                logger.error("Skipping file due to unresolved URL")
                continue
            }

            // Provide progress callback
            let percent = Double(index + 1) / Double(filePaths.count) * 100
            logger.debug("progress: \(percent)%; url: \(fileURL)")
            await onProgress?(percent, fileURL)

            // 1) Skip if already processed
            if filePath.fileHashSHA256 != nil {
                if let existingSong = await songRepo.getSongByURL(fileURL) {
                    // Verify bookmark validity
                    if checkBookmarkValidity(song: existingSong) {
                        logger.debug("Skipping valid existing file: \(fileURL.lastPathComponent)")
                        continue
                    }
                    logger.debug(
                        "Existing bookmark invalid, reprocessing: \(fileURL.lastPathComponent)")
                }

            }

            // 2) Compute new file hash & store in DB
            let fileData = try Data(contentsOf: fileURL)
            let fileHash = sha256(fileData)
            try await sourcePathRepo.updateFileHash(pathId: filePath.pathId, fileHash: fileHash)

            // 3) Read metadata
            let (artist, title, album, albumArtist, releaseYear, trackNumber, discNumber) =
                await readMetadataAVAsset(url: fileURL)
            let songKey = generateSongKey(artist: artist, title: title, album: album)

            // 4) Extract artwork
            let coverArtData = await extractCoverArtData(url: fileURL)
            let coverArtPath = try storeCoverArtOnDiskDedup(coverArtData)

            // 5) Upsert into DB
            let newSong = Song(
                id: nil,
                songKey: songKey,
                artist: artist,
                title: title,
                album: album,
                albumArtist: albumArtist,
                releaseYear: releaseYear,
                discNumber: discNumber,
                trackNumber: trackNumber,
                coverArtPath: coverArtPath,
                bookmark: try createBookmark(for: fileURL),
                pathHash: makeURLHash(fileURL),
                createdAt: Date(),
                updatedAt: nil
            )
            let song = try await songRepo.upsertSong(newSong)
            logger.debug("Upserted song: \(song.title)")
        }
    }

    // MARK: - Recursively gather all file paths
    private func gatherAllFiles(paths: [SourcePath]) async throws -> [SourcePath] {
        var result = [SourcePath]()
        for p in paths {
            if p.isDirectory {
                let children = try await sourcePathRepo.getByParentId(
                    sourceId: p.sourceId, parentPathId: p.pathId
                )
                result.append(contentsOf: try await gatherAllFiles(paths: children))
            } else {
                result.append(p)
            }
        }
        return result
    }

    // MARK: - Resolve file URL with caching
    // MARK: - File URL Resolution
    private func resolveFileURL(for path: SourcePath) async -> URL? {
        guard let rootURL = activeRootURLs[path.sourceId] else {
            logger.error("No root URL found for source \(path.sourceId)")
            return nil
        }

        return rootURL.appendingPathComponent(path.relativePath, isDirectory: false)
    }

    private func resolveURLFromSource(_ source: Source, relativePath: String) throws -> URL? {
        let folderAbsoluteString = source.dirPath
        let bookmarkKey = makeBookmarkKey(URL(filePath: folderAbsoluteString))

        guard let bookmarkData = UserDefaults.standard.data(forKey: bookmarkKey) else {
            logger.error("No bookmark found for source \(source.id ?? -1)")
            return nil
        }

        var isStale = false
        let resolvedURL = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        if isStale {
            // Renew bookmark and update cache if needed
            let newBookmark = try resolvedURL.bookmarkData()
            UserDefaults.standard.set(newBookmark, forKey: bookmarkKey)
        }

        guard resolvedURL.startAccessingSecurityScopedResource() else {
            logger.error("Security scope access failed for \(source.id ?? -1)")
            return nil
        }
        defer { resolvedURL.stopAccessingSecurityScopedResource() }

        return resolvedURL.appendingPathComponent(relativePath)
    }

    // MARK: - Create a bookmark
    private func createBookmark(for fileURL: URL) throws -> Data {
        try fileURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    // MARK: - Read metadata (iOS 16+)
    @available(iOS 16.0, *)
    func readMetadataAVAsset(url: URL) async -> (
        artist: String, title: String, album: String,
        albumArtist: String, releaseYear: Int?, trackNumber: Int?, discNumber: Int?
    ) {
        let asset = AVURLAsset(url: url)
        var defaultSongTitle = url.lastPathComponent
        if defaultSongTitle == "" {
            defaultSongTitle = "Unknown Title"
        }
        do {
            var artist = ""
            var title = ""
            var album = ""
            var trackNumber: Int? = nil

            var albumArtist = ""
            var releaseYear: Int? = nil
            var discNumber: Int? = nil

            let formats = try await asset.load(.availableMetadataFormats)
            for format in formats {
                let metadata = try await asset.loadMetadata(for: format)

                for item in metadata {
                    if let commonKey = item.commonKey {
                        switch commonKey {
                        case .commonKeyArtist where artist == "":
                            if let val = try? await item.load(.stringValue) { artist = val }
                        case .commonKeyTitle where title == "":
                            if let val = try? await item.load(.stringValue) { title = val }
                        case .commonKeyAlbumName where album == "":
                            if let val = try? await item.load(.stringValue) { album = val }
                        case .id3MetadataKeyTrackNumber where trackNumber == nil:
                            if let val = try? await item.load(.numberValue) {
                                trackNumber = val.intValue
                            }
                        default:
                            break
                        }
                    }

                    if let keyStr = item.key as? String {
                        switch keyStr {
                        case "TDRC":  // ID3 release time
                            if let val = try? await item.load(.stringValue),
                                let year = Int(val.prefix(4))
                            {
                                releaseYear = year
                            }
                        case "TPOS":  // ID3 disc number
                            if let val = try? await item.load(.stringValue) {
                                let parts = val.components(separatedBy: "/")
                                if let disc = Int(parts[0]) {
                                    discNumber = disc
                                }
                            }
                        default:
                            break
                        }
                    }

                    // Also check for track number in string format "5/12"
                    if let itemKey = item.key as? String, itemKey == "TRCK", trackNumber == nil {
                        if let val = try? await item.load(.stringValue) {
                            let cleanString = val.components(separatedBy: "/").first ?? val
                            if let number = Int(cleanString) { trackNumber = number }
                        }
                    }
                }
            }

            let cleanedArtist = artist.isEmpty ? "Unknown Artist" : artist
            let cleanedTitle = title.isEmpty ? defaultSongTitle : title
            let cleanedAlbum = album.isEmpty ? "Unknown Album" : album
            // Fallback for albumArtist if not provided.
            let cleanedAlbumArtist = albumArtist.isEmpty ? cleanedArtist : albumArtist

            return (
                cleanedArtist, cleanedTitle, cleanedAlbum, cleanedAlbumArtist, releaseYear,
                trackNumber, discNumber
            )

        } catch {
            logger.error("Failed to read metadata: \(error)")
            return (
                "Unknown Artist", defaultSongTitle, "Unknown Album", "Unknown Artist", nil, nil, nil
            )
        }
    }

    // MARK: - Extract cover art data (improved)
    @available(iOS 16.0, *)
    private func extractCoverArtData(url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        do {
            let metadata = try await asset.load(.metadata)

            // Check multiple possible metadata keys
            for item in metadata {
                guard item.commonKey != nil else { continue }

                // Handle both data values and external URLs
                if let dataValue = try? await item.load(.dataValue) {
                    if isValidImageData(dataValue) {
                        return dataValue
                    }
                }

                // Handle URL references
                if let stringValue = try? await item.load(.stringValue),
                    let url = URL(string: stringValue),
                    url.scheme == "http" || url.scheme == "https"
                {
                    logger.debug("Found remote artwork URL: \(url.absoluteString)")
                    // Consider downloading here if appropriate
                }
            }

            // Fallback: Check all metadata items regardless of key space
            for item in metadata {
                if let dataValue = try? await item.load(.dataValue),
                    isValidImageData(dataValue)
                {
                    return dataValue
                }
            }
        } catch {
            logger.error("extractCoverArtData error: \(error)")
        }
        return nil
    }

    // MARK: - Validate image data
    private func isValidImageData(_ data: Data) -> Bool {
        return UIImage(data: data) != nil
    }

    // MARK: - Store cover art with format detection
    private func storeCoverArtOnDiskDedup(_ data: Data?) throws -> String? {
        guard let data = data, !data.isEmpty else { return nil }

        // Validate image data
        guard isValidImageData(data), let image = UIImage(data: data) else {
            logger.error("Invalid image data, skipping cover art")
            return nil
        }

        // Detect image format
        let format: ImageFormat = image.pngData() != nil ? .png : .jpeg
        let hashString = sha256(data).map { String(format: "%02x", $0) }.joined()
        let filename = "cover-\(hashString).\(format.fileExtension)"

        guard
            let documentsDir = FileManager.default.urls(
                for: .documentDirectory, in: .userDomainMask
            ).first
        else {
            return nil
        }

        let coverArtDir = documentsDir.appendingPathComponent("CoverArt", isDirectory: true)
        if !FileManager.default.fileExists(atPath: coverArtDir.path) {
            try FileManager.default.createDirectory(
                at: coverArtDir, withIntermediateDirectories: true)
        }

        let fileURL = coverArtDir.appendingPathComponent(filename)

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            switch format {
            case .png:
                try image.pngData()?.write(to: fileURL)
            case .jpeg:
                try image.jpegData(compressionQuality: 0.8)?.write(to: fileURL)
            }
        }

        return "CoverArt/\(filename)"
    }

    // MARK: - Utility: SHA256 for Data
    private func sha256(_ data: Data) -> Data {
        // If you're on iOS 13+, you can use CryptoKit. For brevity:
        var hasher = CryptoKit.SHA256()
        hasher.update(data: data)
        return Data(hasher.finalize())
    }
}

func preprocessFTSQuery(_ input: String) -> String {
    input
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .map { "\($0)*" }
        .joined(separator: " ")
}

actor DefaultSourceImportService: SourceImportService {
    let logger = Logger(subsystem: subsystem, category: "SourceImportService")

    private let sourceRepository: SourceRepository
    private let sourcePathRepository: SourcePathRepository
    private let sourcePathSearchRepository: SourcePathSearchRepository

    init(
        sourceRepository: SourceRepository,
        sourcePathRepository: SourcePathRepository,
        sourcePathSearchRepository: SourcePathSearchRepository
    ) {
        self.sourceRepository = sourceRepository
        self.sourcePathRepository = sourcePathRepository
        self.sourcePathSearchRepository = sourcePathSearchRepository
    }

    func deleteOne(sourceId: Int64) async throws {
        try await sourceRepository.deleteSource(sourceId: sourceId)
        try await sourcePathRepository.deleteAllPaths(sourceId: sourceId)
        try await sourcePathSearchRepository.deleteAllFTS(sourceId: sourceId)
    }

    func listItems(sourceId: Int64, parentPathId: Int64?) async throws -> [SourcePath] {
        logger.debug("attempting to list for libID : \(sourceId), parent: \(parentPathId ?? -1)")
        let all = try await sourcePathRepository.getByParentId(
            sourceId: sourceId, parentPathId: parentPathId)

        logger.debug("got : \(all.count) items")

        return all
    }

    func search(sourceId: Int64, query: String) async throws -> [SourcePath] {
        let results = try await sourcePathSearchRepository.search(
            sourceId: sourceId,
            query: query,
            limit: 100  // or whatever you like
        )

        // Retrieve the actual SourcePath records for each matching pathId
        var paths = [SourcePath]()
        for r in results {
            if let p = try await sourcePathRepository.getByPathId(
                sourceId: sourceId, pathId: r.pathId)
            {
                paths.append(p)
            }
        }
        return paths
    }

}

// Could be anything
// file://
// or path
// or other url
func makeURLFromString(_ s: String) -> URL {
    // Trim whitespace and newlines.
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)

    // If the string is empty, fallback to the current directory.
    if trimmed.isEmpty {
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    // Try parsing as a URL. If it has a scheme (like "http", "file", etc.), return it.
    if let url = URL(string: trimmed), let scheme = url.scheme, !scheme.isEmpty {
        return url
    }

    // If it starts with "/" or "~", assume it's a file path.
    if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
    }

    // If it contains a dot and no spaces, assume it’s a web address missing the scheme.
    if trimmed.contains(".") && !trimmed.contains(" ") {
        if let url = URL(string: "http://\(trimmed)") {
            return url
        }
    }

    // Fallback: treat it as a file path.
    return URL(fileURLWithPath: trimmed)
}

func makeURLHash(_ folderURL: URL) -> Int64 {
    return hashStringToInt64(folderURL.normalizedWithoutTrailingSlash.absoluteString)
}

func makeBookmarkKey(_ folderURL: URL) -> String {
    return String(makeURLHash(folderURL))
}

extension URL {
    /// Returns a normalized URL with no trailing slash in its path (unless it's just "/" for root).
    var normalizedWithoutTrailingSlash: URL {
        // Standardize the URL first
        let standardizedURL = self.standardized
        // Use URLComponents to safely modify the path
        guard var components = URLComponents(url: standardizedURL, resolvingAgainstBaseURL: false)
        else {
            return standardizedURL
        }

        // Only modify if the path isn’t root and ends with a slash
        if components.path != "/" && components.path.hasSuffix("/") {
            // Remove all trailing slashes (leaving at least one character)
            while components.path.count > 1 && components.path.hasSuffix("/") {
                components.path.removeLast()
            }
        }

        return components.url ?? standardizedURL
    }
}

actor DefaultSourceSyncService: SourceSyncService {
    let logger = Logger(subsystem: subsystem, category: "SourceSyncService")

    let sourceRepository: SourceRepository
    let sourcePathRepository: SourcePathRepository
    let sourcePathSearchRepository: SourcePathSearchRepository

    init(
        sourceRepository: SourceRepository,
        sourcePathSearchRepository: SourcePathSearchRepository,
        sourcePathRepository: SourcePathRepository
    ) {
        self.sourceRepository = sourceRepository
        self.sourcePathRepository = sourcePathRepository
        self.sourcePathSearchRepository = sourcePathSearchRepository
    }

    func syncDir(
        sourceId: Int64, folderURL: URL, onCurrentURL: ((_ url: URL?) -> Void)?,
        onSetLoading: ((_ loading: Bool) -> Void)?
    ) async throws
        -> Source?
    {
        logger.debug("starting to collect items")
        do {
            onSetLoading?(true)
            defer { onSetLoading?(false) }
            let result = try await syncDirInner(
                folderURL: folderURL, onCurrentURL: onCurrentURL, onSetLoading: onSetLoading)
            let runId = Int64(Date().timeIntervalSince1970 * 1000)

            let itemsToCreate = result?.allItems.map { x in
                var parentPathId: Int64? = nil
                if let parentURL = x.parentURL {
                    parentPathId = makeURLHash(parentURL)
                    logger.debug(
                        "\(x.url) is creating parent path [\(parentPathId ?? -1)]: \(parentURL.absoluteString)"
                    )
                }
                let pathId = makeURLHash(x.url)
                return SourcePath(
                    id: nil,
                    sourceId: sourceId,
                    pathId: pathId,
                    parentPathId: parentPathId,
                    name: x.name,
                    relativePath: x.relativePath,
                    isDirectory: x.isDirectory,
                    fileHashSHA256: nil,
                    runId: runId,
                    createdAt: Date(),
                    updatedAt: nil
                )
            }

            let items = itemsToCreate ?? []
            let numberOfItemsToUpsert = items.count

            logger.debug("upserting \(numberOfItemsToUpsert) items")
            try await sourcePathRepository.batchUpsert(paths: items)
            try await sourcePathSearchRepository.batchUpsertIntoFTS(paths: items)

            logger.debug("removing stale paths...")
            let deletedCount = try await sourcePathRepository.deleteMany(
                sourceId: sourceId, excludingRunId: runId)
            try await sourcePathSearchRepository.batchDeleteFTS(
                sourceId: sourceId, excludingRunId: runId)
            logger.debug("removed \(deletedCount) stale paths")

            if let result = result {
                let totalAudioFiles = result.totalAudioFiles
                logger.debug("updating source \(sourceId)")
                if var lib = try await sourceRepository.getOne(id: sourceId) {
                    lib.lastSyncedAt = Date()
                    lib.updatedAt = Date()
                    lib.totalPaths = totalAudioFiles
                    return try await sourceRepository.updateSource(source: lib)
                } else {
                    logger.error("for some reason source \(sourceId) wasn't found")
                }
            }

            if var lib = try await sourceRepository.getOne(id: sourceId) {
                lib.lastSyncedAt = Date()
                lib.updatedAt = Date()
                lib.totalPaths = result?.totalAudioFiles ?? 0  // Ensure totalPaths is set
                return try await sourceRepository.updateSource(source: lib)
            }
            return nil
        } catch {
            logger.error("sync dir error: \(error)")
            if var lib = try await sourceRepository.getOne(id: sourceId) {
                lib.lastSyncedAt = Date()
                lib.updatedAt = Date()
                lib.syncError = "\(error)"
                return try await sourceRepository.updateSource(source: lib)
            }
            return nil
        }
    }

    func syncDirInner(
        folderURL: URL,
        onCurrentURL: ((_ url: URL) -> Void)?,
        onSetLoading: ((_ loading: Bool) -> Void)?
    ) async throws
        -> SourceSyncResult?
    {
        var audioURLs: [SourceSyncResultItem] = []
        var result = [String: SourceSyncResultItem]()
        let bookmarkKey = makeBookmarkKey(folderURL)
        let audioExtensions = ["mp3", "wav", "m4a", "flac", "aac", "aiff", "aif"]
        guard let bookmarkData = UserDefaults.standard.data(forKey: bookmarkKey) else {
            throw CustomError.genericError("no bookmark found, pick folder")
        }

        var isStale = false
        do {
            let folderURL = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale)

            if isStale {
                // The bookmark is stale, so we need a new one
                throw CustomError.genericError(
                    "Bookmark is stale, user needs to pick folder again.")
            }

            // Start accessing security-scoped resource
            guard folderURL.startAccessingSecurityScopedResource() else {
                throw CustomError.genericError("Couldn't start accessing security scoped resource.")
            }
            defer { folderURL.stopAccessingSecurityScopedResource() }

            // Now we can scan the folder
            if let enumerator = FileManager.default.enumerator(
                at: folderURL, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            {
                for case let file as URL in enumerator {
                    do {
                        onCurrentURL?(file)
                        let resourceValues = try file.resourceValues(forKeys: [.isDirectoryKey])
                        if resourceValues.isDirectory == false,  // file.pathExtension.lowercased() == "mp3"
                            audioExtensions.contains(file.pathExtension.lowercased())
                        {
                            let resultItem = SourceSyncResultItem(
                                rootURL: folderURL, current: file, isDirectory: false)
                            audioURLs.append(resultItem)
                            result[FileHelper(fileURL: file).toString()] = resultItem
                        } else {
                            let resultItem = SourceSyncResultItem(
                                rootURL: folderURL, current: file, isDirectory: true)
                            result[FileHelper(fileURL: file).toString()] = resultItem
                        }
                    } catch {
                        logger.error("Error reading resource values: \(error)")
                    }
                }
                logger.debug("Total audio files found: \(audioURLs.count)")
                return SourceSyncResult(
                    allItems: Array(result.values), audioFiles: audioURLs,
                    totalAudioFiles: audioURLs.count)
            } else {
                throw CustomError.genericError("failed to get enumerator")
            }
        } catch {
            throw CustomError.genericError("error resolving bookmark: \(error)")
        }
    }
}

protocol SourceService {
    func registerSourcePath(userId: Int64, path: String, type: SourceType) async throws -> Source
    func getCurrentSource(userId: Int64) async throws -> Source?
    func syncService() -> SourceSyncService
    func importService() -> SourceImportService
    func repository() -> SourceRepository
}

class DefaultSourceService: SourceService {
    func importService() -> any SourceImportService {
        return sourceImportService
    }

    let logger = Logger(subsystem: subsystem, category: "SourceService")

    func repository() -> SourceRepository {
        return sourceRepo
    }

    func getCurrentSource(userId: Int64) async throws -> Source? {
        let sources = try await sourceRepo.findOneByUserId(userId: userId, path: nil)
        if sources.count == 0 {
            return nil
        } else if let lib = sources.first(where: { $0.isCurrent }) {
            return lib
        } else {
            let lib = sources[0]
            return try await sourceRepo.setCurrentSource(userId: userId, sourceId: lib.id!)
        }
    }

    func registerSourcePath(userId: Int64, path: String, type: SourceType) async throws -> Source {
        let source = try await sourceRepo.findOneByUserId(userId: userId, path: path)
        if source.count == 0 {
            logger.debug("no source found, creating new one")
            let pathId = makeURLHash(makeURLFromString(path))
            let src = Source(
                id: nil, dirPath: path, pathId: pathId, userId: userId, type: type, totalPaths: nil,
                syncError: nil,
                isCurrent: true, createdAt: Date(), lastSyncedAt: nil, updatedAt: nil)
            let source = try await sourceRepo.create(source: src)
            logger.debug("updating current switch")
            let lib2 = try await sourceRepo.setCurrentSource(
                userId: userId, sourceId: source.id!)
            return lib2
        } else if !source[0].isCurrent {
            logger.debug("source is found, but it's not current")
            let lib2 = try await sourceRepo.setCurrentSource(
                userId: userId, sourceId: source[0].id!)
            return lib2
        } else {
            return source[0]
        }
    }

    func syncService() -> SourceSyncService {
        return sourceSyncService
    }

    private var sourceRepo: SourceRepository
    private var sourceImportService: SourceImportService
    private var sourceSyncService: SourceSyncService

    init(
        sourceRepo: SourceRepository, sourceSyncService: SourceSyncService,
        sourceImportService: SourceImportService
    ) {
        self.sourceRepo = sourceRepo
        self.sourceSyncService = sourceSyncService
        self.sourceImportService = sourceImportService
    }

}

protocol SourcePathRepository {
    func getByParentId(sourceId: Int64, parentPathId: Int64?) async throws -> [SourcePath]
    func getByPathId(sourceId: Int64, pathId: Int64) async throws -> SourcePath?
    func create(path: SourcePath) async throws -> SourcePath
    func updateFileHash(pathId: Int64, fileHash: Data?) async throws
    func deleteMany(sourceId: Int64) async throws
    func getByParentId(parentId: Int64) async throws -> [SourcePath]
    func getByPath(relativePath: String, sourceId: Int64) async throws -> SourcePath?
    func batchUpsert(paths: [SourcePath]) async throws
    func deleteMany(sourceId: Int64, excludingRunId: Int64) async throws -> Int
    func deleteAllPaths(sourceId: Int64) async throws
}

protocol SourceRepository {
    func deleteSource(sourceId: Int64) async throws
    func create(source: Source) async throws -> Source
    func findOneByUserId(userId: Int64, path: String?) async throws -> [Source]
    func getOne(id: Int64) async throws -> Source?
    func updateSource(source: Source) async throws -> Source
    // needs to set isCurrent true to the source with userId
    // and for the rest of users libraries set isCurrentFalse
    func setCurrentSource(userId: Int64, sourceId: Int64) async throws -> Source
}

protocol UserRepository {
    func findByIcloudId(icloudId: Int64) async throws -> User?
    func create(user: User) async throws -> User
}

protocol UserService {
    func getOrCreateUser(icloudId: Int64) async throws -> User
}

protocol UserCloudService {
    func resolveCurrentICloudUser() async throws -> User?
}

protocol ICloudProvider {
    func getCurrentICloudUserID() async throws -> Int64?
    func isICloudAvailable() -> Bool
}

class DefaultICloudProvider: ICloudProvider {
    let logger = Logger(subsystem: subsystem, category: "ICloudProvider")
    func isICloudAvailable() -> Bool {
        return FileManager.default.ubiquityIdentityToken != nil
    }

    func getCurrentICloudUserID() async throws -> Int64? {
        logger.debug("Attempting to get current iCloud user")
        if let ubiquityIdentityToken = FileManager.default.ubiquityIdentityToken {
            let tokenData = try NSKeyedArchiver.archivedData(
                withRootObject: ubiquityIdentityToken, requiringSecureCoding: true)
            let tokenString = tokenData.base64EncodedString()
            let hashed = hashStringToInt64(tokenString)
            logger.debug("Current iCloud user token: \(hashed)")
            return hashed
        } else {
            logger.debug("No iCloud account is signed in.")
            return nil
        }
    }

}

class DefaultUserCloudService: UserCloudService {
    let logger = Logger(subsystem: subsystem, category: "UserCloudService")
    func resolveCurrentICloudUser() async throws -> User? {
        if let icloudId = try await iCloudProvider.getCurrentICloudUserID() {
            logger.debug("found cloudID \(icloudId)")
            return try await userService.getOrCreateUser(icloudId: icloudId)
        }
        return nil
    }

    private let userService: UserService
    private let iCloudProvider: ICloudProvider

    public init(userService: UserService, iCloudProvider: ICloudProvider) {
        self.userService = userService
        self.iCloudProvider = iCloudProvider
    }
}

class DefaultUserService: UserService {
    let logger = Logger(subsystem: subsystem, category: "UserService")
    private var userRepository: UserRepository

    func getOrCreateUser(icloudId: Int64) async throws -> User {
        let logger = self.logger
        if let existingUser = try await userRepository.findByIcloudId(icloudId: icloudId) {
            let userId = existingUser.id ?? -1
            logger.debug("found user \(userId) with \(icloudId)")
            return existingUser
        } else {
            let user = User(id: nil, icloudId: icloudId)
            logger.debug("need to setup new user for \(icloudId)")
            return try await userRepository.create(user: user)
        }
    }

    public init(userRepository: UserRepository) {
        self.userRepository = userRepository
    }
}

enum NotImplementedError: Error {
    case featureNotImplemented(message: String)
}

let usersTableName = "users"

actor SQLiteUserRepository: UserRepository {
    let logger = Logger(subsystem: subsystem, category: "SQLiteUserRepository")

    func findByIcloudId(icloudId: Int64) throws -> User? {
        if let row = try db.pluck(table.filter(colIcloudId == icloudId)) {
            return User(id: row[colId], icloudId: row[colIcloudId])
        }
        return nil
    }

    func create(user: User) throws -> User {
        let insert = table.insert(colIcloudId <- user.icloudId)
        let rowId = try db.run(insert)
        logger.debug("inserted user \(rowId)")
        return User(id: rowId, icloudId: user.icloudId)
    }

    init(db: Connection) throws {
        let colId: SQLite.Expression<Int64> = Expression<Int64>("id")
        let colIcloudId: SQLite.Expression<Int64> = Expression<UInt64>("icloudId")
        try db.run(
            table.create(ifNotExists: true) { t in
                t.column(colId, primaryKey: .autoincrement)
                t.column(colIcloudId, unique: true)
            })
        logger.debug("created table: \(usersTableName)")
        self.db = db
        self.colId = colId
        self.colIcloudId = colIcloudId
    }

    let db: Connection

    private let table = Table(usersTableName)
    private let colId: SQLite.Expression<Int64>
    private let colIcloudId: SQLite.Expression<Int64>
}

actor SQLiteSourceRepository: SourceRepository {
    private let db: Connection
    private let table = Table("sources")

    // Add type column
    private var colType: SQLite.Expression<String?>
    private var colId: SQLite.Expression<Int64>
    private var colDirPath: SQLite.Expression<String>
    private var colPathId: SQLite.Expression<Int64>
    private var colUserId: SQLite.Expression<Int64>
    private var colTotalPaths: SQLite.Expression<Int?>
    private var colSyncError: SQLite.Expression<String?>
    private var colIsCurrent: SQLite.Expression<Bool>
    private var colCreatedAt: SQLite.Expression<Date>
    private var colLastSyncedAt: SQLite.Expression<Date?>
    private var colUpdatedAt: SQLite.Expression<Date?>

    private let logger = Logger(subsystem: subsystem, category: "SQLiteSourceRepository")

    init(db: Connection) throws {
        // Existing columns
        let colId = SQLite.Expression<Int64>("id")
        let colDirPath = SQLite.Expression<String>("dirPath")
        let colPathId = SQLite.Expression<Int64>("pathId")
        let colUserId = SQLite.Expression<Int64>("userId")
        let colTotalPaths = SQLite.Expression<Int?>("totalPaths")
        let colSyncError = SQLite.Expression<String?>("syncError")
        let colIsCurrent = SQLite.Expression<Bool>("isCurrent")
        let colCreatedAt = SQLite.Expression<Date>("createdAt")
        let colLastSyncedAt = SQLite.Expression<Date?>("lastSyncedAt")
        let colUpdatedAt = SQLite.Expression<Date?>("updatedAt")
        let colType = SQLite.Expression<String?>("type")

        self.db = db

        // Create table with new column
        try db.run(
            table.create(ifNotExists: true) { t in
                t.column(colId, primaryKey: .autoincrement)
                t.column(colDirPath)
                t.column(colPathId)
                t.column(colUserId)
                t.column(colType)
                t.column(colTotalPaths)
                t.column(colSyncError)
                t.column(colIsCurrent)
                t.column(colCreatedAt)
                t.column(colLastSyncedAt)
                t.column(colUpdatedAt)
            })

        self.colId = colId
        self.colDirPath = colDirPath
        self.colPathId = colPathId
        self.colUserId = colUserId
        self.colTotalPaths = colTotalPaths
        self.colSyncError = colSyncError
        self.colIsCurrent = colIsCurrent
        self.colCreatedAt = colCreatedAt
        self.colLastSyncedAt = colLastSyncedAt
        self.colUpdatedAt = colUpdatedAt
        self.colType = colType
    }

    func deleteSource(sourceId: Int64) async throws {
        let query = table.filter(colId == sourceId)
        try db.run(query.delete())
        logger.debug("Deleted source with ID: \(sourceId)")
    }

    func getOne(id: Int64) async throws -> Source? {
        let query = table.filter(colId == id)
        if let row = try db.pluck(query) {
            return Source(
                id: row[colId],
                dirPath: row[colDirPath],
                pathId: row[colPathId],
                userId: row[colUserId],
                type: row[colType].flatMap(SourceType.init(rawValue:)),  // Map from String?
                totalPaths: row[colTotalPaths],
                syncError: row[colSyncError],
                isCurrent: row[colIsCurrent],
                createdAt: row[colCreatedAt],
                lastSyncedAt: row[colLastSyncedAt],
                updatedAt: row[colUpdatedAt]
            )
        }
        return nil
    }

    func create(source: Source) async throws -> Source {
        // Force explicit type setting (even if nil)
        let insert = table.insert(
            colDirPath <- source.dirPath,
            colPathId <- source.pathId,
            colUserId <- source.userId,
            colType <- source.type?.rawValue,  // Explicit null if type is nil
            colTotalPaths <- source.totalPaths,
            colSyncError <- source.syncError,
            colIsCurrent <- source.isCurrent,
            colCreatedAt <- source.createdAt,
            colLastSyncedAt <- source.lastSyncedAt,
            colUpdatedAt <- source.updatedAt
        )

        let rowId = try db.run(insert)
        logger.debug("Inserted source with ID: \(rowId)")

        return Source(
            id: rowId,
            dirPath: source.dirPath,
            pathId: source.pathId,
            userId: source.userId,
            type: source.type,  // Preserve original type
            totalPaths: source.totalPaths,
            syncError: source.syncError,
            isCurrent: source.isCurrent,
            createdAt: source.createdAt,
            lastSyncedAt: source.lastSyncedAt,
            updatedAt: source.updatedAt
        )
    }

    func findOneByUserId(userId: Int64, path: String?) async throws -> [Source] {
        var predicate = colUserId == userId
        if let path = path {
            predicate = predicate && colDirPath == path
        }

        return try db.prepare(table.filter(predicate)).map { row in
            Source(
                id: row[colId],
                dirPath: row[colDirPath],
                pathId: row[colPathId],
                userId: row[colUserId],
                type: row[colType].flatMap(SourceType.init(rawValue:)),
                totalPaths: row[colTotalPaths],
                syncError: row[colSyncError],
                isCurrent: row[colIsCurrent],
                createdAt: row[colCreatedAt],
                lastSyncedAt: row[colLastSyncedAt],
                updatedAt: row[colUpdatedAt]
            )
        }
    }

    func updateSource(source: Source) async throws -> Source {
        guard let sourceId = source.id else {
            throw NSError(domain: "Invalid source ID", code: 0, userInfo: nil)
        }

        let query = table.filter(colId == sourceId)
        try db.run(
            query.update(
                colDirPath <- source.dirPath,
                colPathId <- source.pathId,
                colType <- source.type?.rawValue,
                colTotalPaths <- source.totalPaths,
                colSyncError <- source.syncError,
                colIsCurrent <- source.isCurrent,
                colLastSyncedAt <- source.lastSyncedAt,
                colUpdatedAt <- source.updatedAt
            ))

        return source
    }

    func setCurrentSource(userId: Int64, sourceId: Int64) async throws -> Source {
        try db.transaction {
            try db.run(table.filter(colUserId == userId).update(colIsCurrent <- false))
            try db.run(table.filter(colId == sourceId).update(colIsCurrent <- true))
        }

        guard let row = try db.pluck(table.filter(colId == sourceId)) else {
            throw NSError(domain: "Source not found", code: 0, userInfo: nil)
        }

        return Source(
            id: row[colId],
            dirPath: row[colDirPath],
            pathId: row[colPathId],
            userId: row[colUserId],
            type: row[colType].flatMap(SourceType.init(rawValue:)),
            totalPaths: row[colTotalPaths],
            syncError: row[colSyncError],
            isCurrent: row[colIsCurrent],
            createdAt: row[colCreatedAt],
            lastSyncedAt: row[colLastSyncedAt],
            updatedAt: row[colUpdatedAt]
        )
    }
}

actor SQLiteSourcePathRepository: SourcePathRepository {
    private let db: Connection
    private let table = Table("source_paths")

    private let colId: SQLite.Expression<Int64>
    private let colSourceId: SQLite.Expression<Int64>
    private let colPathId: SQLite.Expression<Int64>
    private let colParentPathId: SQLite.Expression<Int64?>
    private let colName: SQLite.Expression<String>
    private let colRelativePath: SQLite.Expression<String>
    private let colIsDirectory: SQLite.Expression<Bool>
    private let colFileHashSHA256: SQLite.Expression<Data?>
    private let colRunId: SQLite.Expression<Int64>
    private let colCreatedAt: SQLite.Expression<Date>
    private let colUpdatedAt: SQLite.Expression<Date?>

    private let logger = Logger(subsystem: subsystem, category: "SQLiteSourcePathRepository")

    func getByPathId(sourceId: Int64, pathId: Int64) async throws -> SourcePath? {
        let query = table.filter(colSourceId == sourceId && colPathId == pathId)
        if let row = try db.pluck(query) {
            return SourcePath(
                id: row[colId],
                sourceId: row[colSourceId],
                pathId: row[colPathId],
                parentPathId: row[colParentPathId],
                name: row[colName],
                relativePath: row[colRelativePath],
                isDirectory: row[colIsDirectory],
                fileHashSHA256: row[colFileHashSHA256],
                runId: row[colRunId],
                createdAt: row[colCreatedAt],
                updatedAt: row[colUpdatedAt]
            )
        }
        return nil
    }

    func deleteAllPaths(sourceId: Int64) async throws {
        let query = table.filter(colSourceId == sourceId)
        try db.run(query.delete())
        logger.debug("Deleted all paths for source: \(sourceId)")
    }

    func getByParentId(sourceId: Int64, parentPathId: Int64?) async throws -> [SourcePath] {
        let rows: AnySequence<Row>
        if let parentId = parentPathId {
            let query = table.filter(colSourceId == sourceId && colParentPathId == parentId)
            rows = try db.prepare(query)
        } else {
            let query = table.filter(colSourceId == sourceId)
            rows = try db.prepare(query)
        }
        return rows.map { row in
            SourcePath(
                id: row[colId],
                sourceId: row[colSourceId],
                pathId: row[colPathId],
                parentPathId: row[colParentPathId],
                name: row[colName],
                relativePath: row[colRelativePath],
                isDirectory: row[colIsDirectory],
                fileHashSHA256: row[colFileHashSHA256],
                runId: row[colRunId],
                createdAt: row[colCreatedAt],
                updatedAt: row[colUpdatedAt]
            )
        }
    }
    // MARK: - Initializer
    init(db: Connection) throws {
        let colId = SQLite.Expression<Int64>("id")
        let colSourceId = SQLite.Expression<Int64>("sourceId")
        let colPathId = SQLite.Expression<Int64>("pathId")
        let colParentPathId = SQLite.Expression<Int64?>("parentPathId")
        let colName = SQLite.Expression<String>("name")
        let colRelativePath = SQLite.Expression<String>("relativePath")
        let colIsDirectory = SQLite.Expression<Bool>("isDirectory")
        let colFileHashSHA256 = SQLite.Expression<Data?>("fileHashSHA256")
        let colRunId = SQLite.Expression<Int64>("runId")
        let colCreatedAt = SQLite.Expression<Date>("createdAt")
        let colUpdatedAt = SQLite.Expression<Date?>("updatedAt")

        self.db = db

        try db.run(
            table.create(ifNotExists: true) { t in
                t.column(colId, primaryKey: .autoincrement)
                t.column(colSourceId)
                t.column(colPathId)
                t.column(colParentPathId)
                t.column(colName)
                t.column(colRelativePath)
                t.column(colIsDirectory)
                t.column(colFileHashSHA256)
                t.column(colRunId)
                t.column(colCreatedAt)
                t.column(colUpdatedAt)
            }
        )
        logger.debug("Created table: source_paths")

        self.colId = colId
        self.colSourceId = colSourceId
        self.colPathId = colPathId
        self.colParentPathId = colParentPathId
        self.colName = colName
        self.colRelativePath = colRelativePath
        self.colIsDirectory = colIsDirectory
        self.colFileHashSHA256 = colFileHashSHA256
        self.colRunId = colRunId
        self.colCreatedAt = colCreatedAt
        self.colUpdatedAt = colUpdatedAt
    }
    func deleteMany(sourceId: Int64, excludingRunId: Int64) async throws -> Int {
        let query = table.filter(colSourceId == sourceId && colRunId != excludingRunId)
        let count = try db.run(query.delete())
        logger.debug(
            "Deleted \(count) source paths for sourceId: \(sourceId) excluding runId: \(excludingRunId)"
        )
        return count
    }
    // MARK: - Create
    func create(path: SourcePath) async throws -> SourcePath {
        let insert = table.insert(
            colSourceId <- path.sourceId,
            colPathId <- path.pathId,
            colParentPathId <- path.parentPathId,
            colName <- path.name,
            colRelativePath <- path.relativePath,
            colIsDirectory <- path.isDirectory,
            colFileHashSHA256 <- path.fileHashSHA256,
            colRunId <- path.runId,
            colCreatedAt <- path.createdAt,
            colUpdatedAt <- path.updatedAt
        )
        let rowId = try db.run(insert)
        logger.debug("Inserted source path with ID: \(rowId)")
        return path.copyWith(id: rowId)
    }

    // MARK: - Update File Hash
    func updateFileHash(pathId: Int64, fileHash: Data?) async throws {
        let query = table.filter(colPathId == pathId)
        try db.run(query.update(colFileHashSHA256 <- fileHash))
        logger.debug("Updated file hash for path ID: \(pathId)")
    }

    // MARK: - Delete Many
    func deleteMany(sourceId: Int64) async throws {
        let query = table.filter(colSourceId == sourceId)
        let count = try db.run(query.delete())
        logger.debug("Deleted \(count) source paths for source ID: \(sourceId)")
    }

    // MARK: - Get By Parent ID
    func getByParentId(parentId: Int64) async throws -> [SourcePath] {
        try db.prepare(table.filter(colParentPathId == parentId)).map { row in
            SourcePath(
                id: row[colId],
                sourceId: row[colSourceId],
                pathId: row[colPathId],
                parentPathId: row[colParentPathId],
                name: row[colName],
                relativePath: row[colRelativePath],
                isDirectory: row[colIsDirectory],
                fileHashSHA256: row[colFileHashSHA256],
                runId: row[colRunId],
                createdAt: row[colCreatedAt],
                updatedAt: row[colUpdatedAt]
            )
        }
    }

    // MARK: - Get By Path
    func getByPath(relativePath: String, sourceId: Int64) async throws -> SourcePath? {
        let query = table.filter(colRelativePath == relativePath && colSourceId == sourceId)
        if let row = try db.pluck(query) {
            return SourcePath(
                id: row[colId],
                sourceId: row[colSourceId],
                pathId: row[colPathId],
                parentPathId: row[colParentPathId],
                name: row[colName],
                relativePath: row[colRelativePath],
                isDirectory: row[colIsDirectory],
                fileHashSHA256: row[colFileHashSHA256],
                runId: row[colRunId],
                createdAt: row[colCreatedAt],
                updatedAt: row[colUpdatedAt]
            )
        }
        return nil
    }

    func batchUpsert(paths: [SourcePath]) async throws {
        if paths.count == 0 {
            return
        }
        try db.transaction {
            for path in paths {
                let query = table.filter(colSourceId == path.sourceId && colPathId == path.pathId)
                if (try db.pluck(query)) != nil {
                    // Update existing record
                    try db.run(
                        query.update(
                            colParentPathId <- path.parentPathId,
                            colName <- path.name,
                            colRelativePath <- path.relativePath,
                            colIsDirectory <- path.isDirectory,
                            colFileHashSHA256 <- path.fileHashSHA256,
                            colRunId <- path.runId,
                            colUpdatedAt <- path.updatedAt
                        ))
                    logger.debug(
                        "Updated source path with sourceId: \(path.sourceId), pathId: \(path.pathId)"
                    )
                } else {
                    // Insert new record
                    try db.run(
                        table.insert(
                            colSourceId <- path.sourceId,
                            colPathId <- path.pathId,
                            colParentPathId <- path.parentPathId,
                            colName <- path.name,
                            colRelativePath <- path.relativePath,
                            colIsDirectory <- path.isDirectory,
                            colFileHashSHA256 <- path.fileHashSHA256,
                            colRunId <- path.runId,
                            colCreatedAt <- path.createdAt,
                            colUpdatedAt <- path.updatedAt
                        ))
                    logger.debug(
                        "Inserted new source path with sourceId: \(path.sourceId), pathId: \(path.pathId)"
                    )
                }
            }
        }
    }
}

// Helper extension for copying with new ID
extension SourcePath {
    func copyWith(id: Int64?) -> SourcePath {
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

actor SQLiteSourcePathSearchRepository: SourcePathSearchRepository {
    func search(sourceId: Int64, query: String, limit: Int) async throws -> [PathSearchResult] {
        let processedQuery = preprocessFTSQuery(query)

        let sql = """
            SELECT pathId, bm25(source_paths_fts) AS rank
            FROM source_paths_fts
            WHERE source_paths_fts MATCH ?
                AND sourceId = ?
            ORDER BY rank
            LIMIT ?;
            """

        var results: [PathSearchResult] = []
        for row in try db.prepare(sql, processedQuery, sourceId, limit) {
            let pathId = row[0] as? Int64 ?? 0
            let rank = row[1] as? Double ?? 0.0
            results.append(PathSearchResult(pathId: pathId, rank: rank))
        }
        return results
    }

    func deleteAllFTS(sourceId: Int64) async throws {
        let query = ftsTable.filter(colFtsSourceId == sourceId)
        try db.run(query.delete())
        logger.debug("Deleted all FTS entries for source: \(sourceId)")
    }

    private let logger = Logger(subsystem: subsystem, category: "SourcePathSearchRepository")

    // MARK: - Batch Delete by sourceId, excluding runId
    func batchDeleteFTS(sourceId: Int64, excludingRunId: Int64) async throws {
        // Delete all rows with this sourceId where runId != excludingRunId
        let query = ftsTable.filter(
            colFtsSourceId == sourceId && colFtsRunId != excludingRunId
        )
        try db.transaction {
            try db.run(query.delete())
        }
    }

    // MARK: - Batch Upsert
    /// If `(sourceId, pathId)` already exists, we update `runId`, `fullPath`, `fileName`.
    /// Otherwise, we insert a new row.
    func batchUpsertIntoFTS(paths: [SourcePath]) async throws {
        guard !paths.isEmpty else { return }

        try db.transaction {
            for path in paths {
                let existingQuery = self.ftsTable.filter(
                    self.colFtsPathId == path.pathId && self.colFtsSourceId == path.sourceId
                )
                if try db.pluck(existingQuery) != nil {
                    // Update
                    try db.run(
                        existingQuery.update(
                            self.colFtsRunId <- path.runId,
                            self.colFtsFullPath <- path.relativePath,
                            self.colFtsFileName <- path.name
                        )
                    )
                } else {
                    // Insert
                    try db.run(
                        self.ftsTable.insert(
                            self.colFtsPathId <- path.pathId,
                            self.colFtsSourceId <- path.sourceId,
                            self.colFtsRunId <- path.runId,
                            self.colFtsFullPath <- path.relativePath,
                            self.colFtsFileName <- path.name
                        )
                    )
                }
            }
        }
    }
    private let db: Connection
    private let ftsTable = Table("source_paths_fts")
    private let colFtsPathId = SQLite.Expression<Int64>("pathId")
    private let colFtsSourceId = SQLite.Expression<Int64>("sourceId")
    private let colFtsRunId = SQLite.Expression<Int64>("runId")
    private let colFtsFullPath = SQLite.Expression<String>("fullPath")
    private let colFtsFileName = SQLite.Expression<String>("fileName")

    init(db: Connection) throws {
        self.db = db
        try db.execute(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS source_paths_fts
            USING fts5(
                pathId UNINDEXED,
                sourceId UNINDEXED,
                runId UNINDEXED,
                fullPath,
                fileName,
                tokenize='unicode61'
            );
            """)
    }

}

actor SQLiteSongRepository: SongRepository {
    func updateBookmark(songId: Int64, bookmark: Data) async throws {
        let query = songsTable.filter(colId == songId)
        try db.run(query.update(colBookmark <- Blob(bytes: [UInt8](bookmark))))
    }

    private let db: Connection

    // MARK: - Main "songs" table
    private let songsTable = Table("songs")

    // Typed columns
    private let colId: SQLite.Expression<Int64>
    private let colSongKey: SQLite.Expression<Int64>
    private let colArtist: SQLite.Expression<String>
    private let colTitle: SQLite.Expression<String>
    private let colAlbum: SQLite.Expression<String>
    private let colAlbumArtist: SQLite.Expression<String>  // NEW
    private let colReleaseYear: SQLite.Expression<Int?>  // NEW
    private let colDiscNumber: SQLite.Expression<Int?>  // NEW
    private let colTrackNumber: SQLite.Expression<Int?>
    private let colCoverArtPath: SQLite.Expression<String?>
    private let colBookmark: SQLite.Expression<Blob?>
    private let colPathHash: SQLite.Expression<Int64>
    private let colCreatedAt: SQLite.Expression<Double>
    private let colUpdatedAt: SQLite.Expression<Double?>

    // MARK: - FTS table
    private let ftsSongsTable = Table("songs_fts")
    private let colFtsSongId = SQLite.Expression<Int64>("songId")
    private let colFtsArtist = SQLite.Expression<String>("artist")
    private let colFtsTitle = SQLite.Expression<String>("title")
    private let colFtsAlbum = SQLite.Expression<String>("album")
    private let colFtsAlbumArtist = SQLite.Expression<String>("albumArtist")  // NEW

    // MARK: - Init
    init(db: Connection) throws {
        self.db = db

        // Initialize typed column expressions
        let colId = SQLite.Expression<Int64>("id")
        let colSongKey = SQLite.Expression<Int64>("songKey")
        let colArtist = SQLite.Expression<String>("artist")
        let colTitle = SQLite.Expression<String>("title")
        let colAlbum = SQLite.Expression<String>("album")
        let colAlbumArtist = SQLite.Expression<String>("albumArtist")  // NEW
        let colReleaseYear = SQLite.Expression<Int?>("releaseYear")  // NEW
        let colDiscNumber = SQLite.Expression<Int?>("discNumber")  // NEW
        let colTrackNumber = SQLite.Expression<Int?>("trackNumber")
        let colCoverArtPath = SQLite.Expression<String?>("coverArtPath")
        let colBookmark = SQLite.Expression<Blob?>("bookmark")
        let colPathHash = SQLite.Expression<Int64>("pathHash")
        let colCreatedAt = SQLite.Expression<Double>("createdAt")
        let colUpdatedAt = SQLite.Expression<Double?>("updatedAt")

        self.colId = colId
        self.colSongKey = colSongKey
        self.colArtist = colArtist
        self.colTitle = colTitle
        self.colAlbum = colAlbum
        self.colAlbumArtist = colAlbumArtist  // NEW
        self.colReleaseYear = colReleaseYear  // NEW
        self.colDiscNumber = colDiscNumber  // NEW
        self.colTrackNumber = colTrackNumber
        self.colCoverArtPath = colCoverArtPath
        self.colBookmark = colBookmark
        self.colPathHash = colPathHash
        self.colCreatedAt = colCreatedAt
        self.colUpdatedAt = colUpdatedAt

        // Create main table if needed
        try db.run(
            songsTable.create(ifNotExists: true) { t in
                t.column(colId, primaryKey: .autoincrement)
                t.column(colSongKey)
                t.column(colArtist)
                t.column(colTitle)
                t.column(colAlbum)
                t.column(colAlbumArtist)  // NEW
                t.column(colReleaseYear)  // NEW
                t.column(colDiscNumber)  // NEW
                t.column(colTrackNumber)
                t.column(colCoverArtPath)
                t.column(colBookmark)
                t.column(colPathHash)
                t.column(colCreatedAt)
                t.column(colUpdatedAt)
            }
        )

        // Create FTS table with albumArtist column included
        try db.execute(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS songs_fts
            USING fts5(
                songId UNINDEXED,
                artist,
                title,
                album,
                albumArtist,  -- NEW
                tokenize='unicode61'
            );
            """
        )
    }

    func getSongs(ids: [Int64]) async -> [Song] {
        let query = songsTable.filter(ids.contains(colId))
        return try! db.prepare(query).map { row in
            Song(
                id: row[colId],
                songKey: row[colSongKey],
                artist: row[colArtist],
                title: row[colTitle],
                album: row[colAlbum],
                albumArtist: row[colAlbumArtist],  // NEW
                releaseYear: row[colReleaseYear],  // NEW
                discNumber: row[colDiscNumber],  // NEW
                trackNumber: row[colTrackNumber],
                coverArtPath: row[colCoverArtPath],
                bookmark: (row[colBookmark]?.bytes).map { Data($0) },
                pathHash: row[colPathHash],
                createdAt: Date(timeIntervalSince1970: row[colCreatedAt]),
                updatedAt: row[colUpdatedAt].map(Date.init(timeIntervalSince1970:))
            )
        }
    }

    func getSongByURL(_ url: URL) async -> Song? {
        let pathHash = makeURLHash(url)
        let query = songsTable.filter(colPathHash == pathHash)
        return try? db.pluck(query).map { row in
            Song(
                id: row[colId],
                songKey: row[colSongKey],
                artist: row[colArtist],
                title: row[colTitle],
                album: row[colAlbum],
                albumArtist: row[colAlbumArtist],  // NEW
                releaseYear: row[colReleaseYear],  // NEW
                discNumber: row[colDiscNumber],  // NEW
                trackNumber: row[colTrackNumber],
                coverArtPath: row[colCoverArtPath],
                bookmark: (row[colBookmark]?.bytes).map { Data($0) },
                pathHash: row[colPathHash],
                createdAt: Date(timeIntervalSince1970: row[colCreatedAt]),
                updatedAt: row[colUpdatedAt].map(Date.init(timeIntervalSince1970:))
            )
        }
    }

    func totalSongCount(query: String) async throws -> Int {
        if query.isEmpty {
            let countQuery = "SELECT COUNT(*) FROM songs;"
            var count: Int = 0
            for row in try db.prepare(countQuery) {
                if let c = row[0] as? Int64 {
                    count = Int(c)
                    break
                }
            }
            return count
        } else {
            let processedQuery = preprocessFTSQuery(query)
            let countQuery = """
                SELECT COUNT(*) FROM songs s
                JOIN songs_fts fts ON s.id = fts.songId
                WHERE songs_fts MATCH ?;
                """
            var count: Int = 0
            for row in try db.prepare(countQuery, processedQuery) {
                if let c = row[0] as? Int64 {
                    count = Int(c)
                    break
                }
            }
            return count
        }
    }

    // MARK: - Upsert
    func upsertSong(_ song: Song) async throws -> Song {
        // Check if there's an existing row with the same "songKey"
        let existingRow = try db.pluck(songsTable.filter(colSongKey == song.songKey))
        let now = Date().timeIntervalSince1970  // store as epoch double

        if let row = existingRow {
            let songId = row[colId]
            try db.run(
                songsTable
                    .filter(colId == songId)
                    .update(
                        colArtist <- song.artist,
                        colTitle <- song.title,
                        colAlbum <- song.album,
                        colAlbumArtist <- song.albumArtist,  // NEW
                        colReleaseYear <- song.releaseYear,  // NEW
                        colDiscNumber <- song.discNumber,  // NEW
                        colTrackNumber <- song.trackNumber,
                        colCoverArtPath <- song.coverArtPath,
                        colBookmark <- song.bookmark.map { data in Blob(bytes: [UInt8](data)) },
                        colPathHash <- song.pathHash,
                        colUpdatedAt <- now
                    )
            )

            // Update FTS table
            try db.run(
                ftsSongsTable
                    .filter(colFtsSongId == songId)
                    .update(
                        colFtsArtist <- song.artist,
                        colFtsTitle <- song.title,
                        colFtsAlbum <- song.album,
                        colFtsAlbumArtist <- song.albumArtist  // NEW
                    )
            )

            return song.copyWith(id: songId)
        } else {
            let rowId = try db.run(
                songsTable.insert(
                    colSongKey <- song.songKey,
                    colArtist <- song.artist,
                    colTitle <- song.title,
                    colAlbum <- song.album,
                    colAlbumArtist <- song.albumArtist,  // NEW
                    colReleaseYear <- song.releaseYear,  // NEW
                    colDiscNumber <- song.discNumber,  // NEW
                    colTrackNumber <- song.trackNumber,
                    colCoverArtPath <- song.coverArtPath,
                    colBookmark <- song.bookmark.map { Blob(bytes: [UInt8]($0)) },
                    colPathHash <- song.pathHash,
                    colCreatedAt <- song.createdAt.timeIntervalSince1970,
                    colUpdatedAt <- song.updatedAt?.timeIntervalSince1970
                )
            )

            // Insert into FTS table
            try db.run(
                ftsSongsTable.insert(
                    colFtsSongId <- rowId,
                    colFtsArtist <- song.artist,
                    colFtsTitle <- song.title,
                    colFtsAlbum <- song.album,
                    colFtsAlbumArtist <- song.albumArtist  // NEW
                )
            )
            return song.copyWith(id: rowId)
        }
    }

    // MARK: - FTS Searching
    func searchSongsFTS(query: String, limit: Int, offset: Int) async throws -> [Song] {
        var results = [Song]()
        let statement: Statement
        let sql: String
        let bindings: [Binding?]

        if query.isEmpty {
            sql = """
                SELECT id, songKey, artist, title, album, trackNumber, coverArtPath, bookmark, pathHash, createdAt, updatedAt
                  FROM songs
                 ORDER BY createdAt DESC
                 LIMIT ? OFFSET ?;
                """
            bindings = [limit, offset]
        } else {
            let processedQuery = preprocessFTSQuery(query)
            sql = """
                SELECT s.id, s.songKey, s.artist, s.title, s.album, s.trackNumber,
                       s.coverArtPath, s.bookmark, s.pathHash, s.createdAt, s.updatedAt
                  FROM songs s
                  JOIN songs_fts fts ON s.id = fts.songId
                 WHERE songs_fts MATCH ?
                 ORDER BY bm25(songs_fts)
                 LIMIT ? OFFSET ?;
                """
            bindings = [processedQuery, limit, offset]
        }

        statement = try db.prepare(sql, bindings)
        for row in statement {
            guard let id = row[0] as? Int64 else { continue }
            let songKey = (row[1] as? Int64) ?? 0
            let artist = (row[2] as? String) ?? ""
            let title = (row[3] as? String) ?? ""
            let album = (row[4] as? String) ?? ""
            var trackNumber: Int? = nil
            if let t = (row[5] as? Int64) { trackNumber = Int(t) }
            let coverArtPath = row[6] as? String
            let bookmarkBlob = row[7] as? Blob
            let bookmarkData = bookmarkBlob.map { Data($0.bytes) }
            let pathHash = row[8] as? Int64 ?? -1
            let createdDouble = row[9] as? Double ?? 0
            let createdAt = Date(timeIntervalSince1970: createdDouble)
            let updatedDouble = row[10] as? Double
            let updatedAt = updatedDouble.map { Date(timeIntervalSince1970: $0) }

            // NOTE: FTS search doesn't return albumArtist, releaseYear, or discNumber,
            // so these fields are left blank. You may consider an additional lookup if required.
            let song = Song(
                id: id,
                songKey: songKey,
                artist: artist,
                title: title,
                album: album,
                albumArtist: "",  // Not available from FTS result.
                releaseYear: nil,  // Not available from FTS result.
                discNumber: nil,  // Not available from FTS result.
                trackNumber: trackNumber,
                coverArtPath: coverArtPath,
                bookmark: bookmarkData,
                pathHash: pathHash,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
            results.append(song)
        }
        return results
    }

    func getAllArtists() async throws -> [String] {
        let query = songsTable.select(colArtist)
            .filter(colArtist != "")
            .group(colArtist)
        return try db.prepare(query).compactMap { $0[colArtist] }
    }

    func getAllAlbums() async throws -> [Album] {
        let query = """
                SELECT album, artist, coverArtPath
                FROM songs AS s1
                WHERE album != ''
                  AND LENGTH(artist) = (
                    SELECT MIN(LENGTH(artist))
                    FROM songs AS s2
                    WHERE s2.album = s1.album
                )
                GROUP BY album
                ORDER BY album;
            """
        var albums = [Album]()
        for row in try db.prepare(query) {
            let albumName = row[0] as? String ?? ""
            let artist = row[1] as? String ?? ""
            let coverPath = row[2] as? String
            albums.append(Album(name: albumName, artist: artist, coverArtPath: coverPath))
        }
        return albums
    }

    func getSongsByArtist(_ artist: String) async throws -> [Song] {
        let query = songsTable.filter(colArtist == artist)
        return try parseSongsFromRows(db.prepare(query))
    }

    func getSongsByAlbum(_ album: String, artist: String?) async throws -> [Song] {
        var query = songsTable.filter(colAlbum == album)
        if let artist = artist { query = query.filter(colArtist == artist) }
        return try parseSongsFromRows(db.prepare(query))
    }

    private func parseSongsFromRows(_ rows: AnySequence<Row>) throws -> [Song] {
        return rows.map { row in
            let bookmarkBlob = row[colBookmark]
            let bookmarkData = bookmarkBlob.map { Data($0.bytes) }
            return Song(
                id: row[colId],
                songKey: row[colSongKey],
                artist: row[colArtist],
                title: row[colTitle],
                album: row[colAlbum],
                albumArtist: row[colAlbumArtist],  // NEW
                releaseYear: row[colReleaseYear],  // NEW
                discNumber: row[colDiscNumber],  // NEW
                trackNumber: row[colTrackNumber],
                coverArtPath: row[colCoverArtPath],
                bookmark: bookmarkData,
                pathHash: row[colPathHash],
                createdAt: Date(timeIntervalSince1970: row[colCreatedAt]),
                updatedAt: row[colUpdatedAt].map(Date.init(timeIntervalSince1970:))
            )
        }
    }
}

actor SQLitePlaylistRepository: PlaylistRepository {
    private let db: Connection
    private let table = Table("playlists")
    private let colId: SQLite.Expression<Int64>
    private let colName: SQLite.Expression<String>
    private let colCreatedAt: SQLite.Expression<Date>
    private let colUpdatedAt: SQLite.Expression<Date?>
    private let logger = Logger(subsystem: subsystem, category: "SQLitePlaylistRepository")

    init(db: Connection) throws {
        self.db = db
        // Column definitions
        let colId = SQLite.Expression<Int64>("id")
        let colName = SQLite.Expression<String>("name")
        let colCreatedAt = SQLite.Expression<Date>("createdAt")
        let colUpdatedAt = SQLite.Expression<Date?>("updatedAt")

        try db.run(
            table.create(ifNotExists: true) { t in
                t.column(colId, primaryKey: .autoincrement)
                t.column(colName)
                t.column(colCreatedAt)
                t.column(colUpdatedAt)
            })

        self.colId = colId
        self.colName = colName
        self.colCreatedAt = colCreatedAt
        self.colUpdatedAt = colUpdatedAt
    }

    func create(playlist: Playlist) async throws -> Playlist {
        let insert = table.insert(
            colName <- playlist.name,
            colCreatedAt <- playlist.createdAt,
            colUpdatedAt <- playlist.updatedAt
        )
        let rowId = try db.run(insert)
        return Playlist(
            id: rowId, name: playlist.name, createdAt: playlist.createdAt,
            updatedAt: playlist.updatedAt)
    }

    func update(playlist: Playlist) async throws -> Playlist {
        guard let playlistId = playlist.id else {
            throw CustomError.genericError("Cannot update playlist without ID")
        }

        let query = table.filter(colId == playlistId)
        try db.run(
            query.update(
                colName <- playlist.name,
                colUpdatedAt <- Date()
            ))

        return Playlist(
            id: playlistId,
            name: playlist.name,
            createdAt: playlist.createdAt,
            updatedAt: Date()
        )
    }

    func delete(playlistId: Int64) async throws {
        let query = table.filter(colId == playlistId)
        try db.run(query.delete())
    }

    func getAll() async throws -> [Playlist] {
        try db.prepare(table).map { row in
            Playlist(
                id: row[colId],
                name: row[colName],
                createdAt: row[colCreatedAt],
                updatedAt: row[colUpdatedAt]
            )
        }
    }

    func getOne(id: Int64) async throws -> Playlist? {
        let query = table.filter(colId == id)
        return try db.pluck(query).map { row in
            Playlist(
                id: row[colId],
                name: row[colName],
                createdAt: row[colCreatedAt],
                updatedAt: row[colUpdatedAt]
            )
        }
    }
}

// MARK: - Complete SQLitePlaylistSongRepository implementation
actor SQLitePlaylistSongRepository: PlaylistSongRepository {
    private let db: Connection
    private let table = Table("playlist_songs")
    private let colId: SQLite.Expression<Int64>
    private let colPlaylistId: SQLite.Expression<Int64>
    private let colSongId: SQLite.Expression<Int64>
    private let colPosition: SQLite.Expression<Int>
    private let logger = Logger(subsystem: subsystem, category: "SQLitePlaylistSongRepository")

    init(db: Connection) throws {
        self.db = db
        // Column definitions
        let colId = SQLite.Expression<Int64>("id")
        let colPlaylistId = SQLite.Expression<Int64>("playlistId")
        let colSongId = SQLite.Expression<Int64>("songId")
        let colPosition = SQLite.Expression<Int>("position")

        try db.run(
            table.create(ifNotExists: true) { t in
                t.column(colId, primaryKey: .autoincrement)
                t.column(colPlaylistId)
                t.column(colSongId)
                t.column(colPosition)
                t.unique(colPlaylistId, colSongId)  // Prevent duplicates
            }
        )

        self.colId = colId
        self.colPlaylistId = colPlaylistId
        self.colSongId = colSongId
        self.colPosition = colPosition
    }

    func addSong(playlistId: Int64, songId: Int64) async throws {
        // Get current max position
        let maxPosition =
            try db.scalar(
                table.filter(colPlaylistId == playlistId)
                    .select(colPosition.max)
            ) ?? -1

        let insert = table.insert(
            colPlaylistId <- playlistId,
            colSongId <- songId,
            colPosition <- maxPosition + 1
        )
        try db.run(insert)
    }

    func removeSong(playlistId: Int64, songId: Int64) async throws {
        let query = table.filter(colPlaylistId == playlistId && colSongId == songId)
        try db.run(query.delete())
    }

    func getSongs(playlistId: Int64) async throws -> [Song] {
        let songsTable = Table("songs")
        let songIdCol = SQLite.Expression<Int64>("id")

        return try db.prepare(
            table
                .join(songsTable, on: songsTable[songIdCol] == table[colSongId])
                .filter(colPlaylistId == playlistId)
                .order(colPosition.asc)
        ).map { row in
            Song(
                id: row[songsTable[songIdCol]],
                songKey: row[songsTable[Expression<Int64>("songKey")]],
                artist: row[songsTable[Expression<String>("artist")]],
                title: row[songsTable[Expression<String>("title")]],
                album: row[songsTable[Expression<String>("album")]],
                albumArtist: row[songsTable[Expression<String>("albumArtist")]],  // NEW
                releaseYear: row[songsTable[Expression<Int?>("releaseYear")]],  // NEW
                discNumber: row[songsTable[Expression<Int?>("discNumber")]],  // NEW
                trackNumber: row[songsTable[Expression<Int?>("trackNumber")]],
                coverArtPath: row[songsTable[Expression<String?>("coverArtPath")]],
                bookmark: (row[songsTable[SQLite.Expression<Blob?>("bookmark")]]?.bytes).map { Data($0) },
                pathHash: row[songsTable[Expression<Int64>("pathHash")]],
                createdAt: Date(
                    timeIntervalSince1970: row[songsTable[Expression<Double>("createdAt")]]),
                updatedAt: row[songsTable[Expression<Double?>("updatedAt")]].map(
                    Date.init(timeIntervalSince1970:))
            )
        }
    }

    func reorderSongs(playlistId: Int64, newOrder: [Int64]) async throws {
        try db.transaction {
            // Clear existing positions
            try db.run(table.filter(colPlaylistId == playlistId).update(colPosition <- -1))

            // Update with new positions
            for (index, songId) in newOrder.enumerated() {
                let query = table.filter(colPlaylistId == playlistId && colSongId == songId)
                try db.run(query.update(colPosition <- index))
            }

            // Cleanup any invalid entries (shouldn't be necessary)
            try db.run(table.filter(colPlaylistId == playlistId && colPosition == -1).delete())
        }
    }
}

// MARK: - Complete SQLitePlaylistSongRepository implementation
@MainActor
class DependencyContainer: ObservableObject {
    let userService: UserService
    let userCloudService: UserCloudService
    let icloudProvider: ICloudProvider
    let sourceService: SourceService
    let songRepository: SongRepository
    let songImportService: SongImportService
    let playerPersistenceService: PlayerPersistenceService
    let playlistRepo: PlaylistRepository
    let playlistSongRepo: PlaylistSongRepository

    @Published var sourceBrowseViewModels: [Int64: SourceBrowseViewModel] = [:]

    init() throws {
        guard let db = setupSQLiteConnection(dbName: "musicApp\(schemaVersion).sqlite") else {
            throw CustomError.genericError("database initialisation failed")
        }

        let userRepo = try SQLiteUserRepository(db: db)
        let sourceRepo = try SQLiteSourceRepository(db: db)
        let sourcePathRepo = try SQLiteSourcePathRepository(db: db)
        let sourcePathSearchRepository = try SQLiteSourcePathSearchRepository(db: db)
        let songRepo = try SQLiteSongRepository(db: db)

        self.userService = DefaultUserService(userRepository: userRepo)
        self.icloudProvider = DefaultICloudProvider()
        self.userCloudService = DefaultUserCloudService(
            userService: userService,
            iCloudProvider: icloudProvider)

        let sourceSyncService = DefaultSourceSyncService(
            sourceRepository: sourceRepo,
            sourcePathSearchRepository: sourcePathSearchRepository,
            sourcePathRepository: sourcePathRepo)

        let sourceImportService = DefaultSourceImportService(
            sourceRepository: sourceRepo,
            sourcePathRepository: sourcePathRepo,
            sourcePathSearchRepository: sourcePathSearchRepository)
        self.sourceService = DefaultSourceService(
            sourceRepo: sourceRepo,
            sourceSyncService: sourceSyncService,
            sourceImportService: sourceImportService)
        self.songRepository = songRepo
        self.songImportService = DefaultSongImportService(
            songRepo: songRepo,
            sourcePathRepo: sourcePathRepo,
            sourceRepo: sourceRepo)
        self.playerPersistenceService = DefaultPlayerPersistenceService(songRepo: songRepo)
        self.playlistRepo = try SQLitePlaylistRepository(db: db)
        self.playlistSongRepo = try SQLitePlaylistSongRepository(db: db)
    }

    func makeSongListViewModel(filter: SongListViewModel.Filter) -> SongListViewModel {
        SongListViewModel(songRepo: songRepository, filter: filter)
    }

    func makeArtistListViewModel() -> ArtistListViewModel {
        ArtistListViewModel(songRepo: songRepository)
    }

    func makeAlbumListViewModel() -> AlbumListViewModel {
        AlbumListViewModel(songRepo: songRepository)
    }

    func makePlaylistListViewModel() -> PlaylistListViewModel {
        PlaylistListViewModel(
            playlistRepo: playlistRepo,
            playlistSongRepo: playlistSongRepo,
            songRepo: songRepository
        )
    }

    func makeSyncViewModel() -> SyncViewModel {
        SyncViewModel(
            userCloudService: userCloudService,
            icloudProvider: icloudProvider,
            sourceService: sourceService,
            songImportService: songImportService
        )
    }
}
