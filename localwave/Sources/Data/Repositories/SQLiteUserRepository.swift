import Foundation
import os
import SQLite

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
