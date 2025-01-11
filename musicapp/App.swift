import SQLite
import UIKit
import os

/// subsystem used in logs
let subsystem = "com.snowbear.musicapp"
let baseLogger = Logger(subsystem: subsystem, category: "General")

public func SetupSQLiteConnection(dbName: String) -> Connection? {
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

public class AppDependencies {
    public let userService: UserService

    public init(userService: UserService) {
        self.userService = userService
    }
}

public struct User {
    public let id: Int64?
    public let icloudId: String
}

public protocol UserRepository {
    func findByIcloudId(icloudId: String) async throws -> User?
    func create(user: User) async throws -> User
}

public protocol UserService {
    func getOrCreateUser(icloudId: String) async throws -> User
}

public protocol UserCloudService {
    func resolveCurrentICloudUser() async throws -> User?
}

public protocol ICloudProvider {
    func getCurrentICloudUserID() async throws -> String?
    func isICloudAvailable() -> Bool
}

public final class DefaultUserCloudService: UserCloudService {
    public func resolveCurrentICloudUser() async throws -> User? {
        if let icloudId = try await iCloudProvider.getCurrentICloudUserID() {
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

public final class DefaultUserService: UserService {
    let logger = Logger(subsystem: subsystem, category: "UserService")
    private var userRepository: UserRepository

    public func getOrCreateUser(icloudId: String) async throws -> User {
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

    public func findByIcloudId(icloudId: String) throws -> User? {
        if let row = try db.pluck(table.filter(colIcloudId == icloudId)) {
            return User(id: row[colId], icloudId: row[colIcloudId])
        }
        return nil
    }

    public func create(user: User) throws -> User {
        let insert = table.insert(colIcloudId <- user.icloudId)
        let rowId = try db.run(insert)
        logger.debug("inserted user \(rowId)")
        return User(id: rowId, icloudId: user.icloudId)
    }

    public init(db: Connection) throws {
        let colId: SQLite.Expression<Int64> = Expression<Int64>("id")
        let colIcloudId: SQLite.Expression<String> = Expression<String>("icloudId")
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
    private let colIcloudId: SQLite.Expression<String>
}
