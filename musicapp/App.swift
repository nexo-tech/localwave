import CloudKit
import SQLite
import UIKit
import os

/// subsystem used in logs
let subsystem = "com.snowbear.musicapp"
let baseLogger = Logger(subsystem: subsystem, category: "General")

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

actor DefaultLibrarySyncService: LibrarySyncService {
    let logger = Logger(subsystem: subsystem, category: "LibrarySyncService")

    let libraryRepository: LibraryRepository
    let libraryPathRepository: LibraryPathRepository

    init(
        libraryRepository: LibraryRepository,
        libraryPathRepository: LibraryPathRepository
    ) {
        self.libraryRepository = libraryRepository
        self.libraryPathRepository = libraryPathRepository
    }

    func syncDir(
        libraryId: Int64, folderURL: URL, onCurrentURL: ((_ url: URL?) -> Void)?,
        onSetLoading: ((_ loading: Bool) -> Void)?
    ) async throws
        -> Library?
    {
        logger.debug("starting to collect items")
        do {
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

            logger.debug("removing stale paths...")
            let deletedCount = try await libraryPathRepository.deleteMany(
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

    func syncDirInner(
        folderURL: URL, onCurrentURL: ((_ url: URL) -> Void)?,
        onSetLoading: ((_ loading: Bool) -> Void)?
    ) async throws
        -> LibrarySyncResult?
    {
        logger.debug("[BFS] Starting BFS from: \(folderURL.path)")

        onSetLoading?(true)

        var audioURLs: [LibrarySyncResultItem] = []
        let fm = FileManager.default
        var visited: Set<URL> = []
        var queue: [URL] = [folderURL]

        var result = [String: LibrarySyncResultItem]()

        guard folderURL.startAccessingSecurityScopedResource() else {
            logger.debug("[BFS] Failed to access security-scoped resource.")
            onSetLoading?(false)
            return nil
        }
        defer {
            logger.debug("[BFS] Stopping access to security-scoped resource.")
            folderURL.stopAccessingSecurityScopedResource()
        }

        while !queue.isEmpty {
            let current = queue.removeFirst().resolvingSymlinksInPath()
            result[FileHelper(fileURL: current).toString()] = LibrarySyncResultItem(
                rootURL: folderURL, current: current, isDirectory: true)

            onCurrentURL?(current)
            logger.debug("[BFS] Dequeued folder: \(current.path)")

            guard !visited.contains(current) else {
                logger.debug("[BFS] Already visited \(current.path), skipping...")
                continue
            }
            visited.insert(current)

            do {
                let items = try fm.contentsOfDirectory(
                    at: current,
                    includingPropertiesForKeys: [
                        .isDirectoryKey,
                        .isSymbolicLinkKey,
                        .ubiquitousItemDownloadingStatusKey,
                    ],
                    options: [.skipsHiddenFiles]
                )
                logger.debug("[BFS] Found \(items.count) items in \(current.lastPathComponent)")

                for item in items {
                    let rv = try item.resourceValues(forKeys: [
                        .isDirectoryKey,
                        .isSymbolicLinkKey,
                        .ubiquitousItemDownloadingStatusKey,
                    ])

                    if rv.isSymbolicLink == true {
                        logger.debug("[BFS] Skipping symbolic link: \(item.path)")
                        continue
                    }

                    if rv.isDirectory == true {
                        if let status = rv.ubiquitousItemDownloadingStatus, status == .notDownloaded
                        {
                            do {
                                logger.debug(
                                    "[BFS] Subfolder not downloaded, requesting download: \(item.lastPathComponent)"
                                )
                                try fm.startDownloadingUbiquitousItem(at: item)
                                // We'll skip adding to BFS queue until it’s downloaded
                               try await waitForFolderDownloadIfNeeded(item)

                            } catch {
                                logger.debug(
                                    "[BFS] Error requesting iCloud subfolder download: \(error)")
                            }
                            continue
                        }
                        logger.debug(
                            "[BFS] Subfolder found, adding to queue: \(item.lastPathComponent)")
                        queue.append(item)
                    } else {
                        let ext = item.pathExtension.lowercased()
                        if ["mp3", "m4a", "aiff"].contains(ext) {
                            logger.debug(
                                "[BFS] Audio file found, adding to list: \(item.lastPathComponent)")
                            let resultItem = LibrarySyncResultItem(
                                rootURL: folderURL, current: item, isDirectory: false)
                            audioURLs.append(resultItem)
                            result[FileHelper(fileURL: item).toString()] = resultItem
                        }
                    }
                }
            } catch {
                logger.error(
                    "[BFS] Error reading directory \(current.path): \(error.localizedDescription)")
            }
        }
        logger.debug("[BFS] BFS complete. Total audio files found: \(audioURLs.count)")
        onSetLoading?(false)

        return LibrarySyncResult(
            allItems: Array(result.values), audioFiles: audioURLs, totalAudioFiles: audioURLs.count)
    }
    
    private var metadataQuery: NSMetadataQuery?
        private var folderDownloadContinuation: CheckedContinuation<Void, Error>?

        func waitForFolderDownloadIfNeeded(_ folderURL: URL) async throws {
            try await withCheckedThrowingContinuation { continuation in
                folderDownloadContinuation = continuation

                // Create your observer (non-actor)
                let observer = iCloudFolderDownloadObserver(actor: self, folderURL: folderURL)
                observer.startObserving()
                observer.startQuery()  // We'll set metadataQuery from inside the actor
            }
        }
        
        func setMetadataQuery(_ query: NSMetadataQuery) {
            // This runs on the actor context, so we can safely mutate actor properties
            self.metadataQuery = query
        }
        
        func handleQueryUpdate(_ notification: Notification, folderURL: URL) {
            guard let query = metadataQuery else { return }
            query.disableUpdates()
            
            var allDownloaded = true
            
            // Check each item’s iCloud status
            for case let metadataItem as NSMetadataItem in query.results {
                guard
                    let status = metadataItem.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String,
                    let itemURL = metadataItem.value(forAttribute: NSMetadataItemURLKey) as? URL
                else { continue }
                
                if status != NSMetadataUbiquitousItemDownloadingStatusCurrent {
                    do {
                        try FileManager.default.startDownloadingUbiquitousItem(at: itemURL)
                    } catch {
                        // handle error
                    }
                    allDownloaded = false
                }
            }
            
            if allDownloaded {
                finishFolderDownloadCheck()
            }
            
            query.enableUpdates()
        }
        
        func finishFolderDownloadCheck() {
            metadataQuery?.stop()
            metadataQuery = nil
            folderDownloadContinuation?.resume(returning: ())
            folderDownloadContinuation = nil
        }
    
}



// MARK: - Observer Class

class iCloudFolderDownloadObserver: NSObject {
    private unowned let actorRef: DefaultLibrarySyncService
    private let folderURL: URL
    
    init(actor: DefaultLibrarySyncService, folderURL: URL) {
        self.actorRef = actor
        self.folderURL = folderURL
    }
    
    func startObserving() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onQueryUpdate(_:)),
            name: .NSMetadataQueryDidUpdate,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onQueryUpdate(_:)),
            name: .NSMetadataQueryDidFinishGathering,
            object: nil
        )
    }
    
    func startQuery() {
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(
            format: "%K BEGINSWITH %@",
            NSMetadataItemPathKey,
            folderURL.path
        )
        
        // Hop onto the actor to set metadataQuery and then start
        Task {
            await actorRef.setMetadataQuery(query)
            query.start()
        }
    }
    
    @objc private func onQueryUpdate(_ notification: Notification) {
        // Bridge back to the actor
        Task {
            await actorRef.handleQueryUpdate(notification, folderURL: folderURL)
        }
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

protocol LibraryService {
    func registerLibraryPath(userId: Int64, path: String) async throws -> Library
    func getCurrentLibrary(userId: Int64) async throws -> Library?
    func syncService() -> LibrarySyncService
    func repository() -> LibraryRepository
}

class DefaultLibraryService: LibraryService {
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
    private var librarySyncService: LibrarySyncService

    init(libraryRepo: LibraryRepository, librarySyncService: LibrarySyncService) {
        self.libraryRepo = libraryRepo
        self.librarySyncService = librarySyncService
    }

}

protocol LibraryPathRepository {
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
