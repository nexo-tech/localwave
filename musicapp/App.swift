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

struct LibrarySyncResultItem {
    let path: String
    let parentPath: String?
    let isDirectory: Bool
    let name: String
}

protocol LibrarySyncService {
    func syncDir(
        folderURL: URL, onCurrentURL: ((_ url: URL) -> Void)?,
        onSetLoading: ((_ loading: Bool) -> Void)?
    ) async throws
        -> [LibrarySyncResultItem]
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
              return baseURL.absoluteURL // If the relative path is empty, return the base URL
          }
        return baseURL.appendingPathComponent(relativePath).absoluteURL
    }
}

actor DefaultLibrarySyncService: LibrarySyncService {
    let logger = Logger(subsystem: subsystem, category: "LibrarySyncService")
    func syncDir(
        folderURL: URL, onCurrentURL: ((_ url: URL) -> Void)?,
        onSetLoading: ((_ loading: Bool) -> Void)?
    ) async throws
        -> [LibrarySyncResultItem]
    {
        logger.debug("[BFS] Starting BFS from: \(folderURL.path)")

        onSetLoading?(true)

        var audioURLs: [URL] = []
        let fm = FileManager.default
        var visited: Set<URL> = []
        var queue: [URL] = [folderURL]

        var result = [String: LibrarySyncResultItem]()

        guard folderURL.startAccessingSecurityScopedResource() else {
            logger.debug("[BFS] Failed to access security-scoped resource.")
            onSetLoading?(false)
            return []
        }
        defer {
            logger.debug("[BFS] Stopping access to security-scoped resource.")
            folderURL.stopAccessingSecurityScopedResource()
        }

        while !queue.isEmpty {
            let current = queue.removeFirst().resolvingSymlinksInPath()

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
                        if ["mp3", "m4a"].contains(ext) {
                            logger.debug(
                                "[BFS] Audio file found, adding to list: \(item.lastPathComponent)")
                            audioURLs.append(item)
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
        
        return []
    }
}

struct User: Sendable {
    let id: Int64?
    let icloudId: Int64
}

struct Library: Sendable {
    let id: Int64?
    let dirPath: String
    let userId: Int64
    let totalPaths: Int?
    let syncError: String?
    let isCurrent: Bool
    let createdAt: Date
    let lastSyncedAt: Date?
    let updatedAt: Date?
}

protocol LibraryService {
    func registerLibraryPath(userId: Int64, path: String) async throws -> Library
}

class DefaultLibraryService: LibraryService {
    let logger = Logger(subsystem: subsystem, category: "LibraryService")
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

    private var libraryRepo: LibraryRepository

    init(libraryRepo: LibraryRepository) {
        self.libraryRepo = libraryRepo
    }

}

protocol LibraryRepository {
    func create(library: Library) async throws -> Library
    func findOneByUserId(userId: Int64, path: String?) async throws -> [Library]
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
