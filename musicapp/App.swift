import AVFoundation
import SQLite
import UIKit
import os

/// subsystem used in logs
let subsystem = "com.snowbear.musicapp"
let baseLogger = Logger(subsystem: subsystem, category: "General")

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

struct Library: Sendable {
    var id: Int64?
    var dirPath: String
    var userId: Int64
    var totalPaths: Int?
    var syncError: String?
    var isCurrent: Bool
    var createdAt: Date
    var lastSyncedAt: Date?
    var updatedAt: Date?
}

struct LibraryPath: Sendable {
    let id: Int64?
    let libraryId: Int64

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

/// Example song model, no libraryId. We store all metadata ourselves.
struct Song: Sendable {
    let id: Int64?

    /// A unique-ish hash of (artist, title, album).
    let songKey: Int64

    let artist: String
    let title: String
    let album: String

    /// e.g. "cover-XYZ.jpg" or nil if none
    let coverArtPath: String?

    /// Security-scoped bookmark for the actual file
    let bookmark: Data?

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
            coverArtPath: coverArtPath,
            bookmark: bookmark,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

func generateSongKey(artist: String, title: String, album: String) -> Int64 {
    // Normalize or lowercased if you like
    let combined = "\(artist.lowercased())__\(title.lowercased())__\(album.lowercased())"
    return hashStringToInt64(combined)  // Using your existing FNV approach
}

func setupSQLiteConnection(dbName: String) -> Connection? {
    baseLogger.debug("setting up connection ...")
    let dbPath = NSSearchPathForDirectoriesInDomains(
        .documentDirectory,
        .userDomainMask,
        true
    ).first!
    let dbFullPath = "\(dbPath)/\(dbName)"
    baseLogger.debug("db path: \(dbFullPath)")
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

class AppDependencies {
    let userService: UserService
    let userCloudService: UserCloudService
    let icloudProvider: ICloudProvider
    let libraryService: LibraryService

    init(
        userService: UserService,
        userCloudService: UserCloudService,
        icloudProvider: ICloudProvider,
        libraryService: LibraryService
    ) {
        self.userService = userService
        self.userCloudService = userCloudService
        self.icloudProvider = icloudProvider
        self.libraryService = libraryService
    }
}

struct LibrarySyncResult {
    let allItems: [LibrarySyncResultItem]
    let audioFiles: [LibrarySyncResultItem]
    let totalAudioFiles: Int
}

struct LibrarySyncResultItem {
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
    func searchSongsFTS(query: String, limit: Int) async throws -> [Song]
}

protocol LibraryImportService {
    func listItems(libraryId: Int64, parentPathId: Int64?) async throws -> [LibraryPath]
    func search(libraryId: Int64, query: String) async throws -> [LibraryPath]
}

protocol LibraryPathSearchRepository {
    func batchUpsertIntoFTS(paths: [LibraryPath]) async throws
    func search(libraryId: Int64, query: String, limit: Int) async throws -> [PathSearchResult]
    func batchDeleteFTS(libraryId: Int64, excludingRunId: Int64) async throws
}

protocol LibrarySyncService {
    func syncDir(
        libraryId: Int64,
        folderURL: URL,
        onCurrentURL: ((_ url: URL?) -> Void)?,
        onSetLoading: ((_ loading: Bool) -> Void)?
    ) async throws
        -> Library?
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

actor SongImporter {
    let logger = Logger(subsystem: subsystem, category: "SongImporter")

    private let songRepo: SongRepository
    private let libraryPathRepo: LibraryPathRepository

    init(songRepo: SongRepository, libraryPathRepo: LibraryPathRepository) {
        self.songRepo = songRepo
        self.libraryPathRepo = libraryPathRepo
    }

    /// Import all paths from a list of [LibraryPath].
    /// If a path is a directory, we gather all descendants recursively.
    func importPaths(paths: [LibraryPath]) async throws {
        // Step 1: gather all actual files
        let filePaths = try await gatherAllFiles(paths: paths)

        // Step 2: parse each file, create Song, upsert into DB
        for filePath in filePaths {
            // Reconstruct local URL from the LibraryPath
            // For example, if you have a "root" or "dirPath" somewhere, do:
            // let baseURL = URL(fileURLWithPath: someLibraryRootPath, isDirectory: true)
            // let fileURL = baseURL.appendingPathComponent(filePath.relativePath)
            //
            // For now, let's assume you have a method that can give you the real URL for that library path:
            guard let fileURL = resolveFileURL(for: filePath) else {
                continue
            }

            // Use AVFoundation to read metadata
            let (artist, title, album) = await readMetadataAVAsset(url: fileURL)
            let songKey = generateSongKey(artist: artist, title: title, album: album)

            // Create a security-scoped bookmark
            let bookmarkData = try createBookmark(for: fileURL)

            // Optionally store cover art on disk if you want
            // let coverPath = storeCoverArtOnDisk(...)

            // Upsert
            let newSong = Song(
                id: nil,
                songKey: songKey,
                artist: artist,
                title: title,
                album: album,
                coverArtPath: nil,  // or coverPath if you do cover art
                bookmark: bookmarkData,
                createdAt: Date(),
                updatedAt: nil
            )
            let song = try await songRepo.upsertSong(newSong)
            logger.debug("upserted song: \(song.title)")
        }
    }

    // MARK: - Recursively gather all file paths
    private func gatherAllFiles(paths: [LibraryPath]) async throws -> [LibraryPath] {
        var result = [LibraryPath]()
        for p in paths {
            if p.isDirectory {
                // gather children from libraryPathRepo
                let children = try await libraryPathRepo.getByParentId(
                    libraryId: p.libraryId,
                    parentPathId: p.pathId
                )
                // recursively gather
                let sub = try await gatherAllFiles(paths: children)
                result.append(contentsOf: sub)
            } else {
                result.append(p)
            }
        }
        return result
    }

    // MARK: - Avfoundation-based metadata reading
    @available(iOS 16.0, *)
    func readMetadataAVAsset(url: URL) async -> (artist: String, title: String, album: String) {
        let asset = AVURLAsset(url: url)

        // In iOS 16+, we load metadata asynchronously
        // This replaces the old 'commonMetadata' property
        let metadataItems: [AVMetadataItem]
        do {
            metadataItems = try await asset.load(.metadata)
        } catch {
            // If loading fails for some reason, return empty strings
            print("Failed to load metadata: \(error)")
            return ("", "", "")
        }

        var artist = ""
        var title = ""
        var album = ""

        // We iterate through metadata items, checking their commonKey
        for item in metadataItems {
            // 'commonKey' is also asynchronously loaded in iOS 16.0+
            guard let commonKey = item.commonKey else { continue }

            switch commonKey {
            case .commonKeyArtist:
                // load the stringValue asynchronously
                if let val = try? await item.load(.stringValue) {
                    artist = val
                }
            case .commonKeyTitle:
                if let val = try? await item.load(.stringValue) {
                    title = val
                }
            case .commonKeyAlbumName:
                if let val = try? await item.load(.stringValue) {
                    album = val
                }
            default:
                break
            }
        }

        return (artist, title, album)
    }

    // MARK: - Create a bookmark
    private func createBookmark(for fileURL: URL) throws -> Data {
        let data = try fileURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return data
    }

    /// Resolves the absolute file URL from a Library + LibraryPath.
    /// Assumes `library.dirPath` is the root folder's path on disk.
    /// Then appends `LibraryPath.relativePath`.
    private func resolveFileURL(for p: LibraryPath) -> URL? {
        // Example: you combine your app's Documents directory with p.relativePath
        guard
            let documentsDir = FileManager.default.urls(
                for: .documentDirectory, in: .userDomainMask
            ).first
        else {
            return nil
        }

        // Suppose relativePath is something like "audio/someSong.mp3".
        // Then final path is Documents/audio/someSong.mp3
        let fileURL = documentsDir.appendingPathComponent(p.relativePath)
        return fileURL
    }

    // MARK: - Store cover art in Documents/CoverArt
    private func storeCoverArtOnDisk(_ data: Data) -> String? {
        do {
            // 1) Get Documents
            guard
                let documentsDir = FileManager.default.urls(
                    for: .documentDirectory, in: .userDomainMask
                ).first
            else {
                return nil
            }

            // 2) Create a subfolder “CoverArt” if it doesn’t exist
            let coverArtDir = documentsDir.appendingPathComponent("CoverArt", isDirectory: true)
            if !FileManager.default.fileExists(atPath: coverArtDir.path) {
                try FileManager.default.createDirectory(
                    at: coverArtDir, withIntermediateDirectories: true)
            }

            // 3) Make a unique filename
            let filename = "cover-\(UUID().uuidString).jpg"
            let fileURL = coverArtDir.appendingPathComponent(filename)

            // 4) Write data
            try data.write(to: fileURL)

            // 5) Return the relative path or just the filename
            // E.g., "CoverArt/cover-xxxx.jpg"
            let relativeCoverPath = "CoverArt/\(filename)"
            return relativeCoverPath

        } catch {
            print("Could not store cover art: \(error)")
            return nil
        }
    }
}

actor DefaultLibraryImportService: LibraryImportService {
    let logger = Logger(subsystem: subsystem, category: "LibraryImportService")
    func listItems(libraryId: Int64, parentPathId: Int64?) async throws -> [LibraryPath] {
        logger.debug("attempting to list for libID : \(libraryId), parent: \(parentPathId ?? -1)")
        let all = try await libraryPathRepository.getByParentId(
            libraryId: libraryId, parentPathId: parentPathId)

        logger.debug("got : \(all.count) items")

        return all
    }

    func search(libraryId: Int64, query: String) async throws -> [LibraryPath] {
        let results = try await libraryPathSearchRepository.search(
            libraryId: libraryId,
            query: query,
            limit: 100  // or whatever you like
        )

        // Retrieve the actual LibraryPath records for each matching pathId
        var paths = [LibraryPath]()
        for r in results {
            if let p = try await libraryPathRepository.getByPathId(
                libraryId: libraryId, pathId: r.pathId)
            {
                paths.append(p)
            }
        }
        return paths
    }

    private let libraryPathRepository: LibraryPathRepository
    private let libraryPathSearchRepository: LibraryPathSearchRepository

    init(
        libraryPathRepository: LibraryPathRepository,
        libraryPathSearchRepository: LibraryPathSearchRepository
    ) {
        self.libraryPathRepository = libraryPathRepository
        self.libraryPathSearchRepository = libraryPathSearchRepository
    }

}
actor DefaultLibrarySyncService: LibrarySyncService {
    let logger = Logger(subsystem: subsystem, category: "LibrarySyncService")

    let libraryRepository: LibraryRepository
    let libraryPathRepository: LibraryPathRepository
    let libraryPathSearchRepository: LibraryPathSearchRepository

    init(
        libraryRepository: LibraryRepository,
        libraryPathSearchRepository: LibraryPathSearchRepository,
        libraryPathRepository: LibraryPathRepository
    ) {
        self.libraryRepository = libraryRepository
        self.libraryPathRepository = libraryPathRepository
        self.libraryPathSearchRepository = libraryPathSearchRepository
    }

    func syncDir(
        libraryId: Int64, folderURL: URL, onCurrentURL: ((_ url: URL?) -> Void)?,
        onSetLoading: ((_ loading: Bool) -> Void)?
    ) async throws
        -> Library?
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
                if let parentPath = x.parentURL?.absoluteString {
                    parentPathId = hashStringToInt64(parentPath)
                }
                let pathId = hashStringToInt64(x.url.absoluteString)
                return LibraryPath(
                    id: nil,
                    libraryId: libraryId,
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
            try await libraryPathRepository.batchUpsert(paths: items)
            try await libraryPathSearchRepository.batchUpsertIntoFTS(paths: items)

            logger.debug("removing stale paths...")
            let deletedCount = try await libraryPathRepository.deleteMany(
                libraryId: libraryId, excludingRunId: runId)
            try await libraryPathSearchRepository.batchDeleteFTS(
                libraryId: libraryId, excludingRunId: runId)
            logger.debug("removed \(deletedCount) stale paths")

            if let result = result {
                let totalAudioFiles = result.totalAudioFiles
                logger.debug("updating library \(libraryId)")
                if var lib = try await libraryRepository.getOne(id: libraryId) {
                    lib.lastSyncedAt = Date()
                    lib.updatedAt = Date()
                    lib.totalPaths = totalAudioFiles
                    return try await libraryRepository.updateLibrary(library: lib)
                } else {
                    logger.error("for some reason library \(libraryId) wasn't found")
                }
            }

            return nil
        } catch {
            logger.error("sync dir error: \(error)")
            if var lib = try await libraryRepository.getOne(id: libraryId) {
                lib.lastSyncedAt = Date()
                lib.updatedAt = Date()
                lib.syncError = "\(error)"
                return try await libraryRepository.updateLibrary(library: lib)
            }
            return nil
        }
    }

    func makeBookmarkKey(_ folderURL: URL) -> String {
        return String(hashStringToInt64(folderURL.absoluteString))
    }

    func syncDirInner(
        folderURL: URL,
        onCurrentURL: ((_ url: URL) -> Void)?,
        onSetLoading: ((_ loading: Bool) -> Void)?
    ) async throws
        -> LibrarySyncResult?
    {
        var audioURLs: [LibrarySyncResultItem] = []
        var result = [String: LibrarySyncResultItem]()
        let bookmarkKey = makeBookmarkKey(folderURL)
        let audioExtensions = ["mp3", "wav", "m4a", "flac", "aac"]
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
            // scanFolderRecursively(folderURL: folderURL)
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
                            // Parse partial ID3
                            // let (title, artist, album) = parseID3Tags(for: file)
                            // let meta = SongMetadata(
                            //     fileURL: file, title: title, artist: artist, album: album)
                            // collectedSongs.append(meta)
                            let resultItem = LibrarySyncResultItem(
                                rootURL: folderURL, current: file, isDirectory: false)
                            audioURLs.append(resultItem)
                            result[FileHelper(fileURL: file).toString()] = resultItem
                        } else {
                            let resultItem = LibrarySyncResultItem(
                                rootURL: folderURL, current: file, isDirectory: true)
                            result[FileHelper(fileURL: file).toString()] = resultItem
                        }
                    } catch {
                        logger.error("Error reading resource values: \(error)")
                    }
                }
                logger.debug("Total audio files found: \(audioURLs.count)")
                return LibrarySyncResult(
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

protocol LibraryService {
    func registerLibraryPath(userId: Int64, path: String) async throws -> Library
    func getCurrentLibrary(userId: Int64) async throws -> Library?
    func syncService() -> LibrarySyncService
    func importService() -> LibraryImportService
    func repository() -> LibraryRepository
}

class DefaultLibraryService: LibraryService {
    func importService() -> any LibraryImportService {
        return libraryImportService
    }

    let logger = Logger(subsystem: subsystem, category: "LibraryService")
    func repository() -> LibraryRepository {
        return libraryRepo
    }
    func getCurrentLibrary(userId: Int64) async throws -> Library? {
        let libraries = try await libraryRepo.findOneByUserId(userId: userId, path: nil)
        if libraries.count == 0 {
            return nil
        } else if let lib = libraries.first(where: { $0.isCurrent }) {
            return lib
        } else {
            let lib = libraries[0]
            return try await libraryRepo.setCurrentLibrary(userId: userId, libraryId: lib.id!)
        }
    }

    func registerLibraryPath(userId: Int64, path: String) async throws -> Library {
        let library = try await libraryRepo.findOneByUserId(userId: userId, path: path)
        if library.count == 0 {
            logger.debug("no library found, creating new one")
            // Create new library
            let lib = Library(
                id: nil, dirPath: path, userId: userId, totalPaths: nil, syncError: nil,
                isCurrent: true, createdAt: Date(), lastSyncedAt: nil, updatedAt: nil)
            let library = try await libraryRepo.create(library: lib)
            logger.debug("updating current switch")
            let lib2 = try await libraryRepo.setCurrentLibrary(
                userId: userId, libraryId: library.id!)
            return lib2
        } else if !library[0].isCurrent {
            logger.debug("library is found, but it's not current")
            let lib2 = try await libraryRepo.setCurrentLibrary(
                userId: userId, libraryId: library[0].id!)
            return lib2
        } else {
            return library[0]
        }
    }

    func syncService() -> LibrarySyncService {
        return librarySyncService
    }
    private var libraryRepo: LibraryRepository
    private var libraryImportService: LibraryImportService
    private var librarySyncService: LibrarySyncService

    init(
        libraryRepo: LibraryRepository, librarySyncService: LibrarySyncService,
        libraryImportService: LibraryImportService
    ) {
        self.libraryRepo = libraryRepo
        self.librarySyncService = librarySyncService
        self.libraryImportService = libraryImportService
    }

}

protocol LibraryPathRepository {
    func getByParentId(libraryId: Int64, parentPathId: Int64?) async throws -> [LibraryPath]
    func getByPathId(libraryId: Int64, pathId: Int64) async throws -> LibraryPath?
    func create(path: LibraryPath) async throws -> LibraryPath
    func updateFileHash(pathId: Int64, fileHash: Data?) async throws
    func deleteMany(libraryId: Int64) async throws
    func getByParentId(parentId: Int64) async throws -> [LibraryPath]
    func getByPath(relativePath: String, libraryId: Int64) async throws -> LibraryPath?
    func batchUpsert(paths: [LibraryPath]) async throws
    func deleteMany(libraryId: Int64, excludingRunId: Int64) async throws -> Int
}

protocol LibraryRepository {
    func create(library: Library) async throws -> Library
    func findOneByUserId(userId: Int64, path: String?) async throws -> [Library]
    func getOne(id: Int64) async throws -> Library?
    func updateLibrary(library: Library) async throws -> Library
    // needs to set isCurrent true to the library with userId
    // and for the rest of users libraries set isCurrentFalse
    func setCurrentLibrary(userId: Int64, libraryId: Int64) async throws -> Library
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

actor SQLiteLibraryRepository: LibraryRepository {
    private let db: Connection
    private let table = Table("libraries")

    private var colId: SQLite.Expression<Int64>
    private var colDirPath: SQLite.Expression<String>
    private var colUserId: SQLite.Expression<Int64>
    private var colTotalPaths: SQLite.Expression<Int?>
    private var colSyncError: SQLite.Expression<String?>
    private var colIsCurrent: SQLite.Expression<Bool>
    private var colCreatedAt: SQLite.Expression<Date>
    private var colLastSyncedAt: SQLite.Expression<Date?>
    private var colUpdatedAt: SQLite.Expression<Date?>

    private let logger = Logger(subsystem: subsystem, category: "SQLiteLibraryRepository")

    // MARK: - Initializer
    init(db: Connection) throws {
        let colId: SQLite.Expression<Int64> = Expression<Int64>("id")
        let colDirPath: SQLite.Expression<String> = Expression<String>("dirPath")
        let colUserId: SQLite.Expression<Int64> = Expression<Int64>("userId")
        let colTotalPaths: SQLite.Expression<Int?> = Expression<Int?>("totalPaths")
        let colSyncError: SQLite.Expression<String?> = Expression<String?>("syncError")
        let colIsCurrent: SQLite.Expression<Bool> = Expression<Bool>("isCurrent")
        let colCreatedAt: SQLite.Expression<Date> = Expression<Date>("createdAt")
        let colLastSyncedAt: SQLite.Expression<Date?> = Expression<Date?>("lastSyncedAt")
        let colUpdatedAt: SQLite.Expression<Date?> = Expression<Date?>("updatedAt")
        self.db = db
        try db.run(
            table.create(ifNotExists: true) { t in
                t.column(colId, primaryKey: .autoincrement)
                t.column(colDirPath)
                t.column(colUserId)
                t.column(colTotalPaths)
                t.column(colSyncError)
                t.column(colIsCurrent)
                t.column(colCreatedAt)
                t.column(colLastSyncedAt)
                t.column(colUpdatedAt)
            }
        )
        logger.debug("Created table: libraries")
        self.colId = colId
        self.colDirPath = colDirPath
        self.colUserId = colUserId
        self.colTotalPaths = colTotalPaths
        self.colSyncError = colSyncError
        self.colIsCurrent = colIsCurrent
        self.colCreatedAt = colCreatedAt
        self.colLastSyncedAt = colLastSyncedAt
        self.colUpdatedAt = colUpdatedAt
    }

    func getOne(id: Int64) async throws -> Library? {
        let query = table.filter(colId == id)
        if let row = try db.pluck(query) {
            return Library(
                id: row[colId],
                dirPath: row[colDirPath],
                userId: row[colUserId],
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

    // MARK: - Create
    func create(library: Library) async throws -> Library {
        let insert = table.insert(
            colDirPath <- library.dirPath,
            colUserId <- library.userId,
            colTotalPaths <- library.totalPaths,
            colSyncError <- library.syncError,
            colIsCurrent <- library.isCurrent,
            colCreatedAt <- library.createdAt,
            colLastSyncedAt <- library.lastSyncedAt,
            colUpdatedAt <- library.updatedAt
        )
        let rowId = try db.run(insert)
        logger.debug("Inserted library with ID: \(rowId)")
        return Library(
            id: rowId,
            dirPath: library.dirPath,
            userId: library.userId,
            totalPaths: library.totalPaths,
            syncError: library.syncError,
            isCurrent: library.isCurrent,
            createdAt: library.createdAt,
            lastSyncedAt: library.lastSyncedAt,
            updatedAt: library.updatedAt
        )
    }

    // MARK: - Find by User ID
    func findOneByUserId(userId: Int64, path: String?) async throws -> [Library] {
        var predicate = colUserId == userId
        if path != nil {
            predicate = predicate && colDirPath == path!
        }
        return try db.prepare(table.filter(predicate)).map {
            row in
            Library(
                id: row[colId],
                dirPath: row[colDirPath],
                userId: row[colUserId],
                totalPaths: row[colTotalPaths],
                syncError: row[colSyncError],
                isCurrent: row[colIsCurrent],
                createdAt: row[colCreatedAt],
                lastSyncedAt: row[colLastSyncedAt],
                updatedAt: row[colUpdatedAt]
            )
        }
    }

    // MARK: - Update
    func updateLibrary(library: Library) async throws -> Library {
        guard let libraryId = library.id else {
            throw NSError(domain: "Invalid library ID", code: 0, userInfo: nil)
        }
        let query = table.filter(colId == libraryId)
        try db.run(
            query.update(
                colDirPath <- library.dirPath,
                colTotalPaths <- library.totalPaths,
                colSyncError <- library.syncError,
                colIsCurrent <- library.isCurrent,
                colLastSyncedAt <- library.lastSyncedAt,
                colUpdatedAt <- library.updatedAt
            ))
        logger.debug("Updated library with ID: \(libraryId)")
        return library
    }

    // MARK: - Set Current Library
    func setCurrentLibrary(userId: Int64, libraryId: Int64) async throws -> Library {
        try db.transaction {
            // Set all libraries for the user to `isCurrent = false`
            try db.run(table.filter(colUserId == userId).update(colIsCurrent <- false))

            // Set the specific library to `isCurrent = true`
            let query = table.filter(colId == libraryId)
            try db.run(query.update(colIsCurrent <- true))
        }

        // Return the updated current library
        if let row = try db.pluck(table.filter(colId == libraryId)) {
            return Library(
                id: row[colId],
                dirPath: row[colDirPath],
                userId: row[colUserId],
                totalPaths: row[colTotalPaths],
                syncError: row[colSyncError],
                isCurrent: row[colIsCurrent],
                createdAt: row[colCreatedAt],
                lastSyncedAt: row[colLastSyncedAt],
                updatedAt: row[colUpdatedAt]
            )
        } else {
            throw NSError(domain: "Library not found", code: 0, userInfo: nil)
        }
    }
}

actor SQLiteLibraryPathRepository: LibraryPathRepository {
    private let db: Connection
    private let table = Table("library_paths")

    private let colId: SQLite.Expression<Int64>
    private let colLibraryId: SQLite.Expression<Int64>
    private let colPathId: SQLite.Expression<Int64>
    private let colParentPathId: SQLite.Expression<Int64?>
    private let colName: SQLite.Expression<String>
    private let colRelativePath: SQLite.Expression<String>
    private let colIsDirectory: SQLite.Expression<Bool>
    private let colFileHashSHA256: SQLite.Expression<Data?>
    private let colRunId: SQLite.Expression<Int64>
    private let colCreatedAt: SQLite.Expression<Date>
    private let colUpdatedAt: SQLite.Expression<Date?>

    private let logger = Logger(subsystem: subsystem, category: "SQLiteLibraryPathRepository")

    func getByPathId(libraryId: Int64, pathId: Int64) async throws -> LibraryPath? {
        let query = table.filter(colLibraryId == libraryId && colPathId == pathId)
        if let row = try db.pluck(query) {
            return LibraryPath(
                id: row[colId],
                libraryId: row[colLibraryId],
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

    func getByParentId(libraryId: Int64, parentPathId: Int64?) async throws -> [LibraryPath] {
        let rows: AnySequence<Row>
        if let parentId = parentPathId {
            let query = table.filter(colLibraryId == libraryId && colParentPathId == parentId)
            rows = try db.prepare(query)
        } else {
            let query = table.filter(colLibraryId == libraryId)  // && colParentPathId == nil)
            //            let query = table.filter(colLibraryId == libraryId && colParentPathId == nil)
            rows = try db.prepare(query)
        }
        return rows.map { row in
            LibraryPath(
                id: row[colId],
                libraryId: row[colLibraryId],
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
        let colLibraryId = SQLite.Expression<Int64>("libraryId")
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
                t.column(colLibraryId)
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
        logger.debug("Created table: library_paths")

        self.colId = colId
        self.colLibraryId = colLibraryId
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
    func deleteMany(libraryId: Int64, excludingRunId: Int64) async throws -> Int {
        let query = table.filter(colLibraryId == libraryId && colRunId != excludingRunId)
        let count = try db.run(query.delete())
        logger.debug(
            "Deleted \(count) library paths for libraryId: \(libraryId) excluding runId: \(excludingRunId)"
        )
        return count
    }
    // MARK: - Create
    func create(path: LibraryPath) async throws -> LibraryPath {
        let insert = table.insert(
            colLibraryId <- path.libraryId,
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
        logger.debug("Inserted library path with ID: \(rowId)")
        return path.copyWith(id: rowId)
    }

    // MARK: - Update File Hash
    func updateFileHash(pathId: Int64, fileHash: Data?) async throws {
        let query = table.filter(colPathId == pathId)
        try db.run(query.update(colFileHashSHA256 <- fileHash))
        logger.debug("Updated file hash for path ID: \(pathId)")
    }

    // MARK: - Delete Many
    func deleteMany(libraryId: Int64) async throws {
        let query = table.filter(colLibraryId == libraryId)
        let count = try db.run(query.delete())
        logger.debug("Deleted \(count) library paths for library ID: \(libraryId)")
    }

    // MARK: - Get By Parent ID
    func getByParentId(parentId: Int64) async throws -> [LibraryPath] {
        try db.prepare(table.filter(colParentPathId == parentId)).map { row in
            LibraryPath(
                id: row[colId],
                libraryId: row[colLibraryId],
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
    func getByPath(relativePath: String, libraryId: Int64) async throws -> LibraryPath? {
        let query = table.filter(colRelativePath == relativePath && colLibraryId == libraryId)
        if let row = try db.pluck(query) {
            return LibraryPath(
                id: row[colId],
                libraryId: row[colLibraryId],
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

    func batchUpsert(paths: [LibraryPath]) async throws {
        if paths.count == 0 {
            return
        }
        try db.transaction {
            for path in paths {
                let query = table.filter(colLibraryId == path.libraryId && colPathId == path.pathId)
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
                        "Updated library path with libraryId: \(path.libraryId), pathId: \(path.pathId)"
                    )
                } else {
                    // Insert new record
                    try db.run(
                        table.insert(
                            colLibraryId <- path.libraryId,
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
                        "Inserted new library path with libraryId: \(path.libraryId), pathId: \(path.pathId)"
                    )
                }
            }
        }
    }
}

// Helper extension for copying with new ID
extension LibraryPath {
    func copyWith(id: Int64?) -> LibraryPath {
        return LibraryPath(
            id: id,
            libraryId: libraryId,
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

actor SQLiteLibraryPathSearchRepository: LibraryPathSearchRepository {
    func search(libraryId: Int64, query: String, limit: Int) async throws -> [PathSearchResult] {
        let matchString = query

        let sql = """
            SELECT pathId, bm25(library_paths_fts) AS rank
            FROM library_paths_fts
            WHERE library_paths_fts MATCH ?
                AND libraryId = ?
            ORDER BY rank
            LIMIT ?;
            """

        var results: [PathSearchResult] = []
        for row in try db.prepare(sql, matchString, libraryId, limit) {
            let pathId = row[0] as? Int64 ?? 0
            let rank = row[1] as? Double ?? 0.0
            results.append(PathSearchResult(pathId: pathId, rank: rank))
        }
        return results
    }

    // MARK: - Batch Delete by libraryId, excluding runId
    func batchDeleteFTS(libraryId: Int64, excludingRunId: Int64) async throws {
        // Delete all rows with this libraryId where runId != excludingRunId
        let query = ftsTable.filter(
            colFtsLibraryId == libraryId && colFtsRunId != excludingRunId
        )
        try db.transaction {
            try db.run(query.delete())
        }
    }

    // MARK: - Batch Upsert
    /// If `(libraryId, pathId)` already exists, we update `runId`, `fullPath`, `fileName`.
    /// Otherwise, we insert a new row.
    func batchUpsertIntoFTS(paths: [LibraryPath]) async throws {
        guard !paths.isEmpty else { return }

        try db.transaction {
            for path in paths {
                let existingQuery = self.ftsTable.filter(
                    self.colFtsPathId == path.pathId && self.colFtsLibraryId == path.libraryId
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
                            self.colFtsLibraryId <- path.libraryId,
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
    private let ftsTable = Table("library_paths_fts")
    private let colFtsPathId = SQLite.Expression<Int64>("pathId")
    private let colFtsLibraryId = SQLite.Expression<Int64>("libraryId")
    private let colFtsRunId = SQLite.Expression<Int64>("runId")
    private let colFtsFullPath = SQLite.Expression<String>("fullPath")
    private let colFtsFileName = SQLite.Expression<String>("fileName")

    init(db: Connection) throws {
        self.db = db
        try db.execute(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS library_paths_fts
            USING fts5(
                pathId UNINDEXED,
                libraryId UNINDEXED,
                runId UNINDEXED,
                fullPath,
                fileName,
                tokenize='porter'
            );
            """)
    }

}

actor SQLiteSongRepository: SongRepository {
    private let db: Connection

    // MARK: - Main "songs" table
    private let songsTable = Table("songs")

    // Typed columns
    private let colId: SQLite.Expression<Int64>
    private let colSongKey: SQLite.Expression<Int64>
    private let colArtist: SQLite.Expression<String>
    private let colTitle: SQLite.Expression<String>
    private let colAlbum: SQLite.Expression<String>
    private let colCoverArtPath: SQLite.Expression<String?>
    private let colBookmark: SQLite.Expression<Blob?>  // We'll store as Blob, parse to Data
    private let colCreatedAt: SQLite.Expression<Double>  // store date as epoch seconds
    private let colUpdatedAt: SQLite.Expression<Double?>  // optional date

    // MARK: - FTS table
    private let ftsSongsTable = Table("songs_fts")
    private let colFtsSongId = SQLite.Expression<Int64>("songId")
    private let colFtsArtist = SQLite.Expression<String>("artist")
    private let colFtsTitle = SQLite.Expression<String>("title")
    private let colFtsAlbum = SQLite.Expression<String>("album")

    // MARK: - Init
    init(db: Connection) throws {
        self.db = db

        // Initialize typed column expressions
        let colId = SQLite.Expression<Int64>("id")
        let colSongKey = SQLite.Expression<Int64>("songKey")
        let colArtist = SQLite.Expression<String>("artist")
        let colTitle = SQLite.Expression<String>("title")
        let colAlbum = SQLite.Expression<String>("album")
        let colCoverArtPath = SQLite.Expression<String?>("coverArtPath")
        let colBookmark = SQLite.Expression<Blob?>("bookmark")
        let colCreatedAt = SQLite.Expression<Double>("createdAt")
        let colUpdatedAt = SQLite.Expression<Double?>("updatedAt")

        self.colId = colId
        self.colSongKey = colSongKey
        self.colArtist = colArtist
        self.colTitle = colTitle
        self.colAlbum = colAlbum
        self.colCoverArtPath = colCoverArtPath
        self.colBookmark = colBookmark
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
                t.column(colCoverArtPath)
                t.column(colBookmark)
                t.column(colCreatedAt)
                t.column(colUpdatedAt)
            }
        )

        // Create FTS table
        try db.execute(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS songs_fts
            USING fts5(
                songId UNINDEXED,
                artist,
                title,
                album,
                tokenize='porter'
            );
            """)
    }

    // MARK: - Upsert
    func upsertSong(_ song: Song) async throws -> Song {
        // We'll check if there's an existing row with the same "songKey"
        let existingRow = try db.pluck(songsTable.filter(colSongKey == song.songKey))

        let now = Date().timeIntervalSince1970  // store as epoch double
        if let row = existingRow {
            // We have an existing row => update
            let songId = row[colId]

            try db.run(
                songsTable
                    .filter(colId == songId)
                    .update(
                        colArtist <- song.artist,
                        colTitle <- song.title,
                        colAlbum <- song.album,
                        colCoverArtPath <- song.coverArtPath,
                        colBookmark
                            <- song.bookmark.map { data in
                                Blob(bytes: [UInt8](data))
                            },
                        colUpdatedAt <- now
                    )
            )

            // Update FTS
            try db.run(
                ftsSongsTable
                    .filter(colFtsSongId == songId)
                    .update(
                        colFtsArtist <- song.artist,
                        colFtsTitle <- song.title,
                        colFtsAlbum <- song.album
                    )
            )

            return song.copyWith(id: songId)

        } else {
            // Insert new
            let rowId = try db.run(
                songsTable.insert(
                    colSongKey <- song.songKey,
                    colArtist <- song.artist,
                    colTitle <- song.title,
                    colAlbum <- song.album,
                    colCoverArtPath <- song.coverArtPath,
                    colBookmark <- song.bookmark.map { Blob(bytes: [UInt8]($0)) },
                    colCreatedAt <- song.createdAt.timeIntervalSince1970,
                    colUpdatedAt <- song.updatedAt?.timeIntervalSince1970
                )
            )

            // Insert into FTS
            try db.run(
                ftsSongsTable.insert(
                    colFtsSongId <- rowId,
                    colFtsArtist <- song.artist,
                    colFtsTitle <- song.title,
                    colFtsAlbum <- song.album
                )
            )
            return song.copyWith(id: rowId)
        }
    }

    // MARK: - FTS Searching
    func searchSongsFTS(query: String, limit: Int) async throws -> [Song] {
        // We'll do a raw SQL statement to get bm25 ordering if needed.
        // We store date as Double, bookmark as Blob, so let's parse them carefully.
        let sql = """
            SELECT s.id, s.songKey, s.artist, s.title, s.album,
                   s.coverArtPath, s.bookmark, s.createdAt, s.updatedAt
              FROM songs s
              JOIN songs_fts fts ON s.id = fts.songId
             WHERE songs_fts MATCH ?
             ORDER BY bm25(songs_fts)
             LIMIT ?;
            """

        var results = [Song]()
        let statement = try db.prepare(sql, query, limit)
        for row in statement {
            // row[i] is an `any Binding?`, might be Int64, Double, String, Blob, or nil.
            // We parse carefully:

            // 0: s.id
            guard let id = row[0] as? Int64 else { continue }
            // 1: s.songKey
            let songKey = (row[1] as? Int64) ?? 0
            // 2: artist
            let artist = (row[2] as? String) ?? ""
            // 3: title
            let title = (row[3] as? String) ?? ""
            // 4: album
            let album = (row[4] as? String) ?? ""
            // 5: coverArtPath
            let coverArtPath = row[5] as? String
            // 6: bookmark => parse as Blob -> Data
            let bookmarkBlob = row[6] as? Blob
            let bookmarkData = bookmarkBlob.map { Data($0.bytes) }
            // 7: createdAt => parse as Double -> Date
            let createdDouble = row[7] as? Double ?? 0
            let createdAt = Date(timeIntervalSince1970: createdDouble)
            // 8: updatedAt => optional double
            let updatedDouble = row[8] as? Double
            let updatedAt = updatedDouble.map { Date(timeIntervalSince1970: $0) }

            // Build a new Song
            let song = Song(
                id: id,
                songKey: songKey,
                artist: artist,
                title: title,
                album: album,
                coverArtPath: coverArtPath,
                bookmark: bookmarkData,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
            results.append(song)
        }
        return results
    }
}
